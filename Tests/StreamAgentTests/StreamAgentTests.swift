import XCTest
import AppKit
import CodexBridge
@testable import StreamAgent

final class LayoutTests: XCTestCase {
    func testFixedNavigationAndRoundTripMapping() {
        XCTAssertEqual([DeckLayout.previous, DeckLayout.home, DeckLayout.next], [0,5,10])
        XCTAssertEqual(DeckLayout.contentKeys, [1,2,3,4,6,7,8,9,11,12,13,14])
        for index in 0..<12 { XCTAssertEqual(DeckLayout.contentIndex(for: DeckLayout.physicalKey(forContent: index)!), index) }
        for key in [0,5,10,-1,15] { XCTAssertNil(DeckLayout.contentIndex(for: key)) }
        XCTAssertNil(DeckLayout.physicalKey(forContent: 12))
        XCTAssertEqual(DeckLayout.adjacentIndex(0, delta: -1, count: 5), 4)
        XCTAssertEqual(DeckLayout.adjacentIndex(4, delta: 1, count: 5), 0)
        XCTAssertEqual(DeckLayout.adjacentIndex(0, delta: -1, count: 1), 0)
        XCTAssertEqual(DeckLayout.adjacentIndex(0, delta: 1, count: 0), 0)
    }
    func testFourColumnsThreeRowsAndBanksRemainStable() {
        var board = StableCodexBoard()
        let projects = (0..<6).map { (id: "p\($0)", sessions: ["\($0)-a", "\($0)-b", "\($0)-c", "\($0)-d"]) }
        board.reconcile(projects: projects, preferred: [], pinned: [])
        XCTAssertEqual(board.bankCount, 2)
        for index in 0..<12 { XCTAssertEqual(board.sessionID(contentIndex: index, bank: 0), "\(index % 4)-\(["a","b","c"][index / 4])") }
        XCTAssertEqual(board.projectID(column: 0, bank: 1), "p4")
        XCTAssertNil(board.projectID(column: 2, bank: 1))
        board.reconcile(projects: projects.reversed().map { ($0.id, $0.sessions.reversed()) }, preferred: [], pinned: [])
        XCTAssertEqual(board.projectID(column: 0, bank: 0), "p0")
        XCTAssertEqual(board.sessionID(contentIndex: 0, bank: 0), "0-a")
        XCTAssertEqual(board.sessionID(contentIndex: 4, bank: 0), "0-b")
        XCTAssertEqual(board.sessionID(contentIndex: 0, bank: 0, rowOffset: 3), "0-d")
    }
    func testVacatedThreadRowDoesNotMoveOtherThreadsAndNewThreadFillsHole() {
        var board = StableCodexBoard()
        board.reconcile(projects: [("p", ["a","b","c"])], preferred: [], pinned: [])
        board.reconcile(projects: [("p", ["c","a"])], preferred: [], pinned: [])
        XCTAssertEqual(board.sessionID(contentIndex: 8, bank: 0), "c")
        XCTAssertNil(board.sessionID(contentIndex: 4, bank: 0))
        board.reconcile(projects: [("p", ["new","c","a"])], preferred: [], pinned: [])
        XCTAssertEqual(board.sessionID(contentIndex: 4, bank: 0), "new")
        XCTAssertEqual(board.sessionID(contentIndex: 8, bank: 0), "c")
    }
    func testTransientMissingProjectDoesNotSlideOtherColumns() {
        var board = StableCodexBoard()
        board.reconcile(projects: [("a", []), ("b", []), ("c", [])], preferred: [], pinned: [])
        board.reconcile(projects: [("a", []), ("c", [])], preferred: [], pinned: [])
        XCTAssertEqual(board.projectIDs, ["a", "b", "c"])
        XCTAssertEqual(board.projectID(column: 2, bank: 0), "c")
    }
    func testPinnedMissingProjectRetainsColumnAndExplicitReorderWorks() {
        var board = StableCodexBoard()
        board.reconcile(projects: [("a", []), ("b", [])], preferred: [], pinned: ["a"])
        board.reconcile(projects: [("b", [])], preferred: [], pinned: ["a"])
        XCTAssertEqual(board.projectIDs, ["a","b"])
        board.reconcile(projects: [("b", [])], preferred: ["b","a"], pinned: ["a"])
        XCTAssertEqual(board.projectIDs, ["b","a"])
    }
}

final class ConfigurationTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func testDefaultsAndAtomicRoundTrip() throws {
        let store = ConfigurationStore(directory: directory), config = AppConfiguration.defaults()
        try config.validate(); try store.save(config)
        XCTAssertEqual(try store.load(), config)
        var changed = config; changed.brightness = 22; try store.save(changed)
        XCTAssertEqual(try store.load().brightness, 22)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["configuration.json"])
    }
    func testDamagedStartupIsNotOverwrittenAndRecoveryPreservesOriginal() throws {
        let store = ConfigurationStore(directory: directory)
        let bad = Data("{broken".utf8); try bad.write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertTrue(store.recoveryRequired)
        XCTAssertThrowsError(try store.save(.defaults()))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bad)
        try store.preserveAndSave(.defaults())
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("configuration-preserved-") }
        XCTAssertEqual(backups.count, 1); XCTAssertEqual(try Data(contentsOf: backups[0]), bad)
        XCTAssertNoThrow(try store.load())
    }
    func testInvalidImportRetainsExistingBytesAndValidImportBacksUp() throws {
        let store = ConfigurationStore(directory: directory), original = AppConfiguration.defaults()
        try store.save(original); let originalData = try Data(contentsOf: store.fileURL)
        let source = directory.appendingPathComponent("import.json")
        var invalid = original; invalid.modules[0].tiles.removeLast()
        try JSONEncoder().encode(invalid).write(to: source)
        XCTAssertThrowsError(try store.importConfiguration(from: source))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), originalData)
        var valid = original; valid.brightness = 40
        try JSONEncoder().encode(valid).write(to: source)
        XCTAssertEqual(try store.importConfiguration(from: source), valid)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("configuration-preserved-") })
        XCTAssertEqual(try Data(contentsOf: backup), originalData)
    }
    func testInvalidSaveAndExportCannotDamageActiveFile() throws {
        let store = ConfigurationStore(directory: directory), config = AppConfiguration.defaults()
        try store.save(config); let bytes = try Data(contentsOf: store.fileURL)
        var invalid = config; invalid.version = 99
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertThrowsError(try store.export(config, to: store.fileURL))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
        invalid = config; invalid.modules[0].tiles[0].action = .init(kind: .openURL, value: "javascript:alert(1)")
        XCTAssertThrowsError(try store.save(invalid))
    }
    private func largeValidConfiguration(urlPadding: Int) -> AppConfiguration {
        var config = AppConfiguration.defaults()
        let value = "https://example.invalid/" + String(repeating: "a", count: urlPadding)
        for moduleIndex in 0..<4 {
            var module = ModuleConfiguration(kind: .custom, name: "Large \(moduleIndex)")
            module.pages = (0..<30).map { pageIndex in
                ActionPage(name: "Page \(pageIndex)", tiles: (0..<12).map { _ in
                    .command("Link", "globe", .openURL, value)
                })
            }
            config.modules.append(module)
        }
        return config
    }
    func testOversizedValidConfigurationCannotReplaceSaveExportOrRecoveryFile() throws {
        let store = ConfigurationStore(directory: directory), original = AppConfiguration.defaults()
        try store.save(original)
        let originalBytes = try Data(contentsOf: store.fileURL)
        let oversized = largeValidConfiguration(urlPadding: 4000)
        try oversized.validate() // Structurally valid: this reproduces the actual review finding.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let oversizedBytes = try encoder.encode(oversized)
        XCTAssertGreaterThan(oversizedBytes.count, ConfigurationStore.maximumBytes)
        XCTAssertThrowsError(try store.encoded(oversized))
        XCTAssertThrowsError(try store.save(oversized))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), originalBytes)
        XCTAssertEqual(try store.load(), original)
        let exportURL = directory.appendingPathComponent("existing-export.json")
        let sentinel = Data("existing export must survive".utf8)
        try sentinel.write(to: exportURL)
        XCTAssertThrowsError(try store.export(oversized, to: exportURL))
        XCTAssertEqual(try Data(contentsOf: exportURL), sentinel)
        XCTAssertThrowsError(try store.preserveAndSave(oversized))
        XCTAssertFalse(store.recoveryRequired)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), originalBytes)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("configuration-preserved-") })
        // A damaged-file recovery must also reject before copying or changing its state.
        let damaged = Data("{damaged".utf8)
        try damaged.write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.preserveAndSave(oversized))
        XCTAssertTrue(store.recoveryRequired)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), damaged)
    }
    func testCompactImportThatWouldGrowOverLimitPreservesActiveBytesWithoutBackup() throws {
        let store = ConfigurationStore(directory: directory), original = AppConfiguration.defaults()
        try store.save(original)
        let originalBytes = try Data(contentsOf: store.fileURL)
        let candidate = largeValidConfiguration(urlPadding: 3100)
        let compact = try JSONEncoder().encode(candidate)
        let pretty = JSONEncoder(); pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
        XCTAssertLessThan(compact.count, ConfigurationStore.maximumBytes)
        XCTAssertGreaterThan(try pretty.encode(candidate).count, ConfigurationStore.maximumBytes)
        XCTAssertEqual(try store.decode(compact), candidate)
        let source = directory.appendingPathComponent("compact-import.json")
        try compact.write(to: source)
        XCTAssertThrowsError(try store.importConfiguration(from: source))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), originalBytes)
        XCTAssertEqual(try store.load(), original)
        XCTAssertFalse(store.recoveryRequired)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("configuration-preserved-") })
    }
    func testLargeAcceptedSaveReloadsAndDecodeUsesExactInclusiveByteLimit() throws {
        let store = ConfigurationStore(directory: directory)
        let accepted = largeValidConfiguration(urlPadding: 2800)
        let canonical = try store.encoded(accepted)
        XCTAssertLessThanOrEqual(canonical.count, ConfigurationStore.maximumBytes)
        XCTAssertGreaterThan(canonical.count, 4_000_000)
        try store.save(accepted)
        XCTAssertEqual(try store.load(), accepted)
        var exactLimit = try store.encoded(.defaults())
        exactLimit.append(Data(repeating: 0x20, count: ConfigurationStore.maximumBytes - exactLimit.count))
        XCTAssertEqual(exactLimit.count, ConfigurationStore.maximumBytes)
        XCTAssertNoThrow(try store.decode(exactLimit))
        exactLimit.append(0x20)
        XCTAssertThrowsError(try store.decode(exactLimit))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), canonical)
    }
    func testCustomPagesAndProfilesPersist() throws {
        let store = ConfigurationStore(directory: directory)
        var config = AppConfiguration.defaults()
        config.modules[1].pages.append(.init(name: "Review"))
        config.modules.append(.init(kind: .custom, name: "Build"))
        try store.save(config)
        XCTAssertEqual(try store.load(), config)
        XCTAssertEqual(try store.load().modules[1].pages[0].tiles.count, 12)
    }
}

final class ActionAndFocusTests: XCTestCase {
    func testKeyboardAndActionValidation() throws {
        XCTAssertNoThrow(try KeyboardShortcutSpec(key: "left", modifiers: [.command, .shift]).validate())
        XCTAssertThrowsError(try KeyboardShortcutSpec(key: "rm -rf /", modifiers: []).validate())
        XCTAssertThrowsError(try KeyboardShortcutSpec(key: "c", modifiers: [.command, .command]).validate())
        for value in ["https://example.com", "mailto:a@example.com", "codex://threads/abc"] { XCTAssertNoThrow(try TileAction(kind: .openURL, value: value).validate()) }
        for value in ["javascript:run()", "file:///tmp/test", "https:", "not a URL"] { XCTAssertThrowsError(try TileAction(kind: .openURL, value: value).validate()) }
        XCTAssertThrowsError(try TileAction(kind: .openFile, value: "relative/path").validate())
        XCTAssertNoThrow(try TileAction(kind: .openApp, value: "com.apple.finder").validate())
        XCTAssertThrowsError(try TileAction(kind: .openApp, value: "/usr/bin/sh").validate())
        XCTAssertThrowsError(try TileAction(kind: .appleShortcut, value: "").validate())
        XCTAssertThrowsError(try TileAction(kind: .media, value: "shell").validate())
    }
    func testFocusPauseResumeResetAndCompletion() {
        let start = Date(timeIntervalSince1970: 1000)
        var state = FocusState(); state.reset(minutes: 5); state.toggle(now: start)
        XCTAssertEqual(state.phase, .running)
        state.tick(now: start.addingTimeInterval(30)); XCTAssertEqual(state.remaining, 270)
        state.toggle(now: start.addingTimeInterval(60)); XCTAssertEqual(state.phase, .paused); XCTAssertEqual(state.remaining, 240)
        state.tick(now: start.addingTimeInterval(999)); XCTAssertEqual(state.remaining, 240)
        state.toggle(now: start.addingTimeInterval(1000)); state.tick(now: start.addingTimeInterval(1240))
        XCTAssertEqual(state.phase, .finished); XCTAssertEqual(state.display, "00:00")
        state.toggle(now: start.addingTimeInterval(1300)); XCTAssertEqual(state.remaining, 300)
        state.reset(minutes: 15); XCTAssertEqual(state.phase, .ready); XCTAssertNil(state.deadline); XCTAssertEqual(state.display, "15:00")
    }
    @MainActor func testEditingDifferentProfileDoesNotChangePhysicalLabelsOrActions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory)
        var config = AppConfiguration.defaults()
        for p in config.profiles.indices { config.profiles[p].tiles[0].label = "Profile \(p)"; config.profiles[p].tiles[0].action = .init(kind: .keyboard, shortcut: .init(key: p == 0 ? "a" : "b")) }
        try store.save(config)
        let model = AppModel(store: store)
        defer { model.stop() }
        let live = try XCTUnwrap(AppControlRouting.profile(in: config, targetBundle: model.tracker.bundleIdentifier, physical: true))
        let editing = try XCTUnwrap(config.profiles.first { $0.id != live.id })
        model.editingProfileID = editing.id; model.refreshDeck()
        XCTAssertEqual(model.deck[1].title, editing.tiles[0].label)
        XCTAssertEqual(model.hardwareDeck[1].title, live.tiles[0].label)
        XCTAssertEqual(model.physicalAction(at: 0), live.tiles[0].action)
        XCTAssertNotEqual(model.hardwareDeck[1].title, model.deck[1].title)
    }
    func testAgentKeysPreferDisplayNameWhileRetainingFullInspectorTitle() {
        let session = AgentSession(id: "agent-1", title: "Long task instructions retained for inspection", projectPath: "/project", projectName: "Project", status: .working, updatedAt: Date(), statusDetail: "Observed running turn", displayName: "Builder")
        let key = DeckRenderer.presentation(for: session)
        XCTAssertEqual(key.title, "Builder")
        XCTAssertEqual(key.subtitle, "Working")
        XCTAssertEqual(session.title, "Long task instructions retained for inspection")
    }
    func testDiffSkipsUnchangedAndUpdatesOnlyChangedKey() {
        let old = (0..<15).map { DeckTilePresentation(title: "\($0)", symbol: "square") }
        let cache = Dictionary(uniqueKeysWithValues: old.enumerated().map { ($0.offset, $0.element) })
        XCTAssertEqual(DeckDiff.changedKeys(previous: cache, current: old), [])
        var changed = old; changed[1].title = "24:59"
        XCTAssertEqual(DeckDiff.changedKeys(previous: cache, current: changed), [])
        changed[1].symbol = "play.fill"
        XCTAssertEqual(DeckDiff.changedKeys(previous: cache, current: changed), [1])
    }
    func testRendererProducesNativePixels() {
        let image = DeckRenderer.image(.init(title: "Working", subtitle: "Local", symbol: "gearshape", tint: .blue))
        XCTAssertEqual(image.size.width, 72)
        XCTAssertGreaterThan(image.tiffRepresentation?.count ?? 0, 0)
    }
    func testKeyPixelsNeverContainNamesOrStatusCaptions() throws {
        let original = DeckTilePresentation(title: "Private agent name", subtitle: "Working", symbol: "arrow.triangle.2.circlepath", tint: .blue)
        var renamed = original; renamed.title = "Different project and agent"; renamed.subtitle = "Different status caption"
        XCTAssertEqual(try XCTUnwrap(DeckRenderer.image(original).tiffRepresentation), try XCTUnwrap(DeckRenderer.image(renamed).tiffRepresentation))
        var empty = original; empty.isEmpty = true
        renamed.isEmpty = true; renamed.symbol = "folder"; renamed.tint = .red
        XCTAssertEqual(DeckRenderer.image(empty).tiffRepresentation, DeckRenderer.image(renamed).tiffRepresentation)
    }
    func testWideAndTallSymbolsFitWithoutStretchingOrEdgeClipping() {
        let bounds = NSRect(x: 0, y: 0, width: 72, height: 72)
        for size in [NSSize(width: 60, height: 20), NSSize(width: 20, height: 60)] {
            let rect = DeckRenderer.symbolRect(for: size, in: bounds, inset: DeckRenderer.symbolInset)
            XCTAssertEqual(rect.width / rect.height, size.width / size.height, accuracy: 0.001)
            XCTAssertEqual(rect.midX, 36); XCTAssertEqual(rect.midY, 36)
            XCTAssertTrue(bounds.insetBy(dx: 15, dy: 15).contains(rect))
        }
    }
    func testAllAgentStatesHaveDistinctAvailableAppleSymbols() {
        let symbols = AgentStatus.allCases.map { status in
            DeckRenderer.presentation(for: AgentSession(id: "agent", title: "Agent", projectPath: "/project", projectName: "Project", status: status, updatedAt: Date(), statusDetail: "Fixture")).symbol
        }
        XCTAssertEqual(Set(symbols).count, AgentStatus.allCases.count)
        for name in symbols { XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name) }
    }
    func testGenericFocusPresetsStayDistinctAcrossAnyActionPage() {
        let symbols = ["5", "15", "25", "45", "60"].map { minutes in
            DeckRenderer.presentation(for: .command("Duration", "timer", .focus, minutes), focus: FocusState()).symbol
        }
        XCTAssertEqual(Set(symbols).count, 5)
        for name in symbols { XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name) }
        let customized = ActionTile.command("Duration", "star", .focus, "25")
        XCTAssertEqual(DeckRenderer.presentation(for: customized, focus: FocusState()).symbol, "star")
        var state = FocusState(); state.toggle()
        let start = DeckRenderer.presentation(for: .command("Start", "playpause", .focus, "startPause"), focus: state)
        XCTAssertEqual(start.symbol, "pause.fill"); XCTAssertEqual(start.progress, 1)
        XCTAssertEqual(start.title, "Start · 25:00")
        XCTAssertEqual(DeckRenderer.presentation(for: .command("", "playpause", .focus, "startPause"), focus: state).title, "Start / Pause · 25:00")
    }
    func testLegacyWorkspaceDefaultsGainDistinctFacesWithoutChangingSavedTiles() {
        let finder = ActionTile.command("Finder", "folder", .openApp, "com.apple.finder")
        let apps = ActionTile.command("Applications", "folder", .openFile, "/Applications")
        let finderFace = DeckRenderer.presentation(for: finder, focus: FocusState())
        let appsFace = DeckRenderer.presentation(for: apps, focus: FocusState())
        XCTAssertNotEqual(finderFace.symbol, appsFace.symbol)
        XCTAssertEqual(finder.symbol, "folder"); XCTAssertEqual(apps.symbol, "folder")
        for name in [finderFace.symbol, appsFace.symbol] { XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name) }
    }
}
