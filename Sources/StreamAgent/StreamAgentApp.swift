import SwiftUI
import AppKit

@main
struct StreamAgentEntry {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--smoke-test") { SmokeCheck.run(); return }
        if CommandLine.arguments.contains("--diagnostics") { SmokeCheck.diagnostics(); return }
        StreamAgentApplication.main()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { Self.model?.stop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.model?.showWindow?() }; return true
    }
}

struct StreamAgentApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("StreamAgent", id: "main") {
            WindowContent().environmentObject(model)
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .sidebar) {
                Button("Previous module") { model.navigate(-1) }.keyboardShortcut("[", modifiers: [.command, .option])
                Button("Next module") { model.navigate(1) }.keyboardShortcut("]", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .help) {
                Button("StreamAgent Help") { model.showWindow?(); model.showingHelp = true }
            }
        }
        Settings { SettingsView().environmentObject(model) }
        MenuBarExtra("StreamAgent", systemImage: "square.grid.3x3.fill") {
            MenuBarView().environmentObject(model)
        }
    }
}

struct WindowContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    @State private var initialized = false
    var body: some View {
        MainView().onAppear {
            model.showWindow = { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            AppDelegate.model = model
            if !initialized { model.start(); initialized = true }
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button("Show StreamAgent") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Text(model.device.isConnected ? "Device connected" : "Device disconnected")
        Divider()
        ForEach(model.configuration.modules) { module in
            if module.pages.isEmpty {
                Button { model.selectModule(module.id) } label: { Label(module.name, systemImage: module.symbol) }
            } else {
                Menu {
                    Button("Main") { model.selectModule(module.id) }
                    ForEach(module.pages) { page in Button(page.name) { model.selectModule(module.id); model.selectedPageID = page.id } }
                } label: { Label(module.name, systemImage: module.symbol) }
            }
        }
        if model.module.kind == .codex {
            Divider()
            Button("Previous project bank") { model.nextProjectBank(-1) }
            Button("Next project bank") { model.nextProjectBank(1) }
        }
        Divider()
        SettingsLink()
        Button("Quit StreamAgent") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

@MainActor
enum SmokeCheck {
    static func run() {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("streamagent-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            let store = ConfigurationStore(directory: temp)
            let configuration = AppConfiguration.defaults()
            try store.save(configuration)
            guard try store.load() == configuration else { throw ConfigurationError.invalid("Configuration round trip failed.") }
            let image = DeckRenderer.image(.init(title: "Ready", subtitle: "Local", symbol: "checkmark.circle", tint: .green))
            guard let data = image.tiffRepresentation, !data.isEmpty else { throw ConfigurationError.invalid("Renderer returned no pixels.") }
            guard DeckLayout.contentKeys.count == 12, DeckLayout.contentKeys.allSatisfy({ ![0,5,10].contains($0) }) else { throw ConfigurationError.invalid("Invalid physical layout.") }
            emit(["success": true, "configurationVersion": configuration.version, "modules": configuration.modules.count, "contentKeys": 12, "renderedBytes": data.count, "guiLaunched": false])
        } catch { emit(["success": false, "error": error.localizedDescription]); exit(1) }
    }
    static func diagnostics() {
        let store = ConfigurationStore()
        do {
            let config = try store.load()
            emit(["success": true, "modules": config.modules.count, "profiles": config.profiles.count, "customPages": config.modules.reduce(0) { $0 + $1.pages.count }, "configurationExists": FileManager.default.fileExists(atPath: store.fileURL.path), "guiLaunched": false])
        } catch { emit(["success": false, "configurationReadable": false, "originalPreserved": true, "guiLaunched": false]); exit(1) }
    }
    private static func emit(_ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let output = String(data: data, encoding: .utf8) { print(output) }
    }
}
