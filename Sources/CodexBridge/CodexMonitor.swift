import Combine
import Foundation

public final class CodexMonitor: ObservableObject {
    @Published public private(set) var projects: [AgentProject] = []
    @Published public private(set) var statusMessage: String = "Not refreshed"
    @Published public private(set) var lastRefresh: Date?

    private let queue = DispatchQueue(label: "StreamAgent.CodexBridge", qos: .utility)
    private let reader: CodexStoreReader
    private let lock = NSLock()
    private var running = false
    private var pendingGeneration: Int?
    private var generation = 0
    // Timer and reader are only touched on queue; published properties only on main.
    private var timer: DispatchSourceTimer?

    public init(codexHome: URL? = nil) {
        reader = CodexStoreReader(home: codexHome ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true))
    }

    deinit { timer?.cancel() }

    public func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        let token = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self = self, self.isCurrent(token, requireRunning: true) else { return }
            self.timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 3, repeating: 3, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.refresh() }
            self.timer = timer
            timer.resume()
        }
        refresh()
    }

    public func stop() {
        lock.lock()
        running = false
        generation += 1
        lock.unlock()
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    public func refresh() {
        lock.lock()
        let token = generation
        guard pendingGeneration != token else { lock.unlock(); return }
        pendingGeneration = token
        lock.unlock()
        queue.async { [weak self] in
            guard let self = self else { return }
            let snapshot = self.reader.read()
            let refreshed = Date()
            self.lock.lock()
            if self.pendingGeneration == token { self.pendingGeneration = nil }
            self.lock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isCurrent(token) else { return }
                if self.projects != snapshot.projects { self.projects = snapshot.projects }
                self.statusMessage = snapshot.message
                self.lastRefresh = refreshed
            }
        }
    }

    private func isCurrent(_ token: Int, requireRunning: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == token && (!requireRunning || running)
    }
}
