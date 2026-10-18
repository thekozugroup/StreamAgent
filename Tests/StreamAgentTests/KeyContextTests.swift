import AppKit
import CoreAudio
import XCTest
@testable import StreamAgent

final class KeyContextTests: XCTestCase {
    func testDefaultsAreUnknownAndNotSilentOrUnmuted() {
        XCTAssertNil(OutputAudioState().volume)
        XCTAssertNil(OutputAudioState().muted)
        XCTAssertEqual(OutputAudioState().name, "")
        XCTAssertEqual(KeyContextSnapshot().runningBundleIDs, [])
        XCTAssertFalse(KeyContextSnapshot().accessibilityGranted)
        XCTAssertEqual(CoreAudioOutputReader.state(name: "", scalar: nil, mute: nil), .init())
    }

    func testAudioReadValidationPreservesZeroAndIndependentUnknownValues() {
        XCTAssertEqual(CoreAudioOutputReader.state(name: "Fixture", scalar: 0, mute: 0),
                       OutputAudioState(volume: 0, muted: false, name: "Fixture"))
        XCTAssertEqual(CoreAudioOutputReader.state(name: "Fixture", scalar: 1, mute: 1),
                       OutputAudioState(volume: 1, muted: true, name: "Fixture"))
        XCTAssertEqual(CoreAudioOutputReader.state(name: "", scalar: 0.5, mute: nil),
                       OutputAudioState(volume: 0.5))
        XCTAssertEqual(CoreAudioOutputReader.state(name: "", scalar: nil, mute: 0),
                       OutputAudioState(muted: false))
        for invalid in [Float32.nan, .infinity, -.infinity, -0.01, 1.01] {
            XCTAssertNil(CoreAudioOutputReader.state(name: "", scalar: invalid, mute: 0).volume)
        }
        XCTAssertNil(CoreAudioOutputReader.state(name: "", scalar: 0, mute: 2).muted)
        XCTAssertNil(CoreAudioOutputReader.state(name: "", scalar: 0, mute: .max).muted)
    }

    @MainActor
    func testConstructionOnlyReadsAndRefreshPublishesActualChanges() {
        let input = ContextInputFixture()
        let reader = AudioReaderFixture()
        let monitor = makeMonitor(reader, input: input)
        XCTAssertEqual(monitor.snapshot.runningBundleIDs, ["com.example.One"])
        XCTAssertEqual(monitor.snapshot.audio, reader.states[100])
        XCTAssertFalse(monitor.snapshot.accessibilityGranted)
        XCTAssertTrue(reader.registrations.isEmpty)
        var changes = 0
        monitor.didChange = { changes += 1 }
        monitor.refresh()
        XCTAssertEqual(changes, 0)
        input.bundleIDs = ["com.example.Two"]
        input.accessibility = true
        reader.states[100] = OutputAudioState(name: "Unknown controls")
        monitor.refresh()
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(monitor.snapshot.audio, OutputAudioState(name: "Unknown controls"))
        XCTAssertEqual(monitor.snapshot.runningBundleIDs, input.bundleIDs)
        XCTAssertTrue(monitor.snapshot.accessibilityGranted)
        XCTAssertTrue(reader.registrations.isEmpty)
    }

    @MainActor
    func testStartStopAreIdempotentAndRegisterExactOutputScopes() {
        let reader = AudioReaderFixture()
        let monitor = makeMonitor(reader)
        monitor.start(); monitor.start()
        XCTAssertEqual(reader.active.count, 5)
        XCTAssertEqual(reader.registrations.count, 5)
        let system = reader.registrations.filter { $0.object == kAudioObjectSystemObject }
        XCTAssertEqual(system.map(\.address.mSelector), [kAudioHardwarePropertyDefaultOutputDevice])
        XCTAssertEqual(system.map(\.address.mScope), [kAudioObjectPropertyScopeGlobal])
        let output = reader.registrations.filter { $0.object == 100 }
        XCTAssertEqual(Set(output.map(\.address.mSelector)), [kAudioDevicePropertyVolumeScalar,
            kAudioDevicePropertyMute, kAudioObjectPropertyName, kAudioDevicePropertyDeviceIsAlive])
        XCTAssertTrue(output.allSatisfy { $0.address.mElement == kAudioObjectPropertyElementMain })
        XCTAssertTrue(output.filter { [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute].contains($0.address.mSelector) }
            .allSatisfy { $0.address.mScope == kAudioDevicePropertyScopeOutput })
        monitor.stop(); monitor.stop()
        XCTAssertTrue(reader.active.isEmpty)
        XCTAssertEqual(reader.removals.sorted(), reader.registrations.map(\.id).sorted())
        monitor.start()
        XCTAssertEqual(reader.active.count, 5)
        monitor.stop()
        XCTAssertEqual(reader.removals.count, 10)
    }

    @MainActor
    func testOutputSwitchRemovesOldListenersAndRejectsQueuedOldCallbacks() async {
        let reader = AudioReaderFixture()
        let monitor = makeMonitor(reader)
        monitor.start()
        let old = reader.registrations.filter { $0.object == 100 }
        reader.device = 200
        monitor.refresh()
        XCTAssertEqual(monitor.snapshot.audio, reader.states[200])
        XCTAssertTrue(old.allSatisfy { reader.removals.contains($0.id) })
        XCTAssertEqual(reader.active.count, 5)

        let reads = reader.stateReads
        reader.states[200] = OutputAudioState(volume: 0.25, muted: true, name: "Second")
        old.forEach { $0.changed() }
        await drainCallbacks()
        XCTAssertEqual(reader.stateReads, reads, "Callbacks from retired registrations must be ignored")
        XCTAssertEqual(monitor.snapshot.audio.volume, 0.75)

        reader.registrations.last { $0.object == 200 && $0.address.mSelector == kAudioDevicePropertyMute }?.changed()
        await drainCallbacks()
        XCTAssertEqual(monitor.snapshot.audio, reader.states[200])
        reader.device = nil
        reader.registrations.first { $0.object == kAudioObjectSystemObject }?.changed()
        await drainCallbacks()
        XCTAssertEqual(monitor.snapshot.audio, .init())
        XCTAssertEqual(reader.active.count, 1)
        monitor.stop()
    }

    @MainActor
    func testQueuedCallbacksCannotRefreshAfterStopOrPreviousStart() async {
        let reader = AudioReaderFixture()
        let input = ContextInputFixture()
        let center = NotificationCenter()
        let monitor = makeMonitor(reader, input: input, center: center)
        monitor.start()
        let previous = reader.registrations
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        previous.forEach { $0.changed() }
        monitor.stop()
        input.bundleIDs = ["com.example.Stopped"]
        let reads = reader.stateReads
        await drainCallbacks()
        XCTAssertEqual(reader.stateReads, reads)
        XCTAssertEqual(monitor.snapshot.runningBundleIDs, ["com.example.One"])
        monitor.start()
        reader.states[100] = OutputAudioState(volume: 0.9)
        let restartedReads = reader.stateReads
        previous.forEach { $0.changed() }
        await drainCallbacks()
        XCTAssertEqual(reader.stateReads, restartedReads)
        XCTAssertEqual(monitor.snapshot.runningBundleIDs, input.bundleIDs)
        monitor.stop()
    }

    @MainActor
    func testWorkspaceLaunchTerminationAndActivationRefreshSnapshotAndTrust() async {
        let reader = AudioReaderFixture()
        let input = ContextInputFixture()
        let center = NotificationCenter()
        let monitor = makeMonitor(reader, input: input, center: center)
        monitor.start()
        input.bundleIDs.insert("com.example.Two")
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        await drainCallbacks()
        XCTAssertEqual(monitor.snapshot.runningBundleIDs, input.bundleIDs)
        input.bundleIDs.remove("com.example.One")
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        await drainCallbacks()
        XCTAssertEqual(monitor.snapshot.runningBundleIDs, input.bundleIDs)
        input.accessibility = true
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await drainCallbacks()
        XCTAssertTrue(monitor.snapshot.accessibilityGranted)
        monitor.stop()
        let reads = reader.stateReads
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await drainCallbacks()
        XCTAssertEqual(reader.stateReads, reads)
    }

    @MainActor
    func testDeviceSwitchDuringReadCannotPublishOldDevice() {
        let reader = AudioReaderFixture()
        let monitor = makeMonitor(reader)
        monitor.start()
        var switches = 0
        reader.onRead = { device in
            if device == 100 { reader.device = 200; switches += 1 }
        }
        monitor.refresh()
        XCTAssertEqual(switches, 1)
        XCTAssertEqual(monitor.snapshot.audio, reader.states[200])
        XCTAssertTrue(reader.registrations.filter { reader.active.contains($0.id) }
            .allSatisfy { $0.object == kAudioObjectSystemObject || $0.object == 200 })
        reader.onRead = nil
        monitor.stop()
    }

    @MainActor
    func testContinuousSwitchingIsBoundedAndPublishesUnknown() {
        let reader = AudioReaderFixture()
        let monitor = makeMonitor(reader)
        monitor.start()
        reader.onRead = { device in reader.device = device == 100 ? 200 : 100 }
        let reads = reader.stateReads
        monitor.refresh()
        XCTAssertEqual(reader.stateReads - reads, 3)
        XCTAssertEqual(monitor.snapshot.audio, .init())
        XCTAssertEqual(reader.active.count, 5)
        reader.onRead = nil
        monitor.stop()
    }

    @MainActor
    func testDeinitRemovesEverySuccessfulRegistrationEvenWithoutStop() async {
        let reader = AudioReaderFixture()
        reader.failedSelector = kAudioDevicePropertyMute
        var monitor: KeyContextMonitor? = makeMonitor(reader)
        monitor?.start()
        XCTAssertEqual(reader.active.count, 4)
        let callbacks = reader.registrations
        monitor = nil
        XCTAssertTrue(reader.active.isEmpty)
        XCTAssertEqual(reader.removals.sorted(), reader.registrations.map(\.id).sorted())
        callbacks.forEach { $0.changed() }
        await drainCallbacks()
        XCTAssertTrue(reader.active.isEmpty)
    }

    @MainActor
    func testLiveSnapshotIsReadOnlyAndAnyVolumeIsFiniteAndNormalized() {
        let monitor = KeyContextMonitor()
        if let volume = monitor.snapshot.audio.volume {
            XCTAssertTrue(volume.isFinite)
            XCTAssertTrue((0...1).contains(volume))
        }
        monitor.start()
        monitor.refresh()
        if let volume = monitor.snapshot.audio.volume {
            XCTAssertTrue(volume.isFinite)
            XCTAssertTrue((0...1).contains(volume))
        }
        monitor.stop()
        // Do not assert a particular output, permission, bundle, or mute state,
        // and do not print or persist anything observed on the real machine.
    }

    @MainActor
    private func makeMonitor(_ reader: AudioReaderFixture, input: ContextInputFixture = .init(),
                             center: NotificationCenter = .init()) -> KeyContextMonitor {
        KeyContextMonitor(audioReader: reader, workspaceCenter: center,
                          runningBundleIDs: { input.bundleIDs }, accessibilityGranted: { input.accessibility })
    }

    @MainActor
    private func drainCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

final class ExternalAppTrackerContextTests: XCTestCase {
    @MainActor
    func testRememberedPIDTerminationClearsTargetAndDisplayButUnrelatedExitDoesNot() async {
        let center = NotificationCenter()
        let target = RunningAppFixture(pid: 123456, name: "Fixture", bundle: "com.example.Fixture")
        let other = RunningAppFixture(pid: 123457, name: "Other", bundle: "com.example.Other")
        let tracker = ExternalAppTracker(notificationCenter: center, frontmostApplication: target)
        var changes = 0
        tracker.didChange = { changes += 1 }
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: other])
        await drainCallbacks()
        XCTAssertTrue(tracker.lastApplication === target)
        XCTAssertEqual(changes, 0)
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: target])
        await drainCallbacks()
        XCTAssertNil(tracker.lastApplication)
        XCTAssertEqual(tracker.name, "No external app")
        XCTAssertEqual(tracker.bundleIdentifier, "*")
        XCTAssertEqual(changes, 1)
    }

    @MainActor
    func testSelfBackgroundAndTerminatedAppsCannotReplaceTarget() async {
        let center = NotificationCenter()
        let target = RunningAppFixture(pid: 123456, name: "Fixture", bundle: "com.example.Fixture")
        let tracker = ExternalAppTracker(notificationCenter: center, frontmostApplication: target)
        let own = RunningAppFixture(pid: ProcessInfo.processInfo.processIdentifier, name: "Own", bundle: "com.example.Own")
        let background = RunningAppFixture(pid: 123457, name: "Background", bundle: "com.example.Background", policy: .accessory)
        let ended = RunningAppFixture(pid: 123458, name: "Ended", bundle: "com.example.Ended", terminated: true)
        for app in [own, background, ended] {
            center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                        userInfo: [NSWorkspace.applicationUserInfoKey: app])
        }
        await drainCallbacks()
        XCTAssertTrue(tracker.lastApplication === target)
        XCTAssertEqual(tracker.name, "Fixture")
        XCTAssertEqual(tracker.bundleIdentifier, "com.example.Fixture")
    }

    @MainActor
    private func drainCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

private final class ContextInputFixture {
    var bundleIDs: Set<String> = ["com.example.One"]
    var accessibility = false
}

private final class AudioReaderFixture: OutputAudioReading {
    struct Registration {
        let id: Int
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let changed: @Sendable () -> Void
    }
    var device: AudioObjectID? = 100
    var states: [AudioObjectID: OutputAudioState] = [
        100: .init(volume: 0.5, muted: false, name: "First"),
        200: .init(volume: 0.75, muted: false, name: "Second")
    ]
    var registrations: [Registration] = []
    var active: Set<Int> = []
    var removals: [Int] = []
    var stateReads = 0
    var onRead: ((AudioObjectID) -> Void)?
    var failedSelector: AudioObjectPropertySelector?

    func defaultOutputDevice() -> AudioObjectID? { device }
    func state(for device: AudioObjectID) -> OutputAudioState {
        stateReads += 1
        let result = states[device] ?? .init()
        onRead?(device)
        return result
    }
    func observe(_ object: AudioObjectID, address: AudioObjectPropertyAddress,
                 changed: @escaping @Sendable () -> Void) -> KeyContextObservation? {
        guard address.mSelector != failedSelector else { return nil }
        let id = registrations.count
        registrations.append(Registration(id: id, object: object, address: address, changed: changed))
        active.insert(id)
        return KeyContextObservation { [weak self] in
            self?.active.remove(id)
            self?.removals.append(id)
        }
    }
}

private final class RunningAppFixture: NSRunningApplication, @unchecked Sendable {
    let fixturePID: pid_t
    let fixtureName: String
    let fixtureBundle: String
    let fixturePolicy: NSApplication.ActivationPolicy
    let fixtureTerminated: Bool
    init(pid: pid_t, name: String, bundle: String, policy: NSApplication.ActivationPolicy = .regular, terminated: Bool = false) {
        fixturePID = pid; fixtureName = name; fixtureBundle = bundle
        fixturePolicy = policy; fixtureTerminated = terminated
        super.init()
    }
    override var processIdentifier: pid_t { fixturePID }
    override var localizedName: String? { fixtureName }
    override var bundleIdentifier: String? { fixtureBundle }
    override var activationPolicy: NSApplication.ActivationPolicy { fixturePolicy }
    override var isTerminated: Bool { fixtureTerminated }
}
