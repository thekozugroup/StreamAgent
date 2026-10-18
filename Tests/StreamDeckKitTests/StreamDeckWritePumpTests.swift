import AppKit
import Combine
import IOKit
import XCTest
@testable import StreamDeckKit

final class StreamDeckWritePumpTests: XCTestCase {
    func testBurstCoalescesToOneImagePerKeyAndWritesOffMain() {
        let pump = StreamDeckWritePump()
        let block = DispatchSemaphore(value: 0)
        pump.queue.async { block.wait() }
        let done = expectation(description: "15 final image transfers")
        done.expectedFulfillmentCount = 15
        var reportCount = 0
        let output = StreamDeckOutput(model: .original2017) { data, feature in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertFalse(feature)
            XCTAssertEqual(data.count, 8191)
            reportCount += 1
            if data[4] == 1 { done.fulfill() }
            return kIOReturnSuccess
        }
        pump.connect(output)
        for version in 0..<300 {
            for key in 0..<15 { pump.image(solid(UInt8(version & 255)), key: key) }
        }
        block.signal()
        wait(for: [done], timeout: 5)
        pump.queue.sync {}
        XCTAssertEqual(reportCount, 30)
        pump.connect(nil)
    }

    func testInFlightTransferCompletesThenOnlyLatestReplacementIsSent() {
        let pump = StreamDeckWritePump()
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let finished = expectation(description: "original and latest complete")
        finished.expectedFulfillmentCount = 2
        var headers: [[UInt8]] = []
        let output = StreamDeckOutput(model: .original2017) { data, _ in
            headers.append(Array(data.prefix(6)))
            if headers.count == 1 { entered.signal(); _ = resume.wait(timeout: .now() + 5) }
            if data[4] == 1 { finished.fulfill() }
            return kIOReturnSuccess
        }
        pump.connect(output)
        pump.image(solid(10), key: 0)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        for index in 0..<300 { pump.image(solid(UInt8(index & 255)), key: 0) }
        resume.signal()
        wait(for: [finished], timeout: 5)
        pump.queue.sync {}
        XCTAssertEqual(headers.map { $0[2] }, [1, 2, 1, 2])
        pump.connect(nil)
    }

    func testBrightnessBurstClampsAndKeepsOnlyLatest() {
        let pump = StreamDeckWritePump()
        let block = DispatchSemaphore(value: 0)
        pump.queue.async { block.wait() }
        let done = expectation(description: "one brightness")
        var calls = 0
        pump.connect(StreamDeckOutput(model: .mk2) { data, feature in
            XCTAssertTrue(feature)
            XCTAssertEqual(Array(data.prefix(3)), [3, 8, 100])
            calls += 1; done.fulfill(); return kIOReturnSuccess
        })
        for value in 0..<1000 { pump.brightness(value) }
        block.signal()
        wait(for: [done], timeout: 2)
        pump.queue.sync {}
        XCTAssertEqual(calls, 1)
        pump.connect(nil)
    }

    func testIdenticalImageSkippedUntilCacheCleared() {
        let pump = StreamDeckWritePump()
        var calls = 0
        let first = expectation(description: "first transfer")
        let second = expectation(description: "redraw after clear")
        pump.connect(StreamDeckOutput(model: .original2017) { data, _ in
            calls += 1
            if calls == 2 { first.fulfill() }
            if calls == 4 { second.fulfill() }
            return kIOReturnSuccess
        })
        pump.image(solid(1), key: 0)
        wait(for: [first], timeout: 2)
        pump.queue.sync {}
        for _ in 0..<100 { pump.image(solid(1), key: 0) }
        pump.queue.sync {}
        XCTAssertEqual(calls, 2)
        pump.clearCache()
        pump.queue.sync {}
        pump.image(solid(1), key: 0)
        wait(for: [second], timeout: 2)
        pump.queue.sync {}
        XCTAssertEqual(calls, 4)
        pump.connect(nil)
    }

    func testDisconnectDropsQueuedWritesAndReconnectReplaysLatest() {
        let pump = StreamDeckWritePump()
        let block = DispatchSemaphore(value: 0)
        pump.queue.async { block.wait() }
        var oldCalls = 0
        pump.connect(StreamDeckOutput(model: .original2017) { _, _ in oldCalls += 1; return kIOReturnSuccess })
        pump.image(solid(12), key: 14)
        pump.connect(nil)
        let done = expectation(description: "replay on new connection")
        var newCalls = 0
        pump.connect(StreamDeckOutput(model: .original2017) { data, _ in
            XCTAssertEqual(data[5], 11)
            newCalls += 1
            if data[4] == 1 { done.fulfill() }
            return kIOReturnSuccess
        })
        block.signal()
        wait(for: [done], timeout: 2)
        pump.queue.sync {}
        XCTAssertEqual(oldCalls, 0); XCTAssertEqual(newCalls, 2)
        pump.connect(nil)
    }

    func testWriteFailureStopsTransferAndReportsOnlySuccessfulCount() {
        let pump = StreamDeckWritePump()
        let done = expectation(description: "failed report")
        var calls = 0
        pump.onResult = { _, count, result in
            XCTAssertEqual(count, 1); XCTAssertEqual(result, kIOReturnNotPermitted); done.fulfill()
        }
        pump.connect(StreamDeckOutput(model: .original2017) { _, _ in
            calls += 1
            return calls == 1 ? kIOReturnSuccess : kIOReturnNotPermitted
        })
        pump.image(solid(3), key: 0)
        wait(for: [done], timeout: 2)
        pump.image(solid(4), key: 1)
        pump.queue.sync {}
        XCTAssertEqual(calls, 2)
        pump.connect(nil)
    }

    func testInvalidRasterAndKeyDoNotWrite() {
        let pump = StreamDeckWritePump()
        var count = 0
        pump.connect(StreamDeckOutput(model: .mk2) { _, _ in count += 1; return kIOReturnSuccess })
        pump.image(solid(0), key: -1)
        pump.image(solid(0), key: 15)
        pump.image(StreamDeckRaster(rgba: Data()), key: 0)
        pump.queue.sync {}
        XCTAssertEqual(count, 0)
        pump.connect(nil)
    }

    func testBackgroundPublicMethodPublishesOnMain() {
        let device = StreamDeckDevice()
        let done = expectation(description: "validation publication on main")
        let subscription = device.$statusMessage.dropFirst().sink { status in
            if status.contains("Invalid key") { XCTAssertTrue(Thread.isMainThread); done.fulfill() }
        }
        DispatchQueue.global().async { device.setKeyImage(NSImage(size: NSSize(width: 1, height: 1)), key: 15) }
        wait(for: [done], timeout: 2)
        withExtendedLifetime(subscription) {}
    }
}

func solid(_ value: UInt8) -> StreamDeckRaster {
    StreamDeckRaster(rgba: Data(repeating: value, count: 72 * 72 * 4))
}
