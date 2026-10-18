import AppKit
import Combine
import CodexBridge
import StreamDeckKit
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var configuration: AppConfiguration
    @Published var selectedContentIndex: Int? = nil
    @Published var selectedPageID: String? = nil { didSet { selectedContentIndex = nil; refreshDeck() } }
    @Published var projectBank = 0 { didSet { refreshDeck() } }
    @Published var threadBank = 0 { didSet { refreshDeck() } }
    @Published var errorMessage: String?
    @Published var pressedKey: Int?
    @Published var showingHelp = false
    @Published var showingProjects = false
    @Published var editingProfileID: String?
    @Published private(set) var deck: [DeckTilePresentation] = []
    private(set) var hardwareDeck: [DeckTilePresentation] = []
    @Published private(set) var actionRunning = false
    let device = StreamDeckDevice()
    let monitor = CodexMonitor()
    let tracker = ExternalAppTracker()
    let store: ConfigurationStore
    let focus: FocusController
    let runner: ActionRunner
    private(set) var board = StableCodexBoard()
    private var cancellables = Set<AnyCancellable>()
    private var sent: [Int: DeckTilePresentation] = [:]
    private var feedbackGeneration = 0
    var showWindow: (() -> Void)?

    init(store: ConfigurationStore = ConfigurationStore()) {
        self.store = store
        let loaded: AppConfiguration
        var loadError: String?
        do { loaded = try store.load() }
        catch { loaded = .defaults(); loadError = "Your configuration could not be loaded. The original file is preserved. Temporary defaults are shown. \(error.localizedDescription)" }
        configuration = loaded
        focus = FocusController(minutes: loaded.focusMinutes, keepAwake: loaded.keepAwake)
        runner = ActionRunner(tracker: tracker)
        errorMessage = loadError
        runner.focusAction = { [weak self] value in
            guard let self else { return }; self.focus.perform(value)
            if let minutes = Int(value) { self.update { $0.focusMinutes = minutes } }
        }
        focus.changed = { [weak self] in self?.refreshDeck() }
        tracker.didChange = { [weak self] in
            guard let self else { return }
            if self.configuration.autoSwitchToAppControls, let module = self.configuration.modules.first(where: { $0.kind == .appControls }) { self.selectModule(module.id) }
            self.refreshDeck()
        }
        device.onKeyDown = { [weak self] key in Task { @MainActor in self?.physicalPress(key) } }
        monitor.$projects.receive(on: RunLoop.main).sink { [weak self] _ in
            // Published values arrive before assignment; reconcile on the next turn.
            Task { @MainActor in self?.reconcileProjects() }
        }.store(in: &cancellables)
        device.$isConnected.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] connected in
            guard let self else { return }
            if connected { self.sent.removeAll(); self.device.clearImageCache(); self.device.setBrightness(self.configuration.brightness); self.refreshDeck() }
        }.store(in: &cancellables)
        for publisher in [device.objectWillChange.eraseToAnyPublisher(), monitor.objectWillChange.eraseToAnyPublisher(), tracker.objectWillChange.eraseToAnyPublisher(), focus.objectWillChange.eraseToAnyPublisher()] {
            publisher.receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }
        refreshDeck()
    }
    func start() { device.start(); monitor.start() }
    func stop() { device.stop(); monitor.stop(); focus.stop() }
    var module: ModuleConfiguration { configuration.modules.first(where: { $0.id == configuration.selectedModuleID }) ?? configuration.modules[0] }
    var currentPage: ActionPage? { module.pages.first { $0.id == selectedPageID } }
    var pageTitle: String { currentPage?.name ?? module.name }
    var currentProfile: AppProfile? {
        AppControlRouting.profile(in: configuration, targetBundle: tracker.bundleIdentifier, editingProfileID: editingProfileID, physical: false)
    }
    var currentTiles: [ActionTile] {
        if let currentPage { return currentPage.tiles }
        if module.kind == .appControls { return currentProfile?.tiles ?? ActionTile.padded([]) }
        return module.tiles
    }
    var selectedTile: ActionTile? {
        guard let index = selectedContentIndex, currentTiles.indices.contains(index), isEditablePage else { return nil }
        return currentTiles[index]
    }
    var isEditablePage: Bool { currentPage != nil || module.kind != .codex }
    var currentAgent: AgentSession? {
        guard let index = selectedContentIndex else { return nil }; return agent(at: index)
    }
    var maxThreadBank: Int {
        let ids = (0..<4).compactMap { board.projectID(column: $0, bank: projectBank) }
        let count = ids.map { board.sessionIDs[$0]?.count ?? 0 }.max() ?? 0
        return max(0, (count - 1) / 3)
    }
    func update(_ mutation: (inout AppConfiguration) -> Void) {
        var candidate = configuration; mutation(&candidate)
        do { try candidate.validate() }
        catch { errorMessage = error.localizedDescription; return }
        configuration = candidate
        do { try store.save(candidate) } catch { errorMessage = error.localizedDescription }
        focus.keepAwake = candidate.keepAwake
        refreshDeck()
    }
    func selectModule(_ id: String) {
        guard configuration.modules.contains(where: { $0.id == id }) else { return }
        selectedPageID = nil; selectedContentIndex = nil; editingProfileID = nil
        update { $0.selectedModuleID = id }
    }
    func navigate(_ delta: Int) {
        let index = configuration.modules.firstIndex { $0.id == module.id } ?? 0
        selectModule(configuration.modules[DeckLayout.adjacentIndex(index, delta: delta, count: configuration.modules.count)].id)
    }
    func moveModule(_ id: String, by delta: Int) {
        guard let index = configuration.modules.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard configuration.modules.indices.contains(target) else { return }
        update { $0.modules.swapAt(index, target) }
    }
    func addModule(name: String = "Custom") {
        let new = ModuleConfiguration(kind: .custom, name: name)
        update { $0.modules.append(new); $0.selectedModuleID = new.id }
        selectedPageID = nil
    }
    func renameModule(_ name: String) { let id = module.id; update { config in if let index = config.modules.firstIndex(where: { $0.id == id }) { config.modules[index].name = name } } }
    func deleteModule() {
        guard module.kind == .custom, configuration.modules.count > 1 else { return }
        let id = module.id
        selectedPageID = nil
        update { $0.modules.removeAll { $0.id == id }; $0.selectedModuleID = $0.modules[0].id }
    }
    func addPage() {
        let page = ActionPage(name: "Page \(module.pages.count + 1)"); let id = module.id
        update { config in if let index = config.modules.firstIndex(where: { $0.id == id }) { config.modules[index].pages.append(page) } }
        selectedPageID = page.id
    }
    func renamePage(_ name: String) {
        guard let selectedPageID else { renameModule(name); return }; let id = module.id
        update { config in if let m = config.modules.firstIndex(where: { $0.id == id }), let p = config.modules[m].pages.firstIndex(where: { $0.id == selectedPageID }) { config.modules[m].pages[p].name = name } }
    }
    func deletePage() {
        guard let pageID = selectedPageID else { return }; let id = module.id
        selectedPageID = nil
        update { config in if let m = config.modules.firstIndex(where: { $0.id == id }) { config.modules[m].pages.removeAll { $0.id == pageID } } }
    }
    func movePage(_ delta: Int) {
        guard let pageID = selectedPageID, let p = module.pages.firstIndex(where: { $0.id == pageID }), module.pages.indices.contains(p + delta) else { return }
        let id = module.id
        update { config in if let m = config.modules.firstIndex(where: { $0.id == id }) { config.modules[m].pages.swapAt(p, p + delta) } }
    }
    func saveTile(_ tile: ActionTile) {
        guard let index = selectedContentIndex, (0..<12).contains(index) else { return }
        let id = module.id, pageID = selectedPageID, profileID = currentProfile?.id
        update { config in
            guard let m = config.modules.firstIndex(where: { $0.id == id }) else { return }
            if let pageID, let p = config.modules[m].pages.firstIndex(where: { $0.id == pageID }) { config.modules[m].pages[p].tiles[index] = tile }
            else if config.modules[m].kind == .appControls, let p = config.profiles.firstIndex(where: { $0.id == profileID }) { config.profiles[p].tiles[index] = tile }
            else { config.modules[m].tiles[index] = tile }
        }
    }
    func addCurrentAppProfile() {
        guard tracker.bundleIdentifier != "*", !configuration.profiles.contains(where: { $0.bundleIdentifier == tracker.bundleIdentifier }) else { return }
        var tiles = currentProfile?.tiles ?? ActionTile.padded([])
        for i in tiles.indices { tiles[i].id = UUID().uuidString }
        let profile = AppProfile(bundleIdentifier: tracker.bundleIdentifier, name: tracker.name, tiles: tiles)
        update { $0.profiles.append(profile) }; editingProfileID = profile.id; refreshDeck()
    }
    func deleteCurrentProfile() {
        guard let profile = currentProfile, profile.bundleIdentifier != "*" else { return }
        editingProfileID = nil; update { $0.profiles.removeAll { $0.id == profile.id } }
    }
    func setBrightness(_ value: Int) { update { $0.brightness = value }; device.setBrightness(value) }
    func reconcileProjects() {
        board.reconcile(projects: monitor.projects.map { ($0.id, $0.sessions.map(\.id)) }, preferred: configuration.codexProjectOrder, pinned: configuration.pinnedProjectIDs)
        if projectBank >= board.bankCount { projectBank = max(0, board.bankCount - 1) }
        if threadBank > maxThreadBank { threadBank = maxThreadBank }
        refreshDeck()
    }
    func togglePin(_ projectID: String) {
        update { config in
            if config.pinnedProjectIDs.contains(projectID) { config.pinnedProjectIDs.removeAll { $0 == projectID } }
            else { config.pinnedProjectIDs.append(projectID) }
        }; reconcileProjects()
    }
    func moveProject(_ id: String, by delta: Int) {
        var ids = board.projectIDs
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + delta) else { return }
        ids.swapAt(index, index + delta)
        update { config in config.codexProjectOrder = ids; config.pinnedProjectIDs = ids.filter { config.pinnedProjectIDs.contains($0) } }
        reconcileProjects()
    }
    func chooseProject(_ id: String, column: Int) {
        var ids = board.projectIDs
        guard let from = ids.firstIndex(of: id) else { return }
        let target = projectBank * 4 + column
        guard ids.indices.contains(target) else { return }
        ids.swapAt(from, target)
        // Explicit column selection is stronger than pin order.
        update { $0.codexProjectOrder = ids }; reconcileProjects()
    }
    func agent(at index: Int) -> AgentSession? {
        guard let id = board.sessionID(contentIndex: index, bank: projectBank, rowOffset: threadBank * 3) else { return nil }
        return monitor.projects.lazy.flatMap(\.sessions).first { $0.id == id }
    }
    func projectName(column: Int) -> String {
        guard let id = board.projectID(column: column, bank: projectBank) else { return "Choose project" }
        return monitor.projects.first { $0.id == id }?.name ?? "Unavailable"
    }
    func nextProjectBank(_ delta: Int) { threadBank = 0; projectBank = DeckLayout.adjacentIndex(projectBank, delta: delta, count: board.bankCount) }
    func runSelected() {
        guard let index = selectedContentIndex else { return }
        executeContent(index)
    }
    func physicalPress(_ key: Int) {
        guard (0..<15).contains(key) else { return }
        feedbackGeneration += 1; let generation = feedbackGeneration
        pressedKey = key; refreshDeck()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, self.feedbackGeneration == generation else { return }
            self.pressedKey = nil; self.refreshDeck()
        }
        switch key {
        case DeckLayout.previous: navigate(-1)
        case DeckLayout.home: showWindow?()
        case DeckLayout.next: navigate(1)
        default: if let index = DeckLayout.contentIndex(for: key) { executeContent(index, physical: true) }
        }
    }
    func physicalAction(at index: Int) -> TileAction? {
        guard (0..<12).contains(index) else { return nil }
        if module.kind == .appControls, currentPage == nil {
            return AppControlRouting.tiles(in: configuration, targetBundle: tracker.bundleIdentifier, physical: true)[index].action
        }
        return currentTiles[index].action
    }
    private func executeContent(_ index: Int, physical: Bool = false) {
        guard (0..<12).contains(index), !actionRunning else { return }
        let operation: () async throws -> Void
        if currentPage == nil && module.kind == .codex {
            guard let session = agent(at: index), let url = session.deepLink else {
                errorMessage = "No available Codex thread is assigned to this key."; return
            }
            operation = { try await self.runner.openCodexThread(url) }
        } else {
            // Hardware rendering and execution share the live profile route.
            let action = physical ? physicalAction(at: index) : currentTiles[index].action
            guard let action else { return }
            operation = { try await self.runner.run(action) }
        }
        actionRunning = true
        Task { @MainActor in
            defer { actionRunning = false }
            do { try await operation() } catch { errorMessage = error.localizedDescription; showWindow?() }
        }
    }
    func refreshDeck() {
        var values = (0..<15).map { _ in DeckTilePresentation(title: "", symbol: "square.dashed") }
        values[0] = .init(title: "Previous", symbol: "chevron.up")
        values[5] = .init(title: module.name, subtitle: "Show app", symbol: module.symbol, tint: .blue)
        values[10] = .init(title: "Next", symbol: "chevron.down")
        for index in 0..<12 {
            var tile: DeckTilePresentation
            if currentPage == nil && module.kind == .codex {
                if let agent = agent(at: index) {
                    tile = DeckRenderer.presentation(for: agent)
                } else { tile = .init(title: "No thread", symbol: "minus", isEmpty: true) }
            } else {
                let action = currentTiles[index]
                tile = DeckRenderer.presentation(for: action, focus: focus.state)
            }
            values[DeckLayout.contentKeys[index]] = tile
        }
        if let pressedKey, values.indices.contains(pressedKey) { values[pressedKey].pressed = true }
        if deck != values { deck = values }
        var hardware = values
        if currentPage == nil, module.kind == .appControls {
            let live = AppControlRouting.tiles(in: configuration, targetBundle: tracker.bundleIdentifier, physical: true)
            for index in 0..<12 {
                let action = live[index]
                let key = DeckLayout.contentKeys[index]
                hardware[key] = DeckRenderer.presentation(for: action, focus: focus.state)
                hardware[key].pressed = pressedKey == key
            }
        }
        hardwareDeck = hardware
        guard device.isConnected else { return }
        for key in DeckDiff.changedKeys(previous: sent, current: hardware) {
            let value = hardware[key]
            device.setKeyImage(DeckRenderer.image(value), key: key); sent[key] = value
        }
    }
    func importConfiguration() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try store.importConfiguration(from: url)
            configuration = imported; selectedPageID = nil; editingProfileID = nil
            focus.perform(String(imported.focusMinutes)); focus.keepAwake = imported.keepAwake
            device.setBrightness(imported.brightness); reconcileProjects()
        } catch { errorMessage = "Import failed. Your existing configuration was retained. \(error.localizedDescription)" }
    }
    func exportConfiguration() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "StreamAgent.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.export(configuration, to: url) } catch { errorMessage = error.localizedDescription }
    }
    func preserveConfiguration() {
        do { try store.preserveAndSave(configuration) } catch { errorMessage = error.localizedDescription }
    }
}
