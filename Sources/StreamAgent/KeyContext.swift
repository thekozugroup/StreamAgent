import AppKit
import ApplicationServices
import Combine
import CoreAudio

struct OutputAudioState: Equatable {
    var volume: Double? = nil
    var muted: Bool? = nil
    var name: String = ""
}

struct KeyContextSnapshot: Equatable {
    var runningBundleIDs: Set<String> = []
    var audio: OutputAudioState = .init()
    var accessibilityGranted: Bool = false
}

// Each registration owns its exact removal arguments. Releasing a monitor also
// releases these tokens, without calling actor-isolated methods from deinit.
final class KeyContextObservation {
    private let cancel: () -> Void
    init(cancel: @escaping () -> Void) { self.cancel = cancel }
    deinit { cancel() }
}

protocol OutputAudioReading {
    func defaultOutputDevice() -> AudioObjectID?
    func state(for device: AudioObjectID) -> OutputAudioState
    func observe(_ object: AudioObjectID, address: AudioObjectPropertyAddress,
                 changed: @escaping @Sendable () -> Void) -> KeyContextObservation?
}

final class CoreAudioOutputReader: OutputAudioReading {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    // Missing, failed, nonfinite, or invalid readings are unknown, never silence.
    static func state(name: String, scalar: Float32?, mute: UInt32?) -> OutputAudioState {
        let volume = scalar.flatMap { value -> Double? in
            guard value.isFinite, (0...1).contains(value) else { return nil }
            return Double(value)
        }
        let muted = mute.flatMap { value -> Bool? in
            guard value <= 1 else { return nil }
            return value == 1
        }
        return OutputAudioState(volume: volume, muted: muted, name: name)
    }

    func defaultOutputDevice() -> AudioObjectID? {
        let device: UInt32? = scalar(AudioObjectID(kAudioObjectSystemObject),
                                    Self.address(kAudioHardwarePropertyDefaultOutputDevice), initial: UInt32(0))
        return device.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    func state(for device: AudioObjectID) -> OutputAudioState {
        guard device != kAudioObjectUnknown else { return .init() }
        let alive: UInt32? = scalar(device, Self.address(kAudioDevicePropertyDeviceIsAlive), initial: UInt32(0))
        if alive == 0 { return .init() }
        let volume: Float32? = scalar(device, Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput), initial: Float32.nan)
        let mute: UInt32? = scalar(device, Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput), initial: UInt32.max)
        // A device without a main output control is deliberately unknown. A
        // channel level or a playback app's level cannot establish device volume.
        return Self.state(name: name(for: device), scalar: volume, mute: mute)
    }

    private func scalar<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) -> T? {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        var reportedSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &reportedSize) == noErr,
              reportedSize == size else { return nil }
        var value = initial
        let status = withUnsafeMutableBytes(of: &value) { bytes in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr, size == reportedSize else { return nil }
        return value
    }

    private func name(for device: AudioObjectID) -> String {
        var address = Self.address(kAudioObjectPropertyName)
        guard AudioObjectHasProperty(device, &address) else { return "" }
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name else { return "" }
        // CoreAudio's object-name property transfers ownership to its caller.
        return name.takeRetainedValue() as String
    }

    func observe(_ object: AudioObjectID, address: AudioObjectPropertyAddress,
                 changed: @escaping @Sendable () -> Void) -> KeyContextObservation? {
        var registrationAddress = address
        let queue = DispatchQueue.main
        let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
        guard AudioObjectAddPropertyListenerBlock(object, &registrationAddress, queue, block) == noErr else { return nil }
        return KeyContextObservation {
            var removalAddress = address
            _ = AudioObjectRemovePropertyListenerBlock(object, &removalAddress, queue, block)
        }
    }
}

@MainActor
final class KeyContextMonitor: ObservableObject {
    @Published private(set) var snapshot: KeyContextSnapshot
    var didChange: (() -> Void)?

    private let audioReader: OutputAudioReading
    private let workspaceCenter: NotificationCenter
    private let runningBundleIDs: () -> Set<String>
    private let accessibilityGranted: () -> Bool
    private var workspaceObservations: [KeyContextObservation] = []
    private var systemObservation: KeyContextObservation?
    private var outputObservations: [KeyContextObservation] = []
    private var listeningDevice: AudioObjectID?
    private var running = false
    private var lifecycle: UInt = 0
    private var outputGeneration: UInt = 0

    convenience init() {
        let workspace = NSWorkspace.shared
        self.init(audioReader: CoreAudioOutputReader(), workspaceCenter: workspace.notificationCenter,
                  runningBundleIDs: {
                      Set(workspace.runningApplications.filter { !$0.isTerminated }
                        .compactMap(\.bundleIdentifier).filter { !$0.isEmpty })
                  }, accessibilityGranted: { AXIsProcessTrusted() })
    }

    // Injectable read-only sources let tests exercise delivery and teardown without
    // launching apps, changing sound settings, or requesting any permissions.
    init(audioReader: OutputAudioReading, workspaceCenter: NotificationCenter,
         runningBundleIDs: @escaping () -> Set<String>, accessibilityGranted: @escaping () -> Bool) {
        self.audioReader = audioReader
        self.workspaceCenter = workspaceCenter
        self.runningBundleIDs = runningBundleIDs
        self.accessibilityGranted = accessibilityGranted
        snapshot = .init()
        refresh() // Construction reads once and does not subscribe or persist.
    }

    func start() {
        guard !running else { return }
        running = true
        lifecycle &+= 1
        let token = lifecycle
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                      NSWorkspace.didActivateApplicationNotification] {
            let center = workspaceCenter
            let observer = center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.running, self.lifecycle == token else { return }
                    self.refresh()
                }
            }
            workspaceObservations.append(KeyContextObservation { center.removeObserver(observer) })
        }
        systemObservation = audioReader.observe(AudioObjectID(kAudioObjectSystemObject),
                                                address: CoreAudioOutputReader.address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.lifecycle == token else { return }
                self.refresh()
            }
        }
        refresh()
    }

    func stop() {
        running = false
        lifecycle &+= 1
        outputGeneration &+= 1
        workspaceObservations.removeAll()
        systemObservation = nil
        outputObservations.removeAll()
        listeningDevice = nil
    }

    func refresh() {
        let updated = KeyContextSnapshot(runningBundleIDs: runningBundleIDs(), audio: readCurrentOutput(),
                                         accessibilityGranted: accessibilityGranted())
        guard snapshot != updated else { return }
        snapshot = updated
        didChange?()
    }

    private func readCurrentOutput() -> OutputAudioState {
        // Subscribe before reading. Recheck the default after the read so a device
        // switch during CoreAudio calls never publishes the old device as current.
        for _ in 0..<3 {
            let device = audioReader.defaultOutputDevice()
            if running { observeOutput(device) }
            let state = device.map { audioReader.state(for: $0) } ?? .init()
            if audioReader.defaultOutputDevice() == device { return state }
        }
        // A rapidly changing/disappearing output is unknown until the next event.
        if running { observeOutput(audioReader.defaultOutputDevice()) }
        return .init()
    }

    private func observeOutput(_ device: AudioObjectID?) {
        guard listeningDevice != device else { return }
        outputGeneration &+= 1
        outputObservations.removeAll()
        listeningDevice = device
        guard let device else { return }
        let token = lifecycle
        let deviceToken = outputGeneration
        let addresses = [
            CoreAudioOutputReader.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput),
            CoreAudioOutputReader.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput),
            CoreAudioOutputReader.address(kAudioObjectPropertyName),
            CoreAudioOutputReader.address(kAudioDevicePropertyDeviceIsAlive)
        ]
        for address in addresses {
            if let observation = audioReader.observe(device, address: address, changed: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.running, self.lifecycle == token,
                          self.outputGeneration == deviceToken, self.listeningDevice == device else { return }
                    self.refresh()
                }
            }) { outputObservations.append(observation) }
        }
    }
}
