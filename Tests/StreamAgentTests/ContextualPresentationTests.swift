import XCTest
import AppKit
@testable import StreamAgent

final class ContextualPresentationTests: XCTestCase {
    func testProjectAssignmentsSurviveReorderMissingProjectsAndRoundTrip() throws {
        let colors = ProjectColors.assigning(["a", "b", "c", "d"])
        XCTAssertEqual(Set(colors.values).count, 4)
        let changed = ProjectColors.assigning(["d", "new", "a"], to: colors)
        for id in ["a", "b", "c", "d"] { XCTAssertEqual(changed[id], colors[id]) }
        var configuration = AppConfiguration.defaults(); configuration.projectColorAssignments = changed
        let restored = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(restored.projectColorAssignments, changed)
        XCTAssertNoThrow(try restored.validate())
    }
    func testPreviousConfigurationWithoutColorsStillDecodes() throws {
        let encoded = try JSONEncoder().encode(AppConfiguration.defaults())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "projectColorAssignments")
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.projectColorAssignments)
        var bad = decoded; bad.projectColorAssignments = ["project": KeyIdentity.paletteCount]
        XCTAssertThrowsError(try bad.validate())
    }
    func testOpenAppShowsRunningAndCurrentDestinationOnlyWhenAlive() {
        let action = ActionTile.command("App", "app", .openApp, "example.app")
        var context = KeyContextSnapshot()
        XCTAssertEqual(DeckRenderer.contextualPresentation(for: action, focus: .init(), context: context, targetBundle: "example.app").accessory, .none)
        context.runningBundleIDs = ["example.app"]
        XCTAssertEqual(DeckRenderer.contextualPresentation(for: action, focus: .init(), context: context, targetBundle: "other.app").accessory, .running)
        XCTAssertEqual(DeckRenderer.contextualPresentation(for: action, focus: .init(), context: context, targetBundle: "example.app").accessory, .selected)
    }
    func testChosenApplicationPathGetsSameContextAsBundleID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Fixture.app")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let contents = directory.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "com.example.fixture", "CFBundlePackageType": "APPL", "CFBundleExecutable": "Fixture"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        var context = KeyContextSnapshot(); context.runningBundleIDs = ["com.example.fixture"]
        let action = ActionTile.command("App", "app", .openApp, directory.path)
        XCTAssertEqual(ApplicationIdentity.bundleID(for: directory.path), "com.example.fixture")
        XCTAssertEqual(DeckRenderer.contextualPresentation(for: action, focus: .init(), context: context, targetBundle: "com.example.fixture").accessory, .selected)
        XCTAssertEqual(DeckRenderer.contextualPresentation(for: action, focus: .init(), context: context, targetBundle: "other").accessory, .running)
        XCTAssertNil(ApplicationIdentity.bundleID(for: directory.appendingPathComponent("Missing.app").path))
    }
    @MainActor func testQueuedKeyboardCapturesDestinationAndCustomPageFeedbackFollowsTarget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DestinationFixture(pid: 345601, bundle: "com.example.First")
        let second = DestinationFixture(pid: 345602, bundle: "com.example.Second")
        let center = NotificationCenter()
        let tracker = ExternalAppTracker(notificationCenter: center, frontmostApplication: first)
        var sentTo: [pid_t] = []
        let model = AppModel(store: ConfigurationStore(directory: directory), tracker: tracker, keyboardSender: { _, target in
            sentTo.append(target?.processIdentifier ?? 0)
        })
        defer { model.stop() }
        model.addModule(name: "Fixture")
        model.selectedContentIndex = 0
        model.saveTile(.shortcut("Copy", "doc.on.doc", "c"))
        // Queue B's activation before A's command task, while tracker still reads A.
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: second])
        model.runSelected()
        XCTAssertEqual(model.deck[1].accessory, .busy)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(tracker.bundleIdentifier, "com.example.Second")
        XCTAssertEqual(sentTo, [first.processIdentifier], "The queued shortcut must retain the destination selected at key-down")
        XCTAssertFalse([.busy, .success, .failure].contains(model.deck[1].accessory), "B must not display A's action feedback")
    }
    func testMuteReflectsActualOutputAndNeverInventsPlaybackState() {
        var context = KeyContextSnapshot(); context.accessibilityGranted = true
        context.audio = .init(volume: 0.41, muted: true, name: "Test Output")
        let mute = ActionTile.command("Mute", "speaker.slash.fill", .media, "mute")
        let muted = DeckRenderer.contextualPresentation(for: mute, focus: .init(), context: context, targetBundle: "*")
        XCTAssertEqual(muted.symbol, "speaker.slash.fill"); XCTAssertEqual(muted.progress, 0.4)
        XCTAssertEqual(muted.accessory, .selected); XCTAssertTrue(muted.subtitle.contains("Muted"))
        context.audio.muted = false
        XCTAssertEqual(DeckRenderer.contextualPresentation(for: mute, focus: .init(), context: context, targetBundle: "*").symbol, "speaker.wave.2.fill")
        let playback = ActionTile.command("Play", "playpause.fill", .media, "playPause")
        XCTAssertEqual(DeckRenderer.contextualPresentation(for: playback, focus: .init(), context: context, targetBundle: "*").symbol, "playpause.fill")
    }
    func testUnknownVolumeHasNoInventedRingAndMissingPermissionShowsLock() {
        let action = ActionTile.command("Up", "speaker.wave.3.fill", .media, "volumeUp")
        let tile = DeckRenderer.contextualPresentation(for: action, focus: .init(), context: .init(), targetBundle: "*")
        XCTAssertNil(tile.progress); XCTAssertEqual(tile.accessory, .locked); XCTAssertTrue(tile.dimmed)
        let keyboard = ActionTile.shortcut("Copy", "doc.on.doc", "c")
        XCTAssertEqual(DeckRenderer.contextualPresentation(for: keyboard, focus: .init(), context: .init(), targetBundle: "app").accessory, .locked)
    }
    func testFocusPresetSelectionChangesWithDuration() {
        var focus = FocusState(); focus.reset(minutes: 15)
        let fifteen = ActionTile.command("15", "timer", .focus, "15")
        let twentyFive = ActionTile.command("25", "timer", .focus, "25")
        XCTAssertEqual(DeckRenderer.contextualPresentation(for: fifteen, focus: focus, context: .init(), targetBundle: "*").accessory, .selected)
        XCTAssertEqual(DeckRenderer.contextualPresentation(for: twentyFive, focus: focus, context: .init(), targetBundle: "*").accessory, .none)
    }
    @MainActor func testOperationFeedbackDoesNotBleedIntoNewModule() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(store: ConfigurationStore(directory: directory))
        defer { model.stop() }
        let timer = try XCTUnwrap(model.configuration.modules.first { $0.kind == .focus })
        let workspaces = try XCTUnwrap(model.configuration.modules.first { $0.kind == .workspaces })
        model.selectModule(timer.id); model.selectedContentIndex = 0; model.runSelected()
        XCTAssertEqual(model.deck[1].accessory, .busy)
        model.selectModule(workspaces.id)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(model.deck.contains { [.busy, .success, .failure].contains($0.accessory) })
        XCTAssertEqual(model.focus.state.phase, .running)
    }
}

private final class DestinationFixture: NSRunningApplication, @unchecked Sendable {
    private let fixturePID: pid_t
    private let fixtureBundle: String
    init(pid: pid_t, bundle: String) { fixturePID = pid; fixtureBundle = bundle; super.init() }
    override var processIdentifier: pid_t { fixturePID }
    override var bundleIdentifier: String? { fixtureBundle }
    override var localizedName: String? { "Fixture" }
    override var activationPolicy: NSApplication.ActivationPolicy { .regular }
    override var isTerminated: Bool { false }
}
