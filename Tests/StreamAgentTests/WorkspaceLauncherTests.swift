import XCTest
import Foundation
@testable import StreamAgent

final class WorkspaceLauncherTests: XCTestCase {
    private let firstURL = URL(string: "https://example.invalid/first")!
    private let nextURL = URL(string: "https://example.invalid/next")!

    @MainActor
    func testBlockedOpenerTimesOutWithoutBlockingMainAndRejectsRetriesUntilReturn() async throws {
        let started = expectation(description: "blocking opener entered")
        let heartbeat = expectation(description: "main queue still responds")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let log = LaunchLog()
        let firstRequest = WorkspaceLaunchRequest.url(firstURL)
        let launcher = WorkspaceLauncher(timeout: 0.06) { request, completion in
            log.record(request)
            XCTAssertFalse(Thread.isMainThread)
            if request == firstRequest { started.fulfill(); gate.wait() }
            completion(.success(()))
        }
        let began = Date()
        let first = Task { @MainActor in await self.launchError(launcher, firstRequest) }
        await fulfillment(of: [started], timeout: 1)
        DispatchQueue.main.async { heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 0.5)
        let timeout = await first.value
        XCTAssertEqual(timeout, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)
        XCTAssertTrue(launcher.isInFlight)
        let retryBegan = Date()
        for _ in 0..<30 {
            let error = await launchError(launcher, .url(nextURL))
            XCTAssertEqual(error, .busy)
        }
        XCTAssertLessThan(Date().timeIntervalSince(retryBegan), 0.5)
        XCTAssertEqual(log.requests, [firstRequest], "Rejected requests must never queue additional OS work")
        gate.signal()
        await waitUntilIdle(launcher)
        try await launcher.open(.url(nextURL))
        XCTAssertEqual(log.requests, [firstRequest, .url(nextURL)])
        XCTAssertFalse(launcher.isInFlight)
    }

    @MainActor
    func testCallbackBeforeInvocationReturnsDoesNotReleaseStuckWorkerOrResumeTwice() async throws {
        let started = expectation(description: "callback delivered but invocation stuck")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let firstRequest = WorkspaceLaunchRequest.url(firstURL)
        let launcher = WorkspaceLauncher(timeout: 0.04) { request, completion in
            completion(.success(()))
            if request == firstRequest { started.fulfill(); gate.wait() }
            completion(.failure(WorkspaceLaunchError.failed("Duplicate callback must be ignored")))
        }
        let first = Task { @MainActor in await self.launchError(launcher, firstRequest) }
        await fulfillment(of: [started], timeout: 1)
        let error = await first.value
        XCTAssertEqual(error, .timedOut)
        XCTAssertTrue(launcher.isInFlight)
        let busy = await launchError(launcher, .url(nextURL))
        XCTAssertEqual(busy, .busy)
        gate.signal()
        await waitUntilIdle(launcher)
        try await launcher.open(.url(nextURL))
        XCTAssertFalse(launcher.isInFlight)
    }

    @MainActor
    func testReturnedAsyncInvocationStaysBusyUntilLateCallbackThenAllowsNextLaunch() async throws {
        let captured = CallbackBox()
        let firstRequest = WorkspaceLaunchRequest.application("com.example.Fixture")
        let launcher = WorkspaceLauncher(timeout: 0.04) { request, completion in
            if request == firstRequest { captured.set(completion) }
            else { completion(.success(())) }
        }
        let error = await launchError(launcher, firstRequest)
        XCTAssertEqual(error, .timedOut)
        XCTAssertTrue(launcher.isInFlight)
        let busy = await launchError(launcher, .url(nextURL))
        XCTAssertEqual(busy, .busy)
        let callback = try XCTUnwrap(captured.get())
        callback(.failure(WorkspaceLaunchError.failed("Late result")))
        callback(.success(())) // Exactly-once continuation even after timeout and duplicate completion.
        await waitUntilIdle(launcher)
        try await launcher.open(.url(nextURL))
        XCTAssertFalse(launcher.isInFlight)
    }

    @MainActor
    func testFailureReleasesSlotAndSuccessCancelsItsDeadline() async throws {
        let firstRequest = WorkspaceLaunchRequest.url(firstURL)
        let launcher = WorkspaceLauncher(timeout: 0.02) { request, completion in
            if request == firstRequest { completion(.failure(WorkspaceLaunchError.failed("Rejected by macOS"))) }
            else { completion(.success(())) }
        }
        let error = await launchError(launcher, firstRequest)
        XCTAssertEqual(error, .failed("Rejected by macOS"))
        XCTAssertFalse(launcher.isInFlight)
        try await launcher.open(.url(nextURL))
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertFalse(launcher.isInFlight)
        try await launcher.open(.url(nextURL))
    }

    @MainActor
    func testEveryActionLaunchRouteUsesInjectedWorkerIncludingCodexAndSettings() async throws {
        let log = LaunchLog()
        let launcher = WorkspaceLauncher(timeout: 0.5) { request, completion in
            XCTAssertFalse(Thread.isMainThread)
            log.record(request); completion(.success(()))
        }
        let runner = ActionRunner(tracker: ExternalAppTracker(), launcher: launcher)
        try await runner.run(.init(kind: .openURL, value: "https://example.invalid"))
        try await runner.run(.init(kind: .openFile, value: "/tmp/streamagent-launch-fixture"))
        try await runner.run(.init(kind: .openApp, value: "com.example.Fixture"))
        try await runner.run(.init(kind: .appleShortcut, value: "Fixture shortcut"))
        try await runner.openCodexThread(URL(string: "codex://threads/fixture-1")!)
        try await runner.openAccessibilitySettings()
        let requests = log.requests
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(requests[0], .url(URL(string: "https://example.invalid")!))
        XCTAssertEqual(requests[1], .file(URL(fileURLWithPath: "/tmp/streamagent-launch-fixture")))
        XCTAssertEqual(requests[2], .application("com.example.Fixture"))
        if case .url(let shortcut) = requests[3] { XCTAssertEqual(shortcut.scheme, "shortcuts"); XCTAssertEqual(shortcut.host, "run-shortcut") } else { XCTFail("Expected Apple Shortcuts link") }
        XCTAssertEqual(requests[4], .url(URL(string: "codex://threads/fixture-1")!))
        if case .url(let settings) = requests[5] { XCTAssertEqual(settings.scheme, "x-apple.systempreferences") } else { XCTFail("Expected System Settings link") }
        do { try await runner.openCodexThread(URL(string: "https://example.invalid")!); XCTFail("Expected invalid thread link") }
        catch { XCTAssertEqual(log.requests.count, 6) }
    }

    private func launchError(_ launcher: WorkspaceLauncher, _ request: WorkspaceLaunchRequest) async -> WorkspaceLaunchError? {
        do { try await launcher.open(request); return nil }
        catch { return error as? WorkspaceLaunchError }
    }
    private func waitUntilIdle(_ launcher: WorkspaceLauncher) async {
        for _ in 0..<200 {
            if !launcher.isInFlight { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Opener did not release its in-flight slot")
    }
}

private final class LaunchLog {
    private let lock = NSLock()
    private var values: [WorkspaceLaunchRequest] = []
    func record(_ request: WorkspaceLaunchRequest) { lock.lock(); values.append(request); lock.unlock() }
    var requests: [WorkspaceLaunchRequest] { lock.lock(); defer { lock.unlock() }; return values }
}
private final class CallbackBox {
    private let lock = NSLock()
    private var callback: WorkspaceLauncher.Completion?
    func set(_ value: @escaping WorkspaceLauncher.Completion) { lock.lock(); callback = value; lock.unlock() }
    func get() -> WorkspaceLauncher.Completion? { lock.lock(); defer { lock.unlock() }; return callback }
}
