import SwiftUI
import AppKit
import CodexBridge
import ServiceManagement

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var rename = ""
    @State private var renaming = false
    @State private var deleting = false
    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 198, max: 240)
        } detail: {
            HStack(spacing: 0) {
                canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                InspectorView().frame(width: 258)
            }
        }
        .navigationTitle("StreamAgent")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.showingHelp = true } label: { Image(systemName: "questionmark.circle") }.help("Controls and permissions")
                Menu {
                    Button("Rename…") { rename = model.pageTitle; renaming = true }
                    Button("Add custom page", action: model.addPage)
                    if model.currentPage != nil {
                        Button("Move page earlier") { model.movePage(-1) }
                        Button("Move page later") { model.movePage(1) }
                        Button("Delete page…", role: .destructive) { deleting = true }
                    } else if model.module.kind == .custom {
                        Button("Delete module…", role: .destructive) { deleting = true }
                    }
                    Divider()
                    Button("Import configuration…", action: model.importConfiguration)
                    Button("Export configuration…", action: model.exportConfiguration)
                } label: { Image(systemName: "ellipsis.circle") }.help("Page and configuration actions")
            }
        }
        .alert("StreamAgent", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $rename)
            Button("Cancel", role: .cancel) {}
            Button("Save") { model.renamePage(rename) }
        }
        .confirmationDialog(model.currentPage != nil ? "Delete this page and its tiles?" : "Delete this custom module?", isPresented: $deleting) {
            Button("Delete", role: .destructive) { if model.currentPage != nil { model.deletePage() } else { model.deleteModule() } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $model.showingHelp) { HelpView() }
        .sheet(isPresented: $model.showingProjects) { ProjectPickerView() }
        .frame(minWidth: 1030, minHeight: 660)
    }
    private var canvas: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.pageTitle).font(.largeTitle.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 10)
                if !model.module.pages.isEmpty {
                    Picker("Page", selection: $model.selectedPageID) {
                        Text("Main").tag(String?.none)
                        ForEach(model.module.pages) { Text($0.name).tag(Optional($0.id)) }
                    }.labelsHidden().frame(maxWidth: 160)
                }
            }
            if model.module.kind == .appControls, model.currentPage == nil { profileBar }
            if model.module.kind == .codex, model.currentPage == nil { codexBar }
            if model.module.kind == .focus, model.currentPage == nil { focusBar }
            Spacer(minLength: 0)
            DeviceCanvas()
            HStack(spacing: 6) {
                Image(systemName: "cursorarrow.and.square.on.square.dashed")
                Text("Select a key to inspect. Use Run to execute.")
            }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Circle().fill(model.device.isConnected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                Text(model.device.statusMessage).lineLimit(2)
                Spacer()
                if model.device.isConnected { Text("\(model.device.keyPressCount) presses").monospacedDigit() }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(24)
    }
    private var subtitle: String {
        if model.currentPage != nil { return "Custom actions · physical navigation stays fixed" }
        switch model.module.kind {
        case .appControls: return "Controls for your last active app"
        case .codex: return "Four projects. Three threads each. Stable key positions."
        case .media: return "Playback and volume through macOS media keys"
        case .workspaces: return "Your apps, folders, and links, one press away"
        case .focus: return "A local timer for uninterrupted work"
        case .custom: return "Twelve actions, arranged your way"
        }
    }
    private var profileBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(model.tracker.name, systemImage: "app").font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                Picker("Edit profile", selection: Binding(get: { model.editingProfileID ?? "live" }, set: { model.editingProfileID = $0 == "live" ? nil : $0; model.selectedContentIndex = nil; model.refreshDeck() })) {
                    Text("Follow active app").tag("live")
                    ForEach(model.configuration.profiles) { Text($0.name).tag($0.id) }
                }.frame(maxWidth: 200)
            }
            if model.editingProfileID != nil {
                Text("Editing \(model.currentProfile?.name ?? "profile"). Hardware still controls \(model.tracker.name). Run sends this preview’s action to that app.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Profile: \(model.currentProfile?.name ?? "Default") · shortcuts return to \(model.tracker.name)").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Add profile for active app", action: model.addCurrentAppProfile)
                    .disabled(model.tracker.bundleIdentifier == "*" || model.configuration.profiles.contains { $0.bundleIdentifier == model.tracker.bundleIdentifier })
                if model.editingProfileID != nil, model.currentProfile?.bundleIdentifier != "*" {
                    Button("Remove profile", role: .destructive, action: model.deleteCurrentProfile)
                }
            }.controlSize(.small)
        }
    }
    private var codexBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { model.nextProjectBank(-1) } label: { Image(systemName: "chevron.left") }.help("Previous project bank").disabled(model.board.bankCount <= 1)
                Text("Bank \(model.projectBank + 1) of \(model.board.bankCount)").monospacedDigit().font(.callout)
                Button { model.nextProjectBank(1) } label: { Image(systemName: "chevron.right") }.help("Next project bank").disabled(model.board.bankCount <= 1)
                Spacer()
                Menu {
                    ForEach(0...model.maxThreadBank, id: \.self) { bank in Button("Threads \(bank * 3 + 1)–\(bank * 3 + 3)") { model.threadBank = bank } }
                } label: { Label("Threads \(model.threadBank * 3 + 1)–\(model.threadBank * 3 + 3)", systemImage: "list.bullet") }
                Button { model.showingProjects = true } label: { Image(systemName: "pin") }.help("Choose and order projects")
                Button { model.monitor.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh Codex metadata")
            }.controlSize(.small)
            if model.monitor.projects.isEmpty {
                Text(model.monitor.lastRefresh == nil ? "Reading local Codex data…" : "No local chats available. Open Codex, then refresh.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 3) {
                    Text("\(model.monitor.projects.count) projects · \(model.monitor.projects.reduce(0) { $0 + $1.sessions.count }) agents · one chat per key")
                    if let date = model.monitor.lastRefresh { Text("· refreshed"); Text(date, style: .relative); Text("ago") }
                }.font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
    private var focusBar: some View {
        HStack(spacing: 16) {
            Text(model.focus.state.display).font(.system(size: 40, weight: .light, design: .rounded)).monospacedDigit()
            VStack(alignment: .leading, spacing: 4) {
                Text(model.focus.state.phase.rawValue.capitalized).font(.headline)
                Text(model.configuration.keepAwake ? "Keep awake during timer" : "System sleep settings respected").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.focus.perform("startPause") } label: { Image(systemName: model.focus.state.phase == .running ? "pause.fill" : "play.fill") }.help("Start or pause timer")
            Button { model.focus.perform("reset") } label: { Image(systemName: "arrow.counterclockwise") }.help("Reset timer")
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { Optional(model.module.id) }, set: { if let id = $0 { model.selectModule(id) } })) {
                Section("Modules") {
                    ForEach(model.configuration.modules) { module in
                        Label(module.name, systemImage: module.symbol).tag(module.id)
                            .padding(.vertical, 4)
                            .contextMenu {
                                Button("Move up") { model.moveModule(module.id, by: -1) }
                                Button("Move down") { model.moveModule(module.id, by: 1) }
                            }
                    }.onMove { from, to in model.update { $0.modules.move(fromOffsets: from, toOffset: to) } }
                }
            }.listStyle(.sidebar)
            Button { model.addModule() } label: { Label("Add module", systemImage: "plus") }.buttonStyle(.plain).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: model.device.isConnected ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(model.device.isConnected ? Color.green : Color.secondary)
                    Text(model.device.isConnected ? "Connected" : "Disconnected").font(.callout.weight(.medium))
                }
                Text(model.device.modelName).font(.caption).foregroundStyle(.secondary)
                HStack { Text("Brightness"); Spacer(); Text("\(model.configuration.brightness)%").monospacedDigit() }.font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(model.configuration.brightness) }, set: { model.setBrightness(Int($0.rounded())) }), in: 0...100, step: 1).accessibilityLabel("Device brightness")
                SettingsLink { Label("Settings", systemImage: "gearshape") }.buttonStyle(.plain).font(.callout)
            }.padding(16)
        }
    }
}

struct DeviceCanvas: View {
    @EnvironmentObject var model: AppModel
    // Headings and physical keys share exactly five equal columns.
    private let columns = Array(repeating: GridItem(.fixed(72), spacing: 12), count: 5)
    var body: some View {
        VStack(spacing: 12) {
            if model.module.kind == .codex, model.currentPage == nil {
                LazyVGrid(columns: columns, spacing: 12) {
                    Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                    ForEach(0..<4, id: \.self) { column in
                        Menu {
                            ForEach(model.monitor.projects) { project in Button(project.name) { model.chooseProject(project.id, column: column) } }
                            Divider()
                            Button("Manage projects…") { model.showingProjects = true }
                        } label: { Text(model.projectName(column: column)).font(.caption.weight(.medium)).lineLimit(1).frame(maxWidth: .infinity) }
                        .menuStyle(.borderlessButton)
                        .frame(maxWidth: .infinity)
                        .help(model.projectName(column: column))
                        .accessibilityIdentifier("codex-project-column-\(column)")
                    }
                }.padding(.horizontal, 18)
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(0..<15, id: \.self) { key in
                    if model.deck.indices.contains(key) {
                        DeviceKey(tile: model.deck[key], selected: model.selectedContentIndex == DeckLayout.contentIndex(for: key) && key % 5 > 0, navigation: key % 5 == 0) {
                            if let index = DeckLayout.contentIndex(for: key) { model.selectedContentIndex = index }
                            else if key == 0 { model.navigate(-1) }
                            else if key == 10 { model.navigate(1) }
                            else { model.showWindow?() }
                        }.accessibilityIdentifier("deck-key-\(key)")
                    }
                }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(white: 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08)))
        }
        .frame(width: 444)
        .frame(maxWidth: .infinity)
    }
}

struct DeviceKey: View {
    @Environment(\.displayScale) private var displayScale
    let tile: DeckTilePresentation
    let selected: Bool
    let navigation: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(nsImage: DeckRenderer.image(tile, size: Int(72 * displayScale))).resizable().interpolation(.high)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Color.accentColor : .white.opacity(0.12), lineWidth: selected ? 2 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }.buttonStyle(.plain)
            .accessibilityLabel("\(tile.title)\(tile.subtitle.isEmpty ? "" : ", \(tile.subtitle)")")
            .accessibilityHint(navigation ? "Navigate modules" : "Select key. Use Run in the inspector to execute.")
            .help("\(tile.title)\(tile.subtitle.isEmpty ? "" : " · \(tile.subtitle)")")
    }
}

struct InspectorView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Inspector").font(.headline)
                if let index = model.selectedContentIndex {
                    Text("Key \(DeckLayout.contentKeys[index]) · row \(index / 4 + 1), column \(index % 4 + 1)").font(.caption).foregroundStyle(.secondary)
                    if model.isEditablePage, let tile = model.selectedTile {
                        TileEditor(tile: tile).id("\(model.currentProfile?.id ?? model.module.id)-\(tile.id)")
                    } else if let agent = model.currentAgent { agentDetail(agent) }
                    else { empty("No thread assigned", "Choose projects above the device, or wait for local Codex metadata.", "terminal") }
                } else { empty("Choose a key", "Inspect an action or thread here. Screen clicks select; physical keys execute.", "cursorarrow") }
                Spacer(minLength: 12)
            }.padding(18)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private func empty(_ title: String, _ detail: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }.padding(.top, 30)
    }
    private func agentDetail(_ agent: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(agent.status.label, systemImage: DeckRenderer.presentation(for: agent).symbol).font(.headline)
            Text(agent.displayName).font(.title3.weight(.medium)).textSelection(.enabled)
            if agent.title != agent.displayName { Text(agent.title).font(.callout).textSelection(.enabled) }
            Text(agent.projectName).font(.callout).foregroundStyle(.secondary)
            Text(agent.statusDetail).font(.callout).foregroundStyle(.secondary)
            LabeledContent("Updated", value: agent.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
            Text("Status is inferred from local metadata. It does not expose the model’s private reasoning.").font(.caption).foregroundStyle(.secondary)
            Button(action: model.runSelected) { Label("Open thread", systemImage: "arrow.up.forward.app") }.buttonStyle(.borderedProminent).disabled(agent.deepLink == nil || model.actionRunning)
        }
    }
}

struct TileEditor: View {
    @EnvironmentObject var model: AppModel
    let tile: ActionTile
    @State private var draft: ActionTile
    @State private var message: String?
    init(tile: ActionTile) { self.tile = tile; _draft = State(initialValue: tile) }
    private let symbols = ["square", "star", "bolt", "app", "folder", "doc", "globe", "keyboard", "terminal", "play.fill", "timer", "heart", "bookmark", "link", "magnifyingglass", "gearshape"]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Name (inspector only)", text: $draft.label).textFieldStyle(.roundedBorder)
            HStack {
                Image(systemName: draft.symbol).font(.title2).frame(width: 28)
                TextField("SF Symbol", text: $draft.symbol).textFieldStyle(.roundedBorder).accessibilityLabel("SF Symbol name")
                Menu { ForEach(symbols, id: \.self) { symbol in Button { draft.symbol = symbol } label: { Label(symbol, systemImage: symbol) } } } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).frame(width: 18)
            }
            Picker("Action", selection: $draft.action.kind) {
                ForEach(ActionKind.allCases) { Text($0.label).tag($0) }
            }.onChange(of: draft.action.kind) { _, kind in
                draft.action.value = kind == .media ? "playPause" : kind == .focus ? "startPause" : ""
            }
            actionFields
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
            Button("Save tile") {
                do {
                    try draft.action.validate()
                    guard NSImage(systemSymbolName: draft.symbol, accessibilityDescription: nil) != nil else { throw ConfigurationError.invalid("Choose a valid SF Symbol name.") }
                    model.saveTile(draft); message = nil
                } catch { message = error.localizedDescription }
            }.disabled(draft == tile)
            Divider()
            Button { model.runSelected() } label: { Label(model.actionRunning ? "Running…" : "Run saved action", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).disabled(tile.action.kind == .none || model.actionRunning)
                .accessibilityIdentifier("run-saved-action")
            Text(draft == tile ? "Physical keys execute immediately." : "Unsaved edits. Run uses the saved action.").font(.caption).foregroundStyle(.secondary)
            Button("Clear tile", role: .destructive) { var empty = ActionTile.empty(); empty.id = tile.id; draft = empty; model.saveTile(empty) }.controlSize(.small)
        }
        .onChange(of: tile) { _, value in draft = value }
    }
    @ViewBuilder private var actionFields: some View {
        switch draft.action.kind {
        case .keyboard:
            TextField("Key (c, return, left, f1…)", text: $draft.action.shortcut.key).textFieldStyle(.roundedBorder)
            HStack(spacing: 9) {
                ForEach(ShortcutModifier.allCases) { modifier in
                    Toggle(modifier.glyph, isOn: Binding(get: { draft.action.shortcut.modifiers.contains(modifier) }, set: { enabled in
                        draft.action.shortcut.modifiers.removeAll { $0 == modifier }; if enabled { draft.action.shortcut.modifiers.append(modifier) }
                    })).toggleStyle(.button).help(modifier.rawValue.capitalized)
                }
            }
            Text("Target: \(model.tracker.name)").font(.caption).foregroundStyle(.secondary)
        case .openApp, .openFile:
            TextField(draft.action.kind == .openApp ? "Bundle ID or /path/App.app" : "/path/to/file or folder", text: $draft.action.value).textFieldStyle(.roundedBorder)
            Button("Choose…", action: choosePath).controlSize(.small)
        case .openURL:
            TextField("https://example.com", text: $draft.action.value).textFieldStyle(.roundedBorder)
        case .appleShortcut:
            TextField("Exact shortcut name", text: $draft.action.value).textFieldStyle(.roundedBorder)
            Text("Runs through the Apple Shortcuts app. macOS may request permissions when the shortcut runs.").font(.caption).foregroundStyle(.secondary)
        case .media:
            Picker("Control", selection: $draft.action.value) {
                ForEach(TileAction.mediaCommands, id: \.self) { Text($0).tag($0) }
            }
        case .focus:
            Picker("Timer", selection: $draft.action.value) {
                ForEach(TileAction.focusCommands, id: \.self) { Text($0 == "startPause" ? "Start / Pause" : $0 == "reset" ? "Reset" : "\($0) minutes").tag($0) }
            }
        case .none: EmptyView()
        }
    }
    private func choosePath() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = draft.action.kind == .openFile; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if draft.action.kind == .openApp { panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications") }
        if panel.runModal() == .OK, let url = panel.url { draft.action.value = url.path }
    }
}

struct ProjectPickerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Projects on your deck").font(.title2.weight(.semibold))
            Text("Pin projects to retain their slots when unavailable. Reorder projects to choose their columns. Live status updates retain thread positions.").font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(Array(model.board.projectIDs.enumerated()), id: \.element) { index, id in
                    HStack {
                        Text("\(index / 4 + 1).\(index % 4 + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 35)
                        VStack(alignment: .leading) {
                            Text(model.monitor.projects.first { $0.id == id }?.name ?? "Unavailable project")
                            if let path = model.monitor.projects.first(where: { $0.id == id })?.path { Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer()
                        Button { model.togglePin(id) } label: { Image(systemName: model.configuration.pinnedProjectIDs.contains(id) ? "pin.fill" : "pin") }.help("Pin project")
                        Button { model.moveProject(id, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0).help("Move earlier")
                        Button { model.moveProject(id, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(index + 1 == model.board.projectIDs.count).help("Move later")
                    }
                }
            }.overlay { if model.board.projectIDs.isEmpty { ContentUnavailableView("No projects", systemImage: "folder", description: Text("Open a local Codex thread, then refresh.")) } }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 580, height: 460)
    }
}

struct HelpView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Your deck, your workflow", systemImage: "square.grid.3x3").font(.title2.weight(.semibold))
            Text("The left column is always Previous module, Show StreamAgent, Next module. Module navigation wraps. The other twelve keys belong to the current page.")
            Text("On screen, select a key and use Run. Hardware keys execute immediately. Add custom pages from the toolbar menu. Choose pages here or from the menu bar.")
            Text("Key faces use Apple symbols without captions. Hover or select a key for its name and status. Focus numeral symbols choose minutes; the hourglass chooses one hour. Empty keys stay blank.")
            Text("App Controls follows your last external app. Keyboard actions return to that app and require Accessibility access. StreamAgent never requests permissions at startup.")
            Text("Codex shows inferred local metadata states. Empty keys remain empty; no sessions or progress are invented. Use the bank controls for more projects and threads.")
            Text("Closing the window keeps the menu bar and device active. Quit StreamAgent from the menu bar to stop both.")
            DisclosureGroup("Advanced: local metadata source") {
                Text(model.monitor.statusMessage).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.font(.callout).padding(28).frame(width: 520)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
    @State private var settingsError: String?
    @State private var accessibility = AXIsProcessTrusted()
    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Switch to App Controls when another app becomes active", isOn: Binding(get: { model.configuration.autoSwitchToAppControls }, set: { value in model.update { $0.autoSwitchToAppControls = value } }))
                Toggle("Keep Mac awake while focus timer runs", isOn: Binding(get: { model.configuration.keepAwake }, set: { value in model.update { $0.keepAwake = value } }))
                Toggle("Launch StreamAgent at login", isOn: Binding(get: { loginEnabled }, set: setLogin))
                Text("All options are reversible. Keep awake applies only while the timer is running. Login startup requires the packaged app in a stable location.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                LabeledContent("Accessibility", value: accessibility ? "Allowed" : "Not allowed")
                HStack {
                    Button("Open Accessibility settings") {
                        Task { @MainActor in
                            do { try await model.runner.openAccessibilitySettings(); settingsError = nil }
                            catch { settingsError = error.localizedDescription }
                        }
                    }
                    Button("Check again") { accessibility = AXIsProcessTrusted() }
                }
                Text("Required for keyboard shortcuts and media keys. Grant access yourself in System Settings; StreamAgent does not change security settings. File access and Shortcuts permissions are handled by macOS when you use those actions.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Configuration") {
                HStack {
                    Button("Import…", action: model.importConfiguration)
                    Button("Export…", action: model.exportConfiguration)
                }
                Text(model.store.fileURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if model.store.recoveryRequired { Button("Preserve damaged file and save", action: model.preserveConfiguration) }
            }
            if let settingsError { Text(settingsError).foregroundStyle(.red).font(.caption) }
        }.formStyle(.grouped).padding(8).frame(width: 580, height: 510)
        .onAppear { let status = SMAppService.mainApp.status; loginEnabled = status == .enabled || status == .requiresApproval; accessibility = AXIsProcessTrusted() }
    }
    private func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            let status = SMAppService.mainApp.status
            loginEnabled = status == .enabled || status == .requiresApproval
            if enabled && status == .requiresApproval { settingsError = "Approve StreamAgent in System Settings → General → Login Items." }
            else { settingsError = nil }
        } catch { settingsError = error.localizedDescription; let status = SMAppService.mainApp.status; loginEnabled = status == .enabled || status == .requiresApproval }
    }
}
