import Foundation

struct BridgeSnapshot {
    let projects: [AgentProject]
    let message: String
}

private struct ThreadMetadata {
    let id: String
    let title: String
    let displayName: String
    let cwd: String
    let projectID: String
    let projectName: String
    let projectRoot: String
    let updatedAt: Date
    let rolloutPath: String
    let historyMode: String
    let sourceDirectory: URL
}

/// Confined to the monitor's serial utility queue. The reader never retains conversation content.
final class CodexStoreReader {
    let home: URL
    private var projectOrder: [String] = []
    private var sessionOrder: [String: [String]] = [:]
    private var legacyCache: [String: LegacyCacheEntry] = [:]
    private var legacyCursor = 0

    init(home: URL) { self.home = home.standardizedFileURL.resolvingSymlinksInPath() }

    func read(now: Date = Date()) -> BridgeSnapshot {
        // One overall wall-clock budget, plus explicit bounds on every query/file read.
        let deadline = Date().addingTimeInterval(2)
        var diagnostics: [String] = []
        var records: [ThreadMetadata] = []
        var seen = Set<String>()
        let directories = [home, home.appendingPathComponent("sqlite", isDirectory: true)]
        for directory in directories {
            for url in databases(in: directory, prefix: "state_").prefix(2) {
                do {
                    let db = try ReadOnlySQLite(url: url, deadline: deadline)
                    let threads = try metadata(db, directory: directory)
                    for thread in threads where !seen.contains(thread.id) && records.count < 512 {
                        records.append(thread)
                        seen.insert(thread.id)
                    }
                    diagnostics.append("\(sourceName(url)): threads metadata")
                } catch {
                    diagnostics.append("\(sourceName(url)): unavailable/unsupported")
                }
            }
        }

        var histories: [String: ReadOnlySQLite] = [:]
        for directory in directories {
            for url in databases(in: directory, prefix: "thread_history_").prefix(2) {
                do {
                    let db = try ReadOnlySQLite(url: url, deadline: deadline)
                    let turns = try db.columns("thread_turns")
                    guard ["thread_id", "turn_id", "status", "rollout_ordinal"].allSatisfy(turns.contains) else {
                        throw DatabaseFailure.unsupported
                    }
                    histories[url.path] = db
                    let items = try db.columns("thread_items")
                    diagnostics.append("\(sourceName(url)): thread_turns" + (items.isEmpty ? " metadata (no item timing)" : " + thread_items metadata"))
                } catch {
                    diagnostics.append("\(sourceName(url)): unavailable/unsupported")
                }
            }
        }

        var evidence: [String: StatusEvidence] = [:]
        var legacy: [ThreadMetadata] = []
        for record in records {
            // paginated and sqlite modes must never resurrect a stale rollout JSONL.
            let usesSQLite = record.historyMode == "paginated" || record.historyMode == "sqlite"
            if usesSQLite {
                let ordered = directoriesForHistory(record.sourceDirectory, available: histories)
                for key in ordered {
                    guard let db = histories[key] else { continue }
                    do {
                        if let status = try sqliteEvidence(db, id: record.id, now: now) {
                            evidence[record.id] = status
                            break
                        }
                    } catch {
                        evidence[record.id] = .unavailable
                        // Do not replace an unreadable authoritative turn with older evidence.
                        break
                    }
                }
                if evidence[record.id] == nil { evidence[record.id] = .unavailable }
            } else if record.historyMode == "legacy" || record.historyMode.isEmpty {
                legacy.append(record)
            } else {
                evidence[record.id] = StatusEvidence(status: .unknown, detail: "Unsupported history mode")
            }
        }

        // At most 32 changed tails (8 MiB total) per poll. Rotate for larger legacy sets.
        var legacyReads = 0
        if !legacy.isEmpty {
            for offset in 0..<legacy.count {
                let record = legacy[(legacyCursor + offset) % legacy.count]
                if let url = safeRollout(record.rolloutPath) {
                    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                    let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
                    let modified = attributes?[.modificationDate] as? Date
                    let cached = legacyCache[url.path]
                    if cached?.size == size && cached?.modified == modified {
                        evidence[record.id] = cached?.signal.evidence(now: now) ?? .unavailable
                    } else if legacyReads < 32 && Date() < deadline {
                        legacyReads += 1
                        let signal = LegacyHistory.read(url: url, deadline: deadline)
                        legacyCache[url.path] = LegacyCacheEntry(size: size, modified: modified, signal: signal)
                        evidence[record.id] = signal.evidence(now: now)
                    } else {
                        // A changed file invalidates its old cached terminal/waiting evidence too.
                        evidence[record.id] = .unavailable
                    }
                }
            }
            legacyCursor = (legacyCursor + 32) % legacy.count
            diagnostics.append("legacy JSONL: bounded 256 KiB tails, 32 changed files/poll")
        }
        let retainedPaths = Set(legacy.compactMap { safeRollout($0.rolloutPath)?.path })
        legacyCache = legacyCache.filter { retainedPaths.contains($0.key) }

        let projects = group(records, evidence: evidence)
        if diagnostics.isEmpty { diagnostics.append("No readable state/history databases found") }
        let message = "\(records.count) threads / \(projects.count) projects; " + diagnostics.joined(separator: "; ")
            + "; limits: 256 threads/state, 512 total, 32 items/thread, 2s scan; running timeout: 120s"
        return BridgeSnapshot(projects: projects, message: message)
    }

    private func databases(in directory: URL, prefix: String) -> [URL] {
        // Only enumerate two known directories, never recurse through sessions or account files.
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { url -> (URL, Int)? in
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst(prefix.count).dropLast(7)) else { return nil }
            return (url, version)
        }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private func sourceName(_ url: URL) -> String {
        url.deletingLastPathComponent().lastPathComponent == "sqlite" ? "sqlite/" + url.lastPathComponent : url.lastPathComponent
    }

    private func metadata(_ db: ReadOnlySQLite, directory: URL) throws -> [ThreadMetadata] {
        let columns = try db.columns("threads")
        guard ["id", "cwd", "title"].allSatisfy(columns.contains),
              columns.contains("updated_at_ms") || columns.contains("updated_at") else { throw DatabaseFailure.unsupported }
        let seconds = columns.contains("updated_at") ? "updated_at * 1000" : "0"
        let time = columns.contains("updated_at_ms") ? "COALESCE(updated_at_ms, \(seconds))" : seconds
        // Keep ORDER BY on the native index; COALESCE here would force a table sort each poll.
        let order = columns.contains("updated_at_ms") ? "updated_at_ms" : "updated_at"
        let archived = columns.contains("archived") ? "WHERE archived = 0" : ""
        func field(_ name: String, fallback: String = "''") -> String { columns.contains(name) ? name : fallback }
        var projects: [String: (String, String)] = [:]
        if try db.columns("projects").isSuperset(of: ["id", "name"]) {
            try db.rows("SELECT substr(id,1,256), substr(name,1,240) FROM projects ORDER BY id LIMIT 512") { row in
                projects[row.string(0)] = (row.string(1), "")
            }
            if try db.columns("project_roots").isSuperset(of: ["project_id", "path", "position"]) {
                try db.rows("SELECT substr(project_id,1,256), substr(path,1,4096) FROM project_roots WHERE position = 0 LIMIT 512") { row in
                    let id = row.string(0)
                    if let entry = projects[id] { projects[id] = (entry.0, canonical(row.string(1))) }
                }
            }
        }
        var result: [ThreadMetadata] = []
        let sql = """
            SELECT substr(id,1,256), title, substr(cwd,1,4096), \(time),
                   substr(\(field("project_id")),1,256), substr(\(field("rollout_path")),1,4096), \(field("history_mode", fallback: "'legacy'")),
                   \(field("name")), \(field("agent_nickname"))
            FROM threads \(archived) ORDER BY \(order) DESC, id DESC LIMIT 256
            """
        try db.rows(sql) { row in
            let id = row.string(0)
            guard !id.isEmpty else { return }
            let project = projects[row.string(4)]
            let display = [row.string(7), row.string(8), row.string(1)].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? row.string(1)
            result.append(ThreadMetadata(id: id, title: row.string(1), displayName: display, cwd: canonical(row.string(2)),
                                         projectID: row.string(4), projectName: project?.0 ?? "", projectRoot: project?.1 ?? "",
                                         updatedAt: Date(timeIntervalSince1970: (row.number(3) ?? 0) / 1000),
                                         rolloutPath: row.string(5), historyMode: row.string(6), sourceDirectory: directory))
        }
        return result
    }

    private func directoriesForHistory(_ preferred: URL, available: [String: ReadOnlySQLite]) -> [String] {
        available.keys.sorted { left, right in
            let l = URL(fileURLWithPath: left), r = URL(fileURLWithPath: right)
            let lp = l.deletingLastPathComponent() == preferred, rp = r.deletingLastPathComponent() == preferred
            if lp != rp { return lp }
            func version(_ u: URL) -> Int { Int(u.deletingPathExtension().lastPathComponent.dropFirst("thread_history_".count)) ?? 0 }
            if version(l) != version(r) { return version(l) > version(r) }
            return left < right
        }
    }

    private func sqliteEvidence(_ db: ReadOnlySQLite, id: String, now: Date) throws -> StatusEvidence? {
        let columns = try db.columns("thread_turns")
        let started = columns.contains("started_at") ? "started_at" : "NULL"
        let completed = columns.contains("completed_at") ? "completed_at" : "NULL"
        var turn: (id: String, status: String, started: Date?)?
        try db.rows("SELECT turn_id,status,\(started),\(completed) FROM thread_turns WHERE thread_id=? ORDER BY rollout_ordinal DESC LIMIT 1", bindings: [id]) { row in
            turn = (row.string(0), row.string(1), date(row.number(2)))
        }
        guard let turn = turn else { return nil }
        switch turn.status {
        case "completed": return StatusEvidence(status: .done, detail: "Latest durable turn completed")
        case "failed": return StatusEvidence(status: .failed, detail: "Latest durable turn failed")
        case "interrupted": return StatusEvidence(status: .idle, detail: "Latest durable turn was interrupted")
        case "inProgress", "in_progress": break
        default: return StatusEvidence(status: .unknown, detail: "Unrecognized durable turn status")
        }
        let items = try db.columns("thread_items")
        guard ["thread_id", "turn_id", "item_type", "rollout_ordinal", "created_at_ms"].allSatisfy(items.contains) else {
            return StatusEvidence.running(at: turn.started, now: now)
        }
        let order = items.contains("updated_at_ordinal") ? "updated_at_ordinal" : "rollout_ordinal"
        let start = items.contains("started_at_ms") ? "started_at_ms" : "NULL"
        let end = items.contains("completed_at_ms") ? "completed_at_ms" : "NULL"
        var latest = turn.started
        var reasoning = false
        var newestItem = true
        // No item_json, command/output, reasoning summaries, user content, or error_json is selected.
        try db.rows("SELECT item_type,created_at_ms,\(start),\(end) FROM thread_items WHERE thread_id=? AND turn_id=? ORDER BY \(order) DESC, rollout_ordinal DESC LIMIT 32", bindings: [id, turn.id]) { row in
            let created = date(row.number(1), milliseconds: true)
            let started = date(row.number(2), milliseconds: true)
            let completed = date(row.number(3), milliseconds: true)
            let itemDate = [created, started, completed].compactMap { $0 }.max()
            if let itemDate = itemDate, latest == nil || itemDate > latest! { latest = itemDate }
            if newestItem {
                // Completed reasoning is historical evidence, never proof of current thinking.
                let freshReasoning = started.map { now.timeIntervalSince($0) >= -30 && now.timeIntervalSince($0) <= 120 } ?? false
                reasoning = row.string(0) == "reasoning" && freshReasoning && completed == nil
                newestItem = false
            }
        }
        return StatusEvidence.running(at: latest, now: now, reasoning: reasoning)
    }

    private func date(_ value: Double?, milliseconds: Bool = false) -> Date? {
        guard let value = value, value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds ? value / 1000 : value)
    }

    private func safeRollout(_ path: String) -> URL? {
        guard path.hasPrefix("/"), path.hasSuffix(".jsonl") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let roots = ["sessions", "archived_sessions"].map { home.appendingPathComponent($0).path + "/" }
        return roots.contains(where: { url.path.hasPrefix($0) }) ? url : nil
    }

    private func canonical(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func group(_ records: [ThreadMetadata], evidence: [String: StatusEvidence]) -> [AgentProject] {
        var projectForPath: [String: Set<String>] = [:]
        for record in records where !record.projectID.isEmpty && !record.cwd.isEmpty {
            projectForPath[record.cwd, default: []].insert(record.projectID)
        }
        var groups: [String: (name: String, path: String, sessions: [AgentSession])] = [:]
        for record in records {
            let inferred = projectForPath[record.cwd]
            let projectID = record.projectID.isEmpty && inferred?.count == 1 ? inferred!.first! : record.projectID
            let key = !projectID.isEmpty ? "project:" + projectID : (!record.cwd.isEmpty ? "path:" + record.cwd : "unassigned:" + record.id)
            let path = record.projectRoot.isEmpty ? record.cwd : record.projectRoot
            let name = record.projectName.isEmpty ? (path.isEmpty ? "Unassigned" : URL(fileURLWithPath: path).lastPathComponent) : record.projectName
            let status = evidence[record.id] ?? .unavailable
            let session = AgentSession(id: record.id, title: record.title, projectPath: record.cwd, projectName: name,
                                       status: status.status, updatedAt: record.updatedAt, statusDetail: status.detail, displayName: record.displayName)
            if groups[key] == nil { groups[key] = (name, path, []) }
            groups[key]?.sessions.append(session)
        }
        // Seed newest first, then retain slots. Status changes never reorder keys.
        let newProjects = groups.keys.filter { !projectOrder.contains($0) }.sorted { left, right in
            let l = groups[left]!.sessions.map(\.updatedAt).max() ?? .distantPast
            let r = groups[right]!.sessions.map(\.updatedAt).max() ?? .distantPast
            return l == r ? left < right : l > r
        }
        projectOrder = projectOrder.filter { groups[$0] != nil } + newProjects
        sessionOrder = sessionOrder.filter { groups[$0.key] != nil }
        return projectOrder.compactMap { key in
            guard let group = groups[key] else { return nil }
            let byID = Dictionary(uniqueKeysWithValues: group.sessions.map { ($0.id, $0) })
            let retained = (sessionOrder[key] ?? []).filter { byID[$0] != nil }
            let added = group.sessions.filter { !retained.contains($0.id) }.sorted {
                $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
            }.map(\.id)
            sessionOrder[key] = retained + added
            return AgentProject(id: key, name: group.name, path: group.path,
                                sessions: (sessionOrder[key] ?? []).compactMap { byID[$0] })
        }
    }
}

private struct LegacyCacheEntry {
    let size: UInt64
    let modified: Date?
    let signal: LegacySignal
}
