import AppKit
import Foundation

/// Launch Services can block even before an asynchronous API returns. Only this
/// dedicated worker invokes it; callers suspend without occupying the main thread.
enum WorkspaceLaunchRequest: Equatable, Sendable {
    case url(URL)
    case file(URL)
    case application(String)
}

enum WorkspaceLaunchError: LocalizedError, Equatable {
    case busy
    case timedOut
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .busy:
            return "macOS is still handling the previous open request. Other StreamAgent controls remain available. Wait for that request to finish before opening another item."
        case .timedOut:
            return "macOS did not finish the open request within five seconds. StreamAgent is still responsive. The item may open later; further open requests are blocked until macOS finishes."
        case .failed(let message): return message
        }
    }
}

// Mutable request state is protected by lock; opener runs only on worker.
final class WorkspaceLauncher: @unchecked Sendable {
    typealias Completion = (Result<Void, Error>) -> Void
    /// May block before returning, or deliver a completion asynchronously.
    typealias Opener = (WorkspaceLaunchRequest, @escaping Completion) -> Void
    static let shared = WorkspaceLauncher()

    // Every field is accessed under the owning launcher’s lock.
    private final class Pending: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Error>?
        var timeout: DispatchWorkItem?
        var invocationReturned = false
        var result: Result<Void, Error>?
        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    }
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "StreamAgent.WorkspaceLaunch", qos: .userInitiated)
    private let deadlines = DispatchQueue(label: "StreamAgent.WorkspaceLaunchTimeout", qos: .userInitiated)
    private let timeoutInterval: TimeInterval
    private let opener: Opener
    private var inFlight: Pending?

    init(timeout: TimeInterval = 5, opener: @escaping Opener = WorkspaceLauncher.systemOpen) {
        precondition(timeout.isFinite && timeout > 0)
        timeoutInterval = timeout; self.opener = opener
    }
    var isInFlight: Bool { lock.lock(); defer { lock.unlock() }; return inFlight != nil }

    func open(_ request: WorkspaceLaunchRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            guard inFlight == nil else {
                lock.unlock(); continuation.resume(throwing: WorkspaceLaunchError.busy); return
            }
            let pending = Pending(continuation)
            inFlight = pending
            let timeout = DispatchWorkItem { [weak self, weak pending] in
                guard let self, let pending else { return }
                self.expire(pending)
            }
            pending.timeout = timeout
            lock.unlock()
            deadlines.asyncAfter(deadline: .now() + timeoutInterval, execute: timeout)
            worker.async {
                self.opener(request) { result in self.completed(pending, result: result) }
                self.returned(pending)
            }
        }
    }
    private func expire(_ pending: Pending) {
        lock.lock()
        guard inFlight === pending else { lock.unlock(); return }
        let continuation = pending.continuation
        pending.continuation = nil
        // A UI timeout cannot cancel an uncooperative OS call. Retain the slot;
        // retries fail busy rather than creating more stuck workers or a backlog.
        lock.unlock()
        continuation?.resume(throwing: WorkspaceLaunchError.timedOut)
    }
    private func completed(_ pending: Pending, result: Result<Void, Error>) {
        lock.lock()
        guard inFlight === pending, pending.result == nil else { lock.unlock(); return }
        pending.result = result
        let completion = finishIfReady(pending)
        lock.unlock()
        completion?()
    }
    private func returned(_ pending: Pending) {
        lock.lock()
        guard inFlight === pending else { lock.unlock(); return }
        pending.invocationReturned = true
        let completion = finishIfReady(pending)
        lock.unlock()
        completion?()
    }
    /// Called with lock held. Both conditions matter: an async callback may fire
    /// before the initial invocation returns, and that invocation can still hang.
    private func finishIfReady(_ pending: Pending) -> (() -> Void)? {
        guard pending.invocationReturned, let result = pending.result else { return nil }
        inFlight = nil
        pending.timeout?.cancel(); pending.timeout = nil
        guard let continuation = pending.continuation else { return nil }
        pending.continuation = nil
        return { continuation.resume(with: result) }
    }

    private static func systemOpen(_ request: WorkspaceLaunchRequest, completion: @escaping Completion) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        switch request {
        case .url(let url):
            completion(NSWorkspace.shared.open(url) ? .success(()) : .failure(WorkspaceLaunchError.failed("macOS could not open this link. Check that a compatible app is installed.")))
        case .file(let url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                completion(.failure(WorkspaceLaunchError.failed("This file or folder is unavailable. Choose its new location in the tile editor."))); return
            }
            completion(NSWorkspace.shared.open(url) ? .success(()) : .failure(WorkspaceLaunchError.failed("macOS could not open this file or folder. Check its location and access permissions.")))
        case .application(let value):
            let url = value.hasPrefix("/") ? URL(fileURLWithPath: value) : NSWorkspace.shared.urlForApplication(withBundleIdentifier: value)
            guard let url else { completion(.failure(WorkspaceLaunchError.failed("This app is not installed. Choose an application in the tile editor."))); return }
            // The initial invocation also stays on worker: it may synchronously
            // issue sandbox extensions before delivering this asynchronous result.
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { application, error in
                if let error { completion(.failure(error)) }
                else if application != nil { completion(.success(())) }
                else { completion(.failure(WorkspaceLaunchError.failed("macOS did not return an application for this request."))) }
            }
        }
    }
}
