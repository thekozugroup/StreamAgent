import Combine
import Foundation
import SQLite3
import XCTest
@testable import CodexBridge

final class CodexBridgeTests: XCTestCase {
    private var home: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("CodexBridgeTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    func testStatusLabelsSymbolsAndPublicInitializers() {
        XCTAssertEqual(AgentStatus.allCases.count, 7)
        for status in AgentStatus.allCases {
            XCTAssertFalse(status.label.isEmpty)
            XCTAssertFalse(status.symbol.isEmpty)
        }
        let session = AgentSession(id: "abc-123", title: "Fixture", projectPath: "/work", projectName: "Work",
                                   status: .working, updatedAt: now, statusDetail: "Fixture status")
        XCTAssertEqual(session.deepLink?.absoluteString, "codex://threads/abc-123")
        XCTAssertEqual(session.displayName, session.title)
        XCTAssertNil(AgentSession(id: "../new?prompt=bad", title: "", projectPath: "", projectName: "",
                                  status: .unknown, updatedAt: now, statusDetail: "").deepLink)
        XCTAssertEqual(AgentProject(id: "p", name: "Work", path: "/work", sessions: [session]).sessions, [session])
    }

    func testDisplayNamesPreferExplicitNameThenNicknameThenVerbatimTitle() throws {
        let state = try stateDB()
        let title = "  " + String(repeating: "Original title. ", count: 40) + "\n"
        try thread(state, id: "named", title: title, name: "  Original name  ", nickname: "Nickname")
        try thread(state, id: "nickname", title: title, name: "  \n", nickname: "Original nickname")
        try thread(state, id: "title", title: title)
        let sessions = CodexStoreReader(home: home).read(now: now).projects.flatMap(\.sessions)
        XCTAssertEqual(sessions.first { $0.id == "named" }?.displayName, "  Original name  ")
        XCTAssertEqual(sessions.first { $0.id == "nickname" }?.displayName, "Original nickname")
        XCTAssertEqual(sessions.first { $0.id == "title" }?.displayName, title)
        XCTAssertTrue(sessions.allSatisfy { $0.title == title })
        XCTAssertEqual(AgentSession(id: "init", title: title, projectPath: "", projectName: "", status: .idle,
                                    updatedAt: now, statusDetail: "", displayName: "Chosen").displayName, "Chosen")
    }

    func testModernTurnAndItemStatesAreEvidenceBased() throws {
        let state = try stateDB()
        let history = try historyDB()
        for id in ["started", "reasoning", "tool", "completed", "interrupted", "failed", "stale", "recent-only", "completed-reasoning", "old-reasoning-new-tool"] {
            try thread(state, id: id)
        }
        try turn(history, id: "started", status: "inProgress")
        try turn(history, id: "reasoning", status: "inProgress")
        try item(history, id: "reasoning", type: "reasoning", completed: false)
        try turn(history, id: "tool", status: "inProgress")
        try item(history, id: "tool", type: "commandExecution", completed: false)
        try turn(history, id: "completed", status: "completed")
        try item(history, id: "completed", type: "reasoning", completed: false)
        try turn(history, id: "interrupted", status: "interrupted")
        try turn(history, id: "failed", status: "failed")
        try turn(history, id: "stale", status: "inProgress", at: now.addingTimeInterval(-121))
        try turn(history, id: "completed-reasoning", status: "inProgress")
        try item(history, id: "completed-reasoning", type: "reasoning", completed: true)
        try turn(history, id: "old-reasoning-new-tool", status: "inProgress")
        try item(history, id: "old-reasoning-new-tool", type: "reasoning", completed: false)
        try item(history, id: "old-reasoning-new-tool", type: "mcpToolCall", completed: false, ordinal: 2)
        let snapshot = CodexStoreReader(home: home).read(now: now)
        let statuses = statuses(snapshot)
        XCTAssertEqual(statuses["started"], .working)
        XCTAssertEqual(statuses["reasoning"], .thinking)
        XCTAssertEqual(statuses["tool"], .working)
        XCTAssertEqual(statuses["completed"], .done)
        XCTAssertEqual(statuses["interrupted"], .idle)
        XCTAssertEqual(statuses["failed"], .failed)
        XCTAssertEqual(statuses["stale"], .unknown) // Recent threads.updated_at cannot revive a stale turn.
        XCTAssertEqual(statuses["recent-only"], .unknown)
        XCTAssertEqual(statuses["completed-reasoning"], .working)
        XCTAssertEqual(statuses["old-reasoning-new-tool"], .working)
    }

    func testLatestTurnOverridesEarlierTerminalAndItemsFromOtherTurns() throws {
        let state = try stateDB(), history = try historyDB()
        try thread(state, id: "thread")
        try turn(history, id: "thread", status: "completed", ordinal: 1)
        try turn(history, id: "thread", status: "inProgress", at: now.addingTimeInterval(-200), ordinal: 2)
        try item(history, id: "thread", type: "reasoning", completed: false, turnOrdinal: 1)
        XCTAssertEqual(statuses(CodexStoreReader(home: home).read(now: now))["thread"], .unknown)
    }

    func testBothStateLocationsDeduplicateAndPreferPrimary() throws {
        let primary = try stateDB(), secondary = try stateDB(relative: "sqlite/state_5.sqlite")
        _ = try historyDB()
        try thread(primary, id: "duplicate", title: "Primary", cwd: "/one")
        try thread(secondary, id: "duplicate", title: "Secondary", cwd: "/two")
        try thread(secondary, id: "nested-only", cwd: "/two", mode: "sqlite")
        let snapshot = CodexStoreReader(home: home).read(now: now)
        let sessions = snapshot.projects.flatMap(\.sessions)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.first { $0.id == "duplicate" }?.title, "Primary")
        XCTAssertTrue(snapshot.message.contains("sqlite/state_5.sqlite"))
        XCTAssertTrue(snapshot.message.contains("thread_history_1.sqlite"))
    }

    func testDiscoversNewerDatabaseVersionAndNestedHistory() throws {
        let state = try stateDB(relative: "sqlite/state_6.sqlite")
        let history = try historyDB(relative: "sqlite/thread_history_2.sqlite")
        try thread(state, id: "new-schema", mode: "sqlite")
        try turn(history, id: "new-schema", status: "completed")
        let snapshot = CodexStoreReader(home: home).read(now: now)
        XCTAssertEqual(statuses(snapshot)["new-schema"], .done)
        XCTAssertTrue(snapshot.message.contains("sqlite/thread_history_2.sqlite"))
    }

    func testCanonicalPathsProjectIDsAndStableSlots() throws {
        let state = try stateDB(), history = try historyDB()
        try thread(state, id: "newer", cwd: "/fixture/a/../work", at: now)
        try thread(state, id: "older", cwd: "/fixture/work", at: now.addingTimeInterval(-10))
        try thread(state, id: "other", cwd: "/different/work", at: now.addingTimeInterval(-20))
        try turn(history, id: "newer", status: "completed")
        try turn(history, id: "older", status: "completed")
        let reader = CodexStoreReader(home: home)
        let first = reader.read(now: now)
        XCTAssertEqual(first.projects.count, 2) // Same leaf name does not merge different full paths.
        XCTAssertEqual(first.projects[0].sessions.map(\.id), ["newer", "older"])
        try exec(history, "UPDATE thread_turns SET status='inProgress' WHERE thread_id='older'")
        try exec(state, "UPDATE threads SET updated_at_ms=\(ms(now.addingTimeInterval(20))) WHERE id='other'")
        try exec(state, "UPDATE threads SET updated_at_ms=\(ms(now.addingTimeInterval(10))) WHERE id='older'")
        let second = reader.read(now: now)
        XCTAssertEqual(second.projects.map(\.id), first.projects.map(\.id))
        XCTAssertEqual(second.projects[0].sessions.map(\.id), ["newer", "older"])
        XCTAssertEqual(statuses(second)["older"], .working)
        try thread(state, id: "just-added", cwd: "/fixture/work", at: now.addingTimeInterval(30))
        XCTAssertEqual(reader.read(now: now).projects[0].sessions.map(\.id), ["newer", "older", "just-added"])
    }

    func testProjectIDGroupsWorktreesAndRootMetadata() throws {
        let state = try stateDB()
        try exec(state, "CREATE TABLE projects(id TEXT PRIMARY KEY,name TEXT); CREATE TABLE project_roots(project_id TEXT,position INTEGER,path TEXT); INSERT INTO projects VALUES('project-1','Fixture project'); INSERT INTO project_roots VALUES('project-1',0,'/root/work')")
        try thread(state, id: "a", cwd: "/root/work", project: "project-1")
        try thread(state, id: "b", cwd: "/worktree/work", project: "project-1")
        let snapshot = CodexStoreReader(home: home).read(now: now)
        XCTAssertEqual(snapshot.projects.count, 1)
        XCTAssertEqual(snapshot.projects[0].id, "project:project-1")
        XCTAssertEqual(snapshot.projects[0].path, "/root/work")
        XCTAssertEqual(snapshot.projects[0].name, "Fixture project")
        XCTAssertEqual(Set(snapshot.projects[0].sessions.map(\.projectPath)), ["/root/work", "/worktree/work"])
    }

    func testLegacyStartReasoningToolRequestResolutionAndCompletion() throws {
        let state = try stateDB()
        let events: [(String, [String], AgentStatus)] = [
            ("start", ["task_started"], .working),
            ("reasoning", ["task_started", "agent_reasoning_delta"], .thinking),
            ("tool", ["task_started", "agent_reasoning_delta", "exec_command_begin"], .working),
            ("waiting", ["task_started", "exec_approval_request"], .waiting),
            ("input", ["task_started", "request_user_input"], .waiting),
            ("resolved", ["task_started", "request_user_input", "request_user_input_response"], .working),
            ("done", ["task_started", "request_user_input", "task_complete"], .done),
            ("interrupted", ["task_started", "turn_aborted"], .idle),
            ("failed", ["task_started", "turn_failed"], .failed)
        ]
        for (id, types, _) in events {
            let rollout = try jsonl(id, records: types.map { event($0) })
            try thread(state, id: id, mode: "legacy", rollout: rollout.path)
        }
        let snapshot = CodexStoreReader(home: home).read(now: now)
        for (id, _, expected) in events { XCTAssertEqual(statuses(snapshot)[id], expected, id) }
    }

    func testLegacyStalenessWaitingCacheInvalidationAndNoBodyInference() throws {
        let state = try stateDB()
        let path = try jsonl("mutable", records: [event("task_started"), event("agent_reasoning_delta")])
        try thread(state, id: "mutable", mode: "legacy", rollout: path.path)
        let reader = CodexStoreReader(home: home)
        XCTAssertEqual(statuses(reader.read(now: now))["mutable"], .thinking)
        XCTAssertEqual(statuses(reader.read(now: now.addingTimeInterval(121)))["mutable"], .unknown)
        _ = try jsonl("mutable", records: [event("request_user_input")])
        XCTAssertEqual(statuses(reader.read(now: now.addingTimeInterval(10000)))["mutable"], .waiting)
        _ = try jsonl("mutable", records: [event("task_complete")])
        XCTAssertEqual(statuses(reader.read(now: now))["mutable"], .done)
        _ = try jsonl("mutable", records: [event("task_started"), "{malformed"])
        XCTAssertEqual(statuses(reader.read(now: now))["mutable"], .unknown)
        let bodyOnly = try jsonl("body-only", records: ["{\"timestamp\":\"2027-01-15T08:00:00Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"text\":\"task_started THINKING awaiting input\"}]}}"])
        try thread(state, id: "body-only", mode: "legacy", rollout: bodyOnly.path)
        XCTAssertEqual(statuses(reader.read(now: now))["body-only"], .unknown)
    }

    func testNonblockingRequestAndWrongResolutionDoNotInventWaitingOrClearIt() throws {
        let state = try stateDB()
        let nonblocking = try jsonl("nonblocking", records: [event("task_started"), event("request_user_input", extras: "\"is_blocking\":false")])
        try thread(state, id: "nonblocking", mode: "legacy", rollout: nonblocking.path)
        let wrong = try jsonl("wrong", records: [event("request_user_input", extras: "\"request_id\":\"one\""), event("request_user_input_response", extras: "\"request_id\":\"two\"")])
        try thread(state, id: "wrong", mode: "legacy", rollout: wrong.path)
        let result = statuses(CodexStoreReader(home: home).read(now: now))
        XCTAssertEqual(result["nonblocking"], .working)
        XCTAssertEqual(result["wrong"], .waiting)
    }

    func testMultipleRequestsAndNumericProtocolIDsRemainWaitingUntilResolved() throws {
        let state = try stateDB()
        let first = "{\"timestamp\":\"2027-01-15T08:00:00Z\",\"id\":42,\"method\":\"item/tool/requestUserInput\",\"params\":{\"isBlocking\":true}}"
        let second = event("exec_approval_request", extras: "\"call_id\":\"second\"")
        let resolvedFirst = "{\"timestamp\":\"2027-01-15T08:00:00Z\",\"method\":\"serverRequest/resolved\",\"params\":{\"requestId\":42}}"
        let path = try jsonl("multiple", records: [first, second, resolvedFirst])
        try thread(state, id: "multiple", mode: "legacy", rollout: path.path)
        let reader = CodexStoreReader(home: home)
        XCTAssertEqual(statuses(reader.read(now: now))["multiple"], .waiting)
        _ = try jsonl("multiple", records: [first, second, resolvedFirst, event("exec_approval_response", extras: "\"call_id\":\"second\"")])
        XCTAssertEqual(statuses(reader.read(now: now))["multiple"], .working)
    }

    func testOlderMetadataSchemaWithoutOptionalColumnsAndModernMissingItemTiming() throws {
        let state = home.appendingPathComponent("state_5.sqlite")
        try exec(state, "CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,cwd TEXT,updated_at INTEGER,rollout_path TEXT); INSERT INTO threads VALUES('old','Verbatim title','/fixture',\(Int(now.timeIntervalSince1970)),'')")
        let result = CodexStoreReader(home: home).read(now: now)
        XCTAssertEqual(statuses(result)["old"], .unknown)
        XCTAssertEqual(result.projects.first?.sessions.first?.displayName, "Verbatim title")
        try exec(state, "ALTER TABLE threads ADD COLUMN history_mode TEXT; UPDATE threads SET history_mode='sqlite'")
        let history = try historyDB()
        try turn(history, id: "old", status: "inProgress")
        try exec(history, "DROP TABLE thread_items")
        let missingItems = CodexStoreReader(home: home).read(now: now)
        XCTAssertEqual(statuses(missingItems)["old"], .working)
        XCTAssertTrue(missingItems.message.contains("no item timing"))
    }

    func testReadOnlyAdapterSeesUncheckpointedWALAndDoesNotReadItemBodies() throws {
        let state = try stateDB(), history = try historyDB()
        try thread(state, id: "wal")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(history.path, &writer), SQLITE_OK)
        guard let writer = writer else { return XCTFail("Fixture writer unavailable") }
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0", nil, nil, nil), SQLITE_OK)
        try turn(history, id: "wal", status: "inProgress")
        try item(history, id: "wal", type: "reasoning", completed: false)
        try exec(history, "UPDATE thread_items SET item_json='not JSON; no body parsing required'")
        let data = try Data(contentsOf: history), wal = try Data(contentsOf: URL(fileURLWithPath: history.path + "-wal"))
        XCTAssertEqual(statuses(CodexStoreReader(home: home).read(now: now))["wal"], .thinking)
        XCTAssertEqual(try Data(contentsOf: history), data)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: history.path + "-wal")), wal)
    }

    func testModernMissingHistoryNeverFallsBackToOldRollout() throws {
        let state = try stateDB()
        let rollout = try jsonl("old", records: [event("task_complete")])
        try thread(state, id: "modern", mode: "paginated", rollout: rollout.path)
        XCTAssertEqual(statuses(CodexStoreReader(home: home).read(now: now))["modern"], .unknown)
    }

    func testMissingMalformedAndUnsupportedSourcesAreSafeAndReadOnly() throws {
        let reader = CodexStoreReader(home: home)
        XCTAssertTrue(reader.read(now: now).projects.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("state_5.sqlite").path))
        try Data("not sqlite".utf8).write(to: home.appendingPathComponent("state_5.sqlite"))
        XCTAssertTrue(reader.read(now: now).projects.isEmpty)
        try FileManager.default.removeItem(at: home.appendingPathComponent("state_5.sqlite"))
        let state = try stateDB(), history = try historyDB()
        try thread(state, id: "readonly")
        try turn(history, id: "readonly", status: "completed")
        let before = try Data(contentsOf: state), beforeHistory = try Data(contentsOf: history)
        XCTAssertEqual(statuses(reader.read(now: now))["readonly"], .done)
        XCTAssertEqual(try Data(contentsOf: state), before)
        XCTAssertEqual(try Data(contentsOf: history), beforeHistory)
        try exec(history, "UPDATE thread_turns SET status='unexpected_future_state'")
        XCTAssertEqual(statuses(reader.read(now: now))["readonly"], .unknown)
        try Data("corrupt history".utf8).write(to: history)
        XCTAssertEqual(statuses(reader.read(now: now))["readonly"], .unknown)
    }

    func testScanCapsAndArchivedExclusion() throws {
        let state = try stateDB()
        try exec(state, "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<300) INSERT INTO threads(id,title,cwd,updated_at_ms,history_mode,archived) SELECT printf('fixture-%03d',x),'Fixture','/bounded',\(ms(now))+x,'paginated',0 FROM n")
        try thread(state, id: "archived", at: now.addingTimeInterval(1))
        try exec(state, "UPDATE threads SET archived=1 WHERE id='archived'")
        let result = CodexStoreReader(home: home).read(now: now)
        XCTAssertEqual(result.projects.flatMap(\.sessions).count, 256)
        XCTAssertNil(statuses(result)["archived"])
    }

    func testLegacyTailBoundAndOutsideHomePathAreUnknown() throws {
        let state = try stateDB()
        let rollout = try jsonl("large", records: [event("task_complete"), String(repeating: "x", count: 300000)])
        try thread(state, id: "large", mode: "legacy", rollout: rollout.path)
        try thread(state, id: "outside", mode: "legacy", rollout: "/tmp/not-allowed.jsonl")
        let result = statuses(CodexStoreReader(home: home).read(now: now))
        XCTAssertEqual(result["large"], .unknown)
        XCTAssertEqual(result["outside"], .unknown)
    }

    func testMonitorRefreshPublishesOnMainAndCanStopAndRestart() throws {
        let state = try stateDB()
        try thread(state, id: "monitor")
        let monitor = CodexMonitor(codexHome: home)
        let refreshed = expectation(description: "published refresh")
        let subscription = monitor.$lastRefresh.compactMap { $0 }.first().sink { _ in
            XCTAssertTrue(Thread.isMainThread)
            refreshed.fulfill()
        }
        monitor.start()
        monitor.start()
        wait(for: [refreshed], timeout: 4)
        XCTAssertEqual(monitor.projects.flatMap(\.sessions).count, 1)
        monitor.stop()
        monitor.start()
        monitor.stop()
        withExtendedLifetime(subscription) {}
    }

    func testThreeSecondPollRefreshesMetadataAndStopSuppressesFurtherPublication() throws {
        let state = try stateDB()
        try thread(state, id: "poll", title: "Before poll")
        let monitor = CodexMonitor(codexHome: home)
        let initial = expectation(description: "initial poll")
        let polled = expectation(description: "three-second poll")
        var sawInitial = false
        let updates = monitor.$projects.sink { projects in
            let title = projects.first?.sessions.first?.title
            if title == "Before poll" && !sawInitial { sawInitial = true; initial.fulfill() }
            if title == "After poll" { polled.fulfill() }
        }
        monitor.start()
        wait(for: [initial], timeout: 3)
        try exec(state, "UPDATE threads SET title='After poll'")
        wait(for: [polled], timeout: 5)
        monitor.stop()
        let noPublication = expectation(description: "stop prevents timer publication")
        noPublication.isInverted = true
        let stopped = monitor.$lastRefresh.dropFirst().sink { _ in noPublication.fulfill() }
        try exec(state, "UPDATE threads SET title='Stopped'")
        wait(for: [noPublication], timeout: 3.3)
        XCTAssertEqual(monitor.projects.first?.sessions.first?.title, "After poll")
        withExtendedLifetime((updates, stopped)) {}
    }

    private func statuses(_ snapshot: BridgeSnapshot) -> [String: AgentStatus] {
        Dictionary(uniqueKeysWithValues: snapshot.projects.flatMap(\.sessions).map { ($0.id, $0.status) })
    }

    @discardableResult private func stateDB(relative: String = "state_5.sqlite") throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try exec(url, "CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,cwd TEXT,updated_at INTEGER,updated_at_ms INTEGER,project_id TEXT,rollout_path TEXT,history_mode TEXT,archived INTEGER DEFAULT 0,name TEXT,agent_nickname TEXT); CREATE INDEX idx_threads_updated ON threads(updated_at_ms DESC,id DESC)")
        return url
    }

    private func historyDB(relative: String = "thread_history_1.sqlite") throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try exec(url, "CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,rollout_ordinal INTEGER,status TEXT,started_at INTEGER,completed_at INTEGER); CREATE UNIQUE INDEX idx_turn ON thread_turns(thread_id,rollout_ordinal); CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,item_type TEXT,rollout_ordinal INTEGER,updated_at_ordinal INTEGER,created_at_ms INTEGER,started_at_ms INTEGER,completed_at_ms INTEGER,item_json TEXT); CREATE INDEX idx_item ON thread_items(thread_id,turn_id,updated_at_ordinal)")
        return url
    }

    private func thread(_ db: URL, id: String, title: String = "Fixture", cwd: String = "/fixture/work", project: String = "", at: Date? = nil, mode: String = "paginated", rollout: String = "", name: String = "", nickname: String = "") throws {
        try exec(db, "INSERT INTO threads VALUES(\(quote(id)),\(quote(title)),\(quote(cwd)),\(Int((at ?? now).timeIntervalSince1970)),\(ms(at ?? now)),\(quote(project)),\(quote(rollout)),\(quote(mode)),0,\(quote(name)),\(quote(nickname)))")
    }

    private func turn(_ db: URL, id: String, status: String, at: Date? = nil, ordinal: Int = 1) throws {
        let date = at ?? now
        try exec(db, "INSERT INTO thread_turns VALUES(\(quote(id)),\(quote("turn-\(ordinal)")),\(ordinal),\(quote(status)),\(Int(date.timeIntervalSince1970)),\(status == "inProgress" ? "NULL" : String(Int(date.timeIntervalSince1970))))")
    }

    private func item(_ db: URL, id: String, type: String, completed: Bool, ordinal: Int = 1, turnOrdinal: Int = 1) throws {
        try exec(db, "INSERT INTO thread_items VALUES(\(quote(id)),\(quote("turn-\(turnOrdinal)")),\(quote("item-\(ordinal)")),\(quote(type)),\(ordinal),\(ordinal),\(ms(now)),\(ms(now)),\(completed ? String(ms(now)) : "NULL"),'{\"text\":\"PRIVATE_FIXTURE_BODY\"}')")
    }

    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
    private func quote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "''") + "'" }

    private func exec(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db = db else { throw DatabaseFailure.unavailable }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw DatabaseFailure.query(sqlite3_errcode(db)) }
    }

    private func event(_ type: String, extras: String = "") -> String {
        let formatter = ISO8601DateFormatter()
        let additional = extras.isEmpty ? "" : "," + extras
        return "{\"timestamp\":\"\(formatter.string(from: now))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\"\(additional)}}"
    }

    @discardableResult private func jsonl(_ name: String, records: [String]) throws -> URL {
        let url = home.appendingPathComponent("sessions/" + name + ".jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((records.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }
}
