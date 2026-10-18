import AppKit
import ApplicationServices
import Combine
import ServiceManagement

@MainActor
final class ExternalAppTracker: ObservableObject {
    @Published private(set) var lastApplication: NSRunningApplication?
    @Published private(set) var name = "No external app"
    @Published private(set) var bundleIdentifier = "*"
    var didChange: (() -> Void)?
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         frontmostApplication: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        self.notificationCenter = notificationCenter
        if let app = frontmostApplication { accept(app) }
        observers.append(notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.accept(app) }
        })
        observers.append(notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                guard let self, self.lastApplication?.processIdentifier == pid else { return }
                self.lastApplication = nil; self.name = "No external app"; self.bundleIdentifier = "*"
                self.didChange?()
            }
        })
    }
    private func accept(_ app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular, !app.isTerminated else { return }
        lastApplication = app; name = app.localizedName ?? "Application"; bundleIdentifier = app.bundleIdentifier ?? "*"
        didChange?()
    }
    deinit { for observer in observers { notificationCenter.removeObserver(observer) } }
}

@MainActor
final class ActionRunner {
    typealias KeyboardSender = (KeyboardShortcutSpec, NSRunningApplication?) async throws -> Void
    let tracker: ExternalAppTracker
    var focusAction: ((String) -> Void)?
    let launcher: WorkspaceLauncher
    private let keyboardSender: KeyboardSender?
    init(tracker: ExternalAppTracker, launcher: WorkspaceLauncher = .shared, keyboardSender: KeyboardSender? = nil) {
        self.tracker = tracker; self.launcher = launcher; self.keyboardSender = keyboardSender
    }
    var accessibilityGranted: Bool { AXIsProcessTrusted() }
    func openAccessibilitySettings() async throws {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        try await launcher.open(.url(url))
    }
    func openCodexThread(_ url: URL) async throws {
        guard url.scheme == "codex", url.host == "threads" else { throw ConfigurationError.invalid("This Codex thread link is unavailable.") }
        try await launcher.open(.url(url))
    }
    func run(_ action: TileAction) async throws {
        try await run(action, target: tracker.lastApplication)
    }
    func run(_ action: TileAction, target: NSRunningApplication?) async throws {
        try action.validate()
        switch action.kind {
        case .none: return
        case .keyboard:
            if let keyboardSender { try await keyboardSender(action.shortcut, target) }
            else { try await keyboard(action.shortcut, target: target) }
        case .openURL:
            guard let url = URL(string: action.value) else { throw ConfigurationError.invalid("This URL is invalid.") }
            try await launcher.open(.url(url))
        case .openFile:
            try await launcher.open(.file(URL(fileURLWithPath: action.value)))
        case .openApp:
            try await launcher.open(.application(action.value))
        case .appleShortcut:
            var parts = URLComponents(); parts.scheme = "shortcuts"; parts.host = "run-shortcut"
            parts.queryItems = [URLQueryItem(name: "name", value: action.value)]
            guard let url = parts.url else { throw ConfigurationError.invalid("This Apple Shortcut name cannot form a valid link.") }
            try await launcher.open(.url(url))
        case .media: try media(action.value)
        case .focus: focusAction?(action.value)
        }
    }
    private func keyboard(_ shortcut: KeyboardShortcutSpec, target: NSRunningApplication?) async throws {
        // Never prompt at startup. A deliberate action reveals the missing permission.
        guard AXIsProcessTrusted() else { throw ConfigurationError.invalid("Allow StreamAgent in System Settings → Privacy & Security → Accessibility, then run the action again. No permission was requested automatically.") }
        guard let target, !target.isTerminated else { throw ConfigurationError.invalid("Switch to the app you want to control, then return to StreamAgent and run this shortcut.") }
        target.activate(options: [])
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { throw ConfigurationError.invalid("Could not activate \(target.localizedName ?? "the target app"). The shortcut was not sent.") }
        // Allow the destination window to finish activation before posting to its process.
        try await Task.sleep(nanoseconds: 70_000_000)
        guard !target.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              let code = shortcut.keyCode, let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { throw ConfigurationError.invalid("The destination changed before the shortcut could be sent. Try again.") }
        var flags: CGEventFlags = []
        for modifier in shortcut.modifiers {
            switch modifier { case .command: flags.insert(.maskCommand); case .option: flags.insert(.maskAlternate); case .control: flags.insert(.maskControl); case .shift: flags.insert(.maskShift) }
        }
        down.flags = flags; up.flags = flags
        down.postToPid(target.processIdentifier); up.postToPid(target.processIdentifier)
    }
    private func media(_ command: String) throws {
        guard AXIsProcessTrusted() else { throw ConfigurationError.invalid("Media key posting requires Accessibility access. Enable StreamAgent in System Settings → Privacy & Security → Accessibility, then retry.") }
        // Public system-defined media key events. No private player or DND API.
        let codes = ["volumeUp":0, "volumeDown":1, "mute":7, "playPause":16, "next":17, "previous":18]
        guard let code = codes[command] else { return }
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                               windowNumber: 0, context: nil, subtype: 8,
                                               data1: (code << 16) | ((down ? 0xa : 0xb) << 8), data2: -1) else {
                throw ConfigurationError.invalid("macOS could not create the media key event.")
            }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

@MainActor
final class FocusController: ObservableObject {
    @Published private(set) var state = FocusState()
    @Published var keepAwake = false { didSet { updateActivity() } }
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    var changed: (() -> Void)?
    init(minutes: Int, keepAwake: Bool) {
        state.reset(minutes: minutes); self.keepAwake = keepAwake
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state.phase == .running else { return }
                self.state.tick(); self.updateActivity(); self.changed?()
            }
        }
    }
    func perform(_ value: String) {
        if value == "startPause" { state.toggle() }
        else if value == "reset" { state.reset() }
        else if let minutes = Int(value), (1...240).contains(minutes) { state.reset(minutes: minutes) }
        updateActivity(); changed?()
    }
    private func updateActivity() {
        let needed = keepAwake && state.phase == .running
        if needed && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "StreamAgent focus timer")
        } else if !needed, let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
    func stop() { timer?.invalidate(); timer = nil; if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil } }
}
