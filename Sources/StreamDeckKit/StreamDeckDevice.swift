import AppKit
import Combine
import IOKit.hid

/// Native, non-exclusive HID controller. Logical key indices run left-to-right,
/// top-to-bottom (0...14). Keep the instance alive between start() and stop().
public final class StreamDeckDevice: ObservableObject {
    @Published public private(set) var isConnected = false
    @Published public private(set) var modelName = "Stream Deck"
    @Published public private(set) var statusMessage = "Stopped"
    @Published public private(set) var reportsSent = 0
    @Published public private(set) var keyPressCount = 0
    @Published public private(set) var lastKeyIndex: Int?
    public var onKeyDown: ((Int) -> Void)?

    private let runtime = StreamDeckHIDRuntime()
    private let renderLock = NSLock()
    private var renderRequests: [Int: NSImage] = [:]
    private var renderOrder: [Int] = []
    private var renderScheduled = false

    public init() {
        runtime.publish = { [weak self] update in
            precondition(Thread.isMainThread)
            guard let self else { return }
            switch update {
            case let .connection(connected, name, message):
                modelName = name
                statusMessage = message
                isConnected = connected
            case let .reports(count): reportsSent += count
            case let .key(index):
                lastKeyIndex = index
                keyPressCount += 1
                onKeyDown?(index)
            case let .message(message): statusMessage = message
            }
        }
    }

    deinit {
        let runtime = runtime
        if Thread.isMainThread { runtime.stop() }
        else { DispatchQueue.main.async { runtime.stop() } }
    }

    public func start() { onMain { $0.runtime.start() } }
    public func stop() { onMain { $0.runtime.stop() } }

    public func setBrightness(_ percent: Int) {
        onMain { $0.runtime.pump.brightness(percent) }
    }

    public func setKeyImage(_ image: NSImage, key: Int) {
        guard (0..<15).contains(key) else {
            onMain { $0.statusMessage = "Invalid key index \(key); expected 0...14" }
            return
        }
        // Bound requests before hopping to main, including background callers.
        renderLock.lock()
        if renderRequests[key] == nil { renderOrder.append(key) }
        renderRequests[key] = image
        if !renderScheduled {
            renderScheduled = true
            DispatchQueue.main.async { [weak self] in self?.renderNext() }
        }
        renderLock.unlock()
    }

    public func clearImageCache() { runtime.pump.clearCache() }

    private func renderNext() {
        precondition(Thread.isMainThread)
        renderLock.lock()
        let key = renderOrder.isEmpty ? nil : renderOrder.removeFirst()
        let image = key.flatMap { renderRequests.removeValue(forKey: $0) }
        renderLock.unlock()
        if let key, let image {
            if let raster = StreamDeckImageEncoder.rasterize(image) { runtime.pump.image(raster, key: key) }
            else { statusMessage = "Unable to render image for key \(key)" }
        }
        renderLock.lock()
        if renderRequests.isEmpty { renderScheduled = false }
        else { DispatchQueue.main.async { [weak self] in self?.renderNext() } }
        renderLock.unlock()
    }

    private func onMain(_ body: @escaping (StreamDeckDevice) -> Void) {
        if Thread.isMainThread { body(self) }
        else { DispatchQueue.main.async { [weak self] in if let self { body(self) } } }
    }
}

private enum StreamDeckUpdate {
    case connection(Bool, String, String), reports(Int), key(Int), message(String)
}

// All discovery, registrations, input parsing and publication are main-run-loop
// confined. Device writes and closes share pump.queue; close cannot race a write.
private final class StreamDeckHIDRuntime {
    let pump = StreamDeckWritePump()
    var publish: ((StreamDeckUpdate) -> Void)?
    private var manager: IOHIDManager?
    private var managerIsOpen = false
    private var session: StreamDeckHIDSession?
    private var retry: Timer?
    private var generation = 0

    init() {
        pump.onResult = { [weak self] output, count, result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if count > 0 { publish?(.reports(count)) }
                guard session?.output === output, result != kIOReturnSuccess else { return }
                let name = session!.model.name
                disconnect()
                publish?(.connection(false, name, Self.failure(result, operation: "HID write")))
            }
        }
    }

    func start() {
        precondition(Thread.isMainThread)
        guard manager == nil else { return }
        generation += 1
        publish?(.connection(false, "Stream Deck", "Searching for Stream Deck"))
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
        self.manager = manager
        let matches = StreamDeckModel.allCases.map {
            [kIOHIDVendorIDKey: 0x0FD9, kIOHIDProductIDKey: $0.rawValue]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard let context else { return }
            let runtime = Unmanaged<StreamDeckHIDRuntime>.fromOpaque(context).takeUnretainedValue()
            runtime.matched(device, result: result)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let runtime = Unmanaged<StreamDeckHIDRuntime>.fromOpaque(context).takeUnretainedValue()
            guard let session = runtime.session, CFEqual(session.device, device) else { return }
            let name = session.model.name
            runtime.disconnect()
            runtime.publish?(.connection(false, name, "Stream Deck disconnected; waiting for reconnect"))
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        retry = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.discover() }
        RunLoop.main.add(retry!, forMode: .common)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            publish?(.message(Self.failure(result, operation: "HID discovery")))
            return
        }
        managerIsOpen = true
        discover()
    }

    func stop() {
        precondition(Thread.isMainThread)
        generation += 1
        let stoppedGeneration = generation
        retry?.invalidate(); retry = nil
        if let manager {
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        managerIsOpen = false
        disconnect()
        publish?(.connection(false, "Stream Deck", "Stopping"))
        // Retain runtime through the final queue barrier, including owner deinit.
        pump.queue.async { [self] in
            DispatchQueue.main.async { [self] in
                if generation == stoppedGeneration { publish?(.connection(false, "Stream Deck", "Stopped")) }
            }
        }
    }

    private func discover() {
        guard let manager, session == nil else { return }
        if !managerIsOpen {
            let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            guard result == kIOReturnSuccess else {
                publish?(.message(Self.failure(result, operation: "HID discovery")))
                return
            }
            managerIsOpen = true
        }
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        if devices.isEmpty { publish?(.message("No supported Stream Deck found; waiting for connection")) }
        for device in devices {
            matched(device, result: kIOReturnSuccess)
            if session != nil { break }
        }
    }

    private func matched(_ device: IOHIDDevice, result: IOReturn) {
        guard manager != nil, session == nil,
              let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber,
              let model = StreamDeckModel(rawValue: pid.intValue) else { return }
        guard result == kIOReturnSuccess else {
            publish?(.connection(false, model.name, Self.failure(result, operation: "HID match")))
            return
        }
        // Never seize the device or interfere with another application's process.
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else {
            publish?(.connection(false, model.name, Self.failure(opened, operation: "HID open")))
            return
        }
        let session = StreamDeckHIDSession(device: device, model: model)
        self.session = session
        session.onKeys = { [weak self, weak session] keys in
            guard let self, let session, self.session === session else { return }
            for key in keys {
                guard self.session === session else { break }
                publish?(.key(key))
            }
        }
        session.register()
        pump.connect(session.output)
        publish?(.connection(true, model.name, "Connected to \(model.name)"))
    }

    private func disconnect() {
        pump.connect(nil)
        guard let session else { return }
        self.session = nil
        session.unregister()
        pump.queue.async { session.close() }
    }

    private static func failure(_ result: IOReturn, operation: String) -> String {
        let code = String(format: "0x%08X", UInt32(bitPattern: result))
        switch result {
        case kIOReturnNotPermitted, kIOReturnNotPrivileged:
            return "\(operation) denied (\(code)). Allow Input Monitoring in System Settings > Privacy & Security, then restart this app."
        case kIOReturnExclusiveAccess, kIOReturnBusy:
            return "\(operation) busy (\(code)). Another app may own the device; waiting to retry."
        case kIOReturnNoDevice, kIOReturnNotOpen, kIOReturnOffline:
            return "\(operation) lost connection (\(code)); waiting to reconnect."
        default: return "\(operation) failed (\(code)); check USB connection and device access."
        }
    }
}

private final class StreamDeckHIDSession {
    let device: IOHIDDevice
    let model: StreamDeckModel
    let buffer: UnsafeMutablePointer<UInt8>
    let bufferSize: Int
    var onKeys: (([Int]) -> Void)?
    private var input = StreamDeckInputState()
    lazy var output = StreamDeckOutput(model: model) { [device] report, feature in
        report.withUnsafeBytes { bytes in
            IOHIDDeviceSetReport(device, feature ? kIOHIDReportTypeFeature : kIOHIDReportTypeOutput,
                CFIndex(report[0]), bytes.bindMemory(to: UInt8.self).baseAddress!, report.count)
        }
    }

    init(device: IOHIDDevice, model: StreamDeckModel) {
        self.device = device; self.model = model
        let advertised = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 512
        bufferSize = max(512, min(advertised, 65536))
        buffer = .allocate(capacity: bufferSize)
        buffer.initialize(repeating: 0, count: bufferSize)
    }

    deinit { buffer.deallocate() }

    func register() {
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, { context, result, _, type, reportID, bytes, length in
            guard let context, result == kIOReturnSuccess, type == kIOHIDReportTypeInput, reportID == 1 else { return }
            let session = Unmanaged<StreamDeckHIDSession>.fromOpaque(context).takeUnretainedValue()
            guard length > 0, length <= session.bufferSize else { return }
            let keys = session.input.consume(Data(bytes: bytes, count: length), model: session.model)
            if !keys.isEmpty { session.onKeys?(keys) }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    func unregister() {
        // Unregister and unschedule on the callback run loop before releasing buffer/context.
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        onKeys = nil
    }

    func close() { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
}
