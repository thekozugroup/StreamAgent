import AppKit
import XCTest
@testable import StreamDeckKit

final class StreamDeckProtocolTests: XCTestCase {
    func testModelAndPhysicalColumnMapping() {
        XCTAssertEqual(StreamDeckModel.allCases.map(\.rawValue), [0x60, 0x6D, 0x80])
        XCTAssertNil(StreamDeckModel(rawValue: 0xFFFF))
        for key in 0..<15 {
            XCTAssertEqual(StreamDeckModel.original2017.physicalKey(key), key / 5 * 5 + 4 - key % 5)
            XCTAssertEqual(StreamDeckModel.original2017.physicalKey(StreamDeckModel.original2017.physicalKey(key)), key)
            XCTAssertEqual(StreamDeckModel.original2019.physicalKey(key), key)
            XCTAssertEqual(StreamDeckModel.mk2.physicalKey(key), key)
        }
    }

    func testModernPacketHeadersPaddingAndReassembly() throws {
        let payload = Data((0..<2039).map { UInt8($0 & 255) })
        let reports = try XCTUnwrap(StreamDeckProtocol.imageReports(payload, key: 14, model: .original2019))
        XCTAssertEqual(reports.count, 3)
        XCTAssertEqual(Array(reports[0].prefix(8)), [2, 7, 14, 0, 0xF8, 3, 0, 0])
        XCTAssertEqual(Array(reports[1].prefix(8)), [2, 7, 14, 0, 0xF8, 3, 1, 0])
        XCTAssertEqual(Array(reports[2].prefix(8)), [2, 7, 14, 1, 7, 0, 2, 0])
        var reconstructed = Data()
        for report in reports {
            XCTAssertEqual(report.count, 1024)
            let length = Int(report[4]) | Int(report[5]) << 8
            reconstructed.append(report[8..<(8 + length)])
            XCTAssertTrue(report[(8 + length)...].allSatisfy { $0 == 0 })
        }
        XCTAssertEqual(reconstructed, payload)
        XCTAssertEqual(StreamDeckProtocol.imageReports(payload, key: 14, model: .mk2), reports)
    }

    func testExactPayloadBoundaryAndPageNumberLittleEndian() throws {
        let one = try XCTUnwrap(StreamDeckProtocol.imageReports(Data(repeating: 8, count: 1016), key: 0, model: .mk2))
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0][3], 1)
        let large = try XCTUnwrap(StreamDeckProtocol.imageReports(Data(repeating: 8, count: 1016 * 256 + 1), key: 0, model: .mk2))
        XCTAssertEqual(Array(large.last!.prefix(8)), [2, 7, 0, 1, 1, 0, 0, 1])
    }

    func testPacketLimitsRejectEmptyOversizeAndInvalidKey() {
        for key in [-1, 15, Int.max] {
            XCTAssertNil(StreamDeckProtocol.imageReports(Data([1]), key: key, model: .mk2))
        }
        XCTAssertNil(StreamDeckProtocol.imageReports(Data(), key: 0, model: .mk2))
        XCTAssertNil(StreamDeckProtocol.imageReports(Data(repeating: 0, count: StreamDeckProtocol.maximumJPEGSize + 1), key: 0, model: .mk2))
        XCTAssertNil(StreamDeckProtocol.imageReports(Data(repeating: 0, count: StreamDeckProtocol.legacyImageSize - 1), key: 0, model: .original2017))
    }

    func testLegacyTwoHalfPacketsAndMirroredKey() throws {
        let bytes = Data((0..<StreamDeckProtocol.legacyImageSize).map { UInt8($0 & 255) })
        let reports = try XCTUnwrap(StreamDeckProtocol.imageReports(bytes, key: 5, model: .original2017))
        XCTAssertEqual(reports.map(\.count), [8191, 8191])
        XCTAssertEqual(Array(reports[0].prefix(16)), [2, 1, 1, 0, 0, 10] + [UInt8](repeating: 0, count: 10))
        XCTAssertEqual(Array(reports[1].prefix(6)), [2, 1, 2, 0, 1, 10])
        let half = bytes.count / 2
        XCTAssertEqual(Data(reports[0][16..<(16 + half)]) + Data(reports[1][16..<(16 + half)]), bytes)
        XCTAssertTrue(reports[0][(16 + half)...].allSatisfy { $0 == 0 })
    }

    func testBrightnessClampsBothModelsAndUsesCorrectFeatureHeader() {
        for model in StreamDeckModel.allCases {
            let low = StreamDeckProtocol.brightnessReport(Int.min, model: model)
            let high = StreamDeckProtocol.brightnessReport(Int.max, model: model)
            let index = model == .original2017 ? 5 : 2
            XCTAssertEqual(low[index], 0)
            XCTAssertEqual(high[index], 100)
            XCTAssertEqual(StreamDeckProtocol.brightnessReport(42, model: model)[index], 42)
            if model == .original2017 {
                XCTAssertEqual(low.count, 17)
                XCTAssertEqual(Array(high.prefix(6)), [5, 0x55, 0xAA, 0xD1, 1, 100])
            } else {
                XCTAssertEqual(low.count, 32)
                XCTAssertEqual(Array(high.prefix(3)), [3, 8, 100])
            }
        }
    }

    func testInputRisingEdgesReleaseAndMultipleKeys() {
        var state = StreamDeckInputState()
        XCTAssertEqual(state.consume(modernInput([0, 4, 14]), model: .original2019), [0, 4, 14])
        XCTAssertEqual(state.consume(modernInput([0, 4, 14]), model: .original2019), [])
        XCTAssertEqual(state.consume(modernInput([4]), model: .original2019), [])
        XCTAssertEqual(state.consume(modernInput([0, 4]), model: .original2019), [0])
    }

    func testLegacyInputMirrorsColumnsAndSuppressesHeldKeys() {
        var state = StreamDeckInputState()
        var report = Data([1] + [UInt8](repeating: 0, count: 15))
        report[1 + 4] = 1; report[1 + 9] = 1; report[1 + 14] = 1
        XCTAssertEqual(state.consume(report, model: .original2017), [0, 5, 10])
        XCTAssertEqual(state.consume(report, model: .original2017), [])
    }

    func testMalformedInputDoesNotChangeHeldState() {
        var state = StreamDeckInputState()
        let held = modernInput([2])
        XCTAssertEqual(state.consume(held, model: .mk2), [2])
        var malformed = [Data(), Data([1]), Data(held.prefix(18))]
        for (index, value) in [(0, 2), (1, 1), (2, 14), (3, 1), (4, 2)] {
            var report = modernInput([]); report[index] = UInt8(value); malformed.append(report)
        }
        malformed.append(Data(repeating: 0, count: 513))
        for report in malformed { XCTAssertEqual(state.consume(report, model: .mk2), []) }
        XCTAssertEqual(state.consume(held, model: .mk2), [])
        XCTAssertEqual(state.consume(modernInput([]), model: .mk2), [])
        XCTAssertEqual(state.consume(held, model: .mk2), [2])
    }

    func testPaddedModernInputAcceptedAndWrongLegacyIDRejected() {
        var modern = StreamDeckInputState()
        let report = modernInput([3]) + Data(repeating: 0, count: 512 - 19)
        XCTAssertEqual(modern.consume(report, model: .mk2), [3])
        var legacy = StreamDeckInputState()
        XCTAssertEqual(legacy.consume(Data([2] + [UInt8](repeating: 1, count: 15)), model: .original2017), [])
    }
}

func modernInput(_ keys: [Int]) -> Data {
    var report = Data([1, 0, 15, 0] + [UInt8](repeating: 0, count: 15))
    for key in keys { report[4 + key] = 1 }
    return report
}
