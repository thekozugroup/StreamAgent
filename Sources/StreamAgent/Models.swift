import Foundation

// Device coordinates are physical row-major indices. The navigation rail never moves.
enum DeckLayout {
    static let previous = 0, home = 5, next = 10
    static let contentKeys = [1, 2, 3, 4, 6, 7, 8, 9, 11, 12, 13, 14]
    static func contentIndex(for key: Int) -> Int? { contentKeys.firstIndex(of: key) }
    static func physicalKey(forContent index: Int) -> Int? { contentKeys.indices.contains(index) ? contentKeys[index] : nil }
    static func adjacentIndex(_ index: Int, delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }
}

enum ModuleKind: String, Codable, CaseIterable {
    case appControls, codex, media, workspaces, focus, custom
    var symbol: String {
        switch self {
        case .appControls: return "app.badge"
        case .codex: return "terminal"
        case .media: return "play.rectangle"
        case .workspaces: return "square.stack.3d.up"
        case .focus: return "timer"
        case .custom: return "square.grid.3x3"
        }
    }
}

enum ShortcutModifier: String, Codable, CaseIterable, Identifiable {
    case command, option, control, shift
    var id: String { rawValue }
    var glyph: String {
        switch self { case .command: return "⌘"; case .option: return "⌥"; case .control: return "⌃"; case .shift: return "⇧" }
    }
}

struct KeyboardShortcutSpec: Codable, Equatable {
    var key: String = "c"
    var modifiers: [ShortcutModifier] = [.command]
    var display: String { modifiers.map(\.glyph).joined() + key.uppercased() }
    // ANSI virtual key codes, including named navigation keys. Never interpret shell text.
    static let keyCodes: [String: UInt16] = [
        "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,
        "q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,
        "=":24,"9":25,"7":26,"-":27,"8":28,"0":29,
        "]":30,"o":31,"u":32,"[":33,"i":34,"p":35,"return":36,"l":37,"j":38,"'":39,"k":40,";":41,
        "\\":42,",":43,"/":44,"n":45,"m":46,".":47,"tab":48,"space":49,"`":50,"delete":51,"escape":53,
        "f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,"f9":101,"f10":109,"f11":103,"f12":111,
        "home":115,"pageup":116,"forwarddelete":117,"end":119,"pagedown":121,"left":123,"right":124,"down":125,"up":126
    ]
    var keyCode: UInt16? { Self.keyCodes[key.lowercased()] }
    func validate() throws {
        guard keyCode != nil else { throw ConfigurationError.invalid("Choose a supported shortcut key, such as c, return, left, or f1.") }
        guard Set(modifiers).count == modifiers.count else { throw ConfigurationError.invalid("Shortcut modifiers must be unique.") }
    }
}

enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case none, keyboard, openApp, openFile, openURL, appleShortcut, media, focus
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "No action"
        case .keyboard: return "Keyboard shortcut"
        case .openApp: return "Open app"
        case .openFile: return "Open file or folder"
        case .openURL: return "Open URL"
        case .appleShortcut: return "Run Apple Shortcut"
        case .media: return "Media control"
        case .focus: return "Focus timer"
        }
    }
}

struct TileAction: Codable, Equatable {
    var kind: ActionKind = .none
    var value: String = ""
    var shortcut: KeyboardShortcutSpec = .init()
    static let mediaCommands = ["playPause", "next", "previous", "volumeUp", "volumeDown", "mute"]
    static let focusCommands = ["startPause", "reset", "5", "15", "25", "45", "60"]
    func validate() throws {
        guard value.count <= 4096 else { throw ConfigurationError.invalid("Action value is too long.") }
        switch kind {
        case .none: break
        case .keyboard: try shortcut.validate()
        case .openApp:
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.hasPrefix("/") || (value.contains(".") && !value.contains("/") && !value.contains(" ")) else {
                throw ConfigurationError.invalid("Choose an app or enter its bundle identifier, such as com.apple.finder.")
            }
            if value.hasPrefix("/") && !value.lowercased().hasSuffix(".app") { throw ConfigurationError.invalid("The application path must end in .app.") }
        case .openFile:
            guard value.hasPrefix("/"), !value.contains("\0") else { throw ConfigurationError.invalid("Choose an absolute file or folder path.") }
        case .openURL:
            guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
                  ["https", "http", "mailto", "codex"].contains(scheme),
                  ((scheme != "https" && scheme != "http") || url.host?.isEmpty == false) else {
                throw ConfigurationError.invalid("Enter an http, https, mailto, or codex URL.")
            }
        case .appleShortcut:
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !value.contains("\n"), !value.contains("\0") else {
                throw ConfigurationError.invalid("Enter the exact name of an Apple Shortcut.")
            }
        case .media:
            guard Self.mediaCommands.contains(value) else { throw ConfigurationError.invalid("Unknown media command.") }
        case .focus:
            guard Self.focusCommands.contains(value) else { throw ConfigurationError.invalid("Unknown focus command.") }
        }
    }
}

struct ActionTile: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var label: String = ""
    var symbol: String = "square.dashed"
    var action: TileAction = .init()
    static func empty() -> ActionTile { ActionTile() }
    static func shortcut(_ label: String, _ symbol: String, _ key: String, _ modifiers: [ShortcutModifier] = [.command]) -> ActionTile {
        .init(label: label, symbol: symbol, action: .init(kind: .keyboard, shortcut: .init(key: key, modifiers: modifiers)))
    }
    static func command(_ label: String, _ symbol: String, _ kind: ActionKind, _ value: String) -> ActionTile {
        .init(label: label, symbol: symbol, action: .init(kind: kind, value: value))
    }
    static func padded(_ tiles: [ActionTile]) -> [ActionTile] { Array(tiles.prefix(12)) + (0..<max(0, 12 - tiles.count)).map { _ in .empty() } }
}

struct ActionPage: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var name: String = "New page"
    var tiles: [ActionTile] = ActionTile.padded([])
}

struct ModuleConfiguration: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var kind: ModuleKind
    var name: String
    var tiles: [ActionTile] = ActionTile.padded([])
    var pages: [ActionPage] = []
    var symbol: String { kind.symbol }
}

struct AppProfile: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var bundleIdentifier: String
    var name: String
    var tiles: [ActionTile]
}

struct AppConfiguration: Codable, Equatable {
    var version = 1
    var modules: [ModuleConfiguration]
    var selectedModuleID: String
    var brightness = 65
    var profiles: [AppProfile]
    var codexProjectOrder: [String] = []
    var pinnedProjectIDs: [String] = []
    var focusMinutes = 25
    var keepAwake = false
    var autoSwitchToAppControls = false
    static func defaults() -> AppConfiguration {
        let app = ModuleConfiguration(kind: .appControls, name: "App Controls")
        let codex = ModuleConfiguration(kind: .codex, name: "Codex")
        let media = ModuleConfiguration(kind: .media, name: "Media", tiles: ActionTile.padded([
            .command("Previous", "backward.end.fill", .media, "previous"), .command("Play / Pause", "playpause.fill", .media, "playPause"),
            .command("Next", "forward.end.fill", .media, "next"), .command("Mute", "speaker.slash.fill", .media, "mute"),
            .command("Volume down", "speaker.wave.1.fill", .media, "volumeDown"), .command("Volume up", "speaker.wave.3.fill", .media, "volumeUp")
        ]))
        let work = ModuleConfiguration(kind: .workspaces, name: "Workspaces", tiles: ActionTile.padded([
            .command("Finder", "folder", .openApp, "com.apple.finder"),
            .command("Safari", "safari", .openApp, "com.apple.Safari"),
            .command("Applications", "folder", .openFile, "/Applications"),
            .command("Apple", "globe", .openURL, "https://www.apple.com")
        ]))
        let focus = ModuleConfiguration(kind: .focus, name: "Focus", tiles: ActionTile.padded([
            .command("Start / Pause", "playpause", .focus, "startPause"), .command("Reset", "arrow.counterclockwise", .focus, "reset"),
            .command("5 minutes", "timer", .focus, "5"), .command("15 minutes", "timer", .focus, "15"),
            .command("25 minutes", "timer", .focus, "25"), .command("45 minutes", "timer", .focus, "45"),
            .command("60 minutes", "timer", .focus, "60")
        ]))
        let general = ActionTile.padded([
            .shortcut("Copy", "doc.on.doc", "c"), .shortcut("Paste", "doc.on.clipboard", "v"), .shortcut("Undo", "arrow.uturn.backward", "z"), .shortcut("Search", "magnifyingglass", "f"),
            .shortcut("Save", "square.and.arrow.down", "s"), .shortcut("New", "plus", "n"), .shortcut("Close", "xmark", "w"), .shortcut("Select all", "selection.pin.in.out", "a")
        ])
        var finder = general
        finder[4] = .shortcut("New folder", "folder.badge.plus", "n", [.command, .shift])
        finder[5] = .shortcut("Quick Look", "eye", "space", [])
        finder[6] = .shortcut("Parent folder", "arrow.up.to.line", "up", [.command])
        finder[7] = .shortcut("Get Info", "info.circle", "i")
        var browser = general
        browser[4] = .shortcut("Reload", "arrow.clockwise", "r")
        browser[5] = .shortcut("New tab", "plus.square", "t")
        browser[6] = .shortcut("Address", "link", "l")
        browser[7] = .shortcut("Reopen tab", "arrow.uturn.backward", "t", [.command, .shift])
        let profiles = [AppProfile(bundleIdentifier: "*", name: "Default", tiles: general),
                        AppProfile(bundleIdentifier: "com.apple.finder", name: "Finder", tiles: finder),
                        AppProfile(bundleIdentifier: "com.apple.Safari", name: "Safari", tiles: browser),
                        AppProfile(bundleIdentifier: "com.google.Chrome", name: "Chrome", tiles: browser),
                        AppProfile(bundleIdentifier: "com.microsoft.VSCode", name: "Visual Studio Code", tiles: general),
                        AppProfile(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode", tiles: general)]
        return .init(modules: [app, codex, media, work, focus], selectedModuleID: app.id, profiles: profiles)
    }
    func validate() throws {
        guard version == 1 else { throw ConfigurationError.invalid("This configuration version is not supported.") }
        guard (1...40).contains(modules.count), Set(modules.map(\.id)).count == modules.count,
              modules.contains(where: { $0.id == selectedModuleID }), (0...100).contains(brightness), (1...240).contains(focusMinutes) else {
            throw ConfigurationError.invalid("Configuration contains invalid modules, brightness, or focus duration.")
        }
        guard profiles.count <= 200, Set(profiles.map(\.bundleIdentifier)).count == profiles.count,
              Set(profiles.map(\.id)).count == profiles.count,
              Set(codexProjectOrder).count == codexProjectOrder.count,
              Set(pinnedProjectIDs).count == pinnedProjectIDs.count else { throw ConfigurationError.invalid("Configuration contains duplicate profiles or projects.") }
        func tiles(_ values: [ActionTile]) throws {
            var ids = Set<String>()
            guard values.count == 12 else { throw ConfigurationError.invalid("Every page must have exactly twelve tiles.") }
            for tile in values {
                guard !tile.id.isEmpty, ids.insert(tile.id).inserted, tile.label.count <= 60,
                      !tile.symbol.isEmpty, tile.symbol.count <= 100 else { throw ConfigurationError.invalid("Invalid or duplicate action tile.") }
                try tile.action.validate()
            }
        }
        for module in modules {
            guard !module.id.isEmpty, !module.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, module.name.count <= 60,
                  module.pages.count <= 30, Set(module.pages.map(\.id)).count == module.pages.count else { throw ConfigurationError.invalid("Invalid module or page name.") }
            try tiles(module.tiles)
            for page in module.pages {
                guard !page.id.isEmpty, !page.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, page.name.count <= 60 else { throw ConfigurationError.invalid("Page names must contain 1–60 characters.") }
                try tiles(page.tiles)
            }
        }
        for profile in profiles {
            guard !profile.bundleIdentifier.isEmpty, !profile.name.isEmpty, profile.name.count <= 80 else { throw ConfigurationError.invalid("Invalid app profile.") }
            try tiles(profile.tiles)
        }
    }
}

enum ConfigurationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

/// Validation happens before any mutation. A bad startup file remains byte-for-byte intact.
final class ConfigurationStore {
    static let maximumBytes = 5_000_000
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("configuration.json") }
    private(set) var recoveryRequired = false
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StreamAgent", isDirectory: true)) { self.directory = directory }
    func load() throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .defaults() }
        do { return try decode(Data(contentsOf: fileURL)) }
        catch { recoveryRequired = true; throw error }
    }
    func decode(_ data: Data) throws -> AppConfiguration {
        guard data.count <= Self.maximumBytes else { throw ConfigurationError.invalid("Configuration exceeds the 5 MB limit.") }
        let result = try JSONDecoder().decode(AppConfiguration.self, from: data)
        try result.validate()
        return result
    }
    func encoded(_ configuration: AppConfiguration) throws -> Data {
        try configuration.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        guard data.count <= Self.maximumBytes else { throw ConfigurationError.invalid("Configuration exceeds the 5 MB limit. Remove some pages or shorten action values before saving.") }
        return data
    }
    func save(_ configuration: AppConfiguration) throws {
        guard !recoveryRequired else { throw ConfigurationError.invalid("The damaged configuration is preserved. Export your changes, or use Settings → Preserve damaged file and save to continue.") }
        let data = try encoded(configuration)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
    }
    func importConfiguration(from url: URL) throws -> AppConfiguration {
        let candidate = try decode(Data(contentsOf: url))
        // Compact imports can grow beyond the limit when canonicalized. Reject
        // those before backups, recovery-state changes, or active-file writes.
        _ = try encoded(candidate)
        // Preserve the previous valid configuration too, before replacing it.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) { try backupCurrent() }
        let wasRecovering = recoveryRequired
        recoveryRequired = false
        do { try save(candidate) } catch { recoveryRequired = wasRecovering; throw error }
        return candidate
    }
    @discardableResult private func backupCurrent() throws -> URL {
        let backup = directory.appendingPathComponent("configuration-preserved-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: fileURL, to: backup)
        return backup
    }
    func preserveAndSave(_ configuration: AppConfiguration) throws {
        _ = try encoded(configuration)
        if FileManager.default.fileExists(atPath: fileURL.path) { try backupCurrent() }
        recoveryRequired = false
        do { try save(configuration) } catch { recoveryRequired = true; throw error }
    }
    func export(_ configuration: AppConfiguration, to url: URL) throws {
        guard url.standardizedFileURL.resolvingSymlinksInPath() != fileURL.standardizedFileURL.resolvingSymlinksInPath() else {
            throw ConfigurationError.invalid("Choose an export location outside the active configuration file.")
        }
        try encoded(configuration).write(to: url, options: [.atomic])
    }
}

struct FocusState: Equatable {
    enum Phase: String { case ready, running, paused, finished }
    var duration: TimeInterval = 25 * 60
    var remaining: TimeInterval = 25 * 60
    var phase: Phase = .ready
    var deadline: Date?
    mutating func toggle(now: Date = Date()) {
        if phase == .running { tick(now: now); if phase == .running { phase = .paused }; deadline = nil }
        else { if phase == .finished { remaining = duration }; phase = .running; deadline = now.addingTimeInterval(remaining) }
    }
    mutating func reset(minutes: Int? = nil) {
        if let minutes { duration = TimeInterval(minutes * 60) }
        remaining = duration; phase = .ready; deadline = nil
    }
    mutating func tick(now: Date = Date()) {
        guard phase == .running, let deadline else { return }
        remaining = max(0, deadline.timeIntervalSince(now))
        if remaining == 0 { phase = .finished; self.deadline = nil }
    }
    var display: String { let seconds = Int(ceil(remaining)); return String(format: "%02d:%02d", seconds / 60, seconds % 60) }
}

/// Fixed project slots and per-project thread slots survive refresh ordering changes.
struct StableCodexBoard {
    private(set) var projectIDs: [String] = []
    private(set) var sessionIDs: [String: [String]] = [:]
    var bankCount: Int { max(1, Int(ceil(Double(projectIDs.count) / 4))) }
    mutating func reconcile(projects: [(id: String, sessions: [String])], preferred: [String], pinned: [String]) {
        // Keep missing projects as unavailable placeholders for this run.
        // A transient metadata failure must not slide every later project left.
        let wanted = Array(NSOrderedSet(array: preferred + pinned + projectIDs + projects.map(\.id))) as? [String] ?? []
        projectIDs = wanted
        for project in projects {
            let current = sessionIDs[project.id] ?? []
            // Keep existing threads in place; new threads fill vacated rows before overflow.
            let live = Set(project.sessions)
            var slots = current.map { live.contains($0) ? $0 : "" }
            let additions = project.sessions.filter { !slots.contains($0) }
            for id in additions {
                if let empty = slots.firstIndex(of: "") { slots[empty] = id } else { slots.append(id) }
            }
            while slots.last == "" { slots.removeLast() }
            sessionIDs[project.id] = slots
        }
    }
    func projectID(column: Int, bank: Int) -> String? {
        let index = bank * 4 + column
        return (0..<4).contains(column) && projectIDs.indices.contains(index) ? projectIDs[index] : nil
    }
    func sessionID(contentIndex: Int, bank: Int, rowOffset: Int = 0) -> String? {
        guard (0..<12).contains(contentIndex), let project = projectID(column: contentIndex % 4, bank: bank), let sessions = sessionIDs[project] else { return nil }
        let row = contentIndex / 4 + rowOffset
        return sessions.indices.contains(row) && !sessions[row].isEmpty ? sessions[row] : nil
    }
}

/// Both physical rendering and execution use this route. Editing is an independent surface.
enum AppControlRouting {
    static func profile(in configuration: AppConfiguration, targetBundle: String, editingProfileID: String? = nil, physical: Bool) -> AppProfile? {
        if !physical, let editingProfileID, let profile = configuration.profiles.first(where: { $0.id == editingProfileID }) { return profile }
        return configuration.profiles.first { $0.bundleIdentifier == targetBundle } ?? configuration.profiles.first { $0.bundleIdentifier == "*" }
    }
    static func tiles(in configuration: AppConfiguration, targetBundle: String, editingProfileID: String? = nil, physical: Bool) -> [ActionTile] {
        profile(in: configuration, targetBundle: targetBundle, editingProfileID: editingProfileID, physical: physical)?.tiles ?? ActionTile.padded([])
    }
}
