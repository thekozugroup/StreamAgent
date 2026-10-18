import Foundation

// Wire formats: https://docs.elgato.com/streamdeck/hid/stream-deck-classic/
// Legacy behavior: python-elgato-streamdeck, Devices/StreamDeckOriginal.py (MIT).
enum StreamDeckModel: Int, CaseIterable {
    case original2017 = 0x0060
    case original2019 = 0x006D
    case mk2 = 0x0080

    var name: String {
        switch self {
        case .original2017: return "Stream Deck Original (2017)"
        case .original2019: return "Stream Deck Original (2019)"
        case .mk2: return "Stream Deck MK.2"
        }
    }

    func physicalKey(_ logicalKey: Int) -> Int {
        self == .original2017 ? logicalKey / 5 * 5 + 4 - logicalKey % 5 : logicalKey
    }
}

enum StreamDeckProtocol {
    static let keyCount = 15
    static let imageSide = 72
    static let legacyImageSize = 54 + imageSide * imageSide * 3
    // Bounds malformed/accidental inputs before allocating packet arrays.
    static let maximumJPEGSize = 256 * 1024

    static func imageReports(_ image: Data, key: Int, model: StreamDeckModel) -> [Data]? {
        guard (0..<keyCount).contains(key), !image.isEmpty else { return nil }
        if model == .original2017 {
            guard image.count == legacyImageSize else { return nil }
            // The original firmware requires two equal halves, not 8175-byte chunks.
            let half = image.count / 2
            return (0..<2).map { page in
                var report = Data(repeating: 0, count: 8191)
                report.replaceSubrange(0..<6, with: [2, 1, UInt8(page + 1), 0,
                    UInt8(page == 1 ? 1 : 0), UInt8(model.physicalKey(key) + 1)])
                report.replaceSubrange(16..<(16 + half), with: image[(page * half)..<((page + 1) * half)])
                return report
            }
        }
        guard image.count <= maximumJPEGSize else { return nil }
        let capacity = 1016
        return stride(from: 0, to: image.count, by: capacity).enumerated().map { page, offset in
            let length = min(capacity, image.count - offset)
            var report = Data(repeating: 0, count: 1024)
            report.replaceSubrange(0..<8, with: [2, 7, UInt8(key),
                UInt8(offset + length == image.count ? 1 : 0),
                UInt8(length & 255), UInt8(length >> 8), UInt8(page & 255), UInt8(page >> 8)])
            report.replaceSubrange(8..<(8 + length), with: image[offset..<(offset + length)])
            return report
        }
    }

    static func brightnessReport(_ percent: Int, model: StreamDeckModel) -> Data {
        let value = UInt8(min(100, max(0, percent)))
        var report = Data(repeating: 0, count: model == .original2017 ? 17 : 32)
        let header: [UInt8] = model == .original2017 ? [5, 0x55, 0xAA, 0xD1, 1, value] : [3, 8, value]
        report.replaceSubrange(0..<header.count, with: header)
        return report
    }
}

struct StreamDeckInputState {
    private var previous = [Bool](repeating: false, count: StreamDeckProtocol.keyCount)

    mutating func consume(_ report: Data, model: StreamDeckModel) -> [Int] {
        let bytes = [UInt8](report)
        let start = model == .original2017 ? 1 : 4
        guard bytes.count >= start + 15, bytes.count <= 512, bytes[0] == 1 else { return [] }
        if model != .original2017 {
            guard bytes[1] == 0, bytes[2] == 15, bytes[3] == 0 else { return [] }
        }
        let payload = Array(bytes[start..<(start + 15)])
        guard payload.allSatisfy({ $0 == 0 || $0 == 1 }) else { return [] }
        let current = (0..<15).map { payload[model.physicalKey($0)] == 1 }
        let rising = (0..<15).filter { current[$0] && !previous[$0] }
        previous = current
        return rising
    }
}
