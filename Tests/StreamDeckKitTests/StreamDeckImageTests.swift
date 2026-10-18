import AppKit
import ImageIO
import XCTest
@testable import StreamDeckKit

final class StreamDeckImageTests: XCTestCase {
    func testRotationMovesAsymmetricCornersExactly() throws {
        let rotated = try XCTUnwrap(StreamDeckImageEncoder.rotatedPixels(corners()))
        XCTAssertEqual(Array(rotated.prefix(4)), [255, 255, 0, 255])
        XCTAssertEqual(Array(rotated[(71 * 4)..<(72 * 4)]), [0, 0, 255, 255])
        XCTAssertEqual(Array(rotated.suffix(4)), [255, 0, 0, 255])
        XCTAssertNil(StreamDeckImageEncoder.rotatedPixels(StreamDeckRaster(rgba: Data([0]))))
    }

    func testJPEGDimensionsOrientationAndMagicBytes() throws {
        let jpeg = try XCTUnwrap(StreamDeckImageEncoder.encode(corners(), model: .original2019))
        XCTAssertEqual(Array(jpeg.prefix(2)), [255, 216])
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: jpeg))
        XCTAssertEqual(decoded.pixelsWide, 72); XCTAssertEqual(decoded.pixelsHigh, 72)
        try assertColor(decoded, x: 8, y: 8, red: 1, green: 1, blue: 0)
        try assertColor(decoded, x: 63, y: 63, red: 1, green: 0, blue: 0)
        try assertColor(decoded, x: 63, y: 8, red: 0, green: 0, blue: 1)
    }

    func testLegacyBMPIs24BitBottomUpAndRotated() throws {
        let bmp = try XCTUnwrap(StreamDeckImageEncoder.encode(corners(), model: .original2017))
        XCTAssertEqual(bmp.count, 15606)
        XCTAssertEqual(Array(bmp.prefix(6)), [0x42, 0x4D, 0xF6, 0x3C, 0, 0])
        XCTAssertEqual(Array(bmp[10..<14]), [54, 0, 0, 0])
        XCTAssertEqual(Array(bmp[28..<30]), [24, 0])
        XCTAssertEqual(Array(bmp[54..<57]), [0, 255, 0]) // rotated bottom-left is green, BGR
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: bmp))
        try assertColor(decoded, x: 8, y: 8, red: 1, green: 1, blue: 0)
        try assertColor(decoded, x: 63, y: 63, red: 1, green: 0, blue: 0)
    }

    func testAppKitRasterPreservesTopAndBottomBeforeRotation() throws {
        let work = {
            let image = NSImage(size: NSSize(width: 72, height: 72), flipped: false) { _ in
                NSColor.red.setFill(); NSRect(x: 0, y: 36, width: 72, height: 36).fill()
                NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 72, height: 36).fill()
                return true
            }
            let raster = StreamDeckImageEncoder.rasterize(image)
            XCTAssertNotNil(raster)
            if let raster {
                XCTAssertEqual(Array(raster.rgba.prefix(4)), [255, 0, 0, 255])
                XCTAssertEqual(Array(raster.rgba.suffix(4)), [0, 0, 255, 255])
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    }

    func testRasterAspectFitAndOpaqueBlackBackground() {
        let work = {
            let image = NSImage(size: NSSize(width: 144, height: 72), flipped: false) { rect in
                NSColor.red.setFill(); rect.fill(); return true
            }
            let raster = StreamDeckImageEncoder.rasterize(image)!
            XCTAssertEqual(raster.rgba.count, 72 * 72 * 4)
            XCTAssertEqual(Array(raster.rgba.prefix(4)), [0, 0, 0, 255])
            XCTAssertEqual(Array(raster.rgba[(36 * 72 * 4)..<(36 * 72 * 4 + 4)]), [255, 0, 0, 255])
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    }
}

func corners() -> StreamDeckRaster {
    var data = Data()
    for y in 0..<72 {
        for x in 0..<72 {
            let color: [UInt8] = y < 36 ? (x < 36 ? [255, 0, 0, 255] : [0, 255, 0, 255]) :
                (x < 36 ? [0, 0, 255, 255] : [255, 255, 0, 255])
            data.append(contentsOf: color)
        }
    }
    return StreamDeckRaster(rgba: data)
}

func assertColor(_ image: NSBitmapImageRep, x: Int, y: Int, red: CGFloat, green: CGFloat, blue: CGFloat,
                 file: StaticString = #filePath, line: UInt = #line) throws {
    // Assert decoded wire pixels without applying the host display's color profile.
    XCTAssertEqual(image.bitsPerSample, 8, file: file, line: line)
    XCTAssertGreaterThanOrEqual(image.samplesPerPixel, 3, file: file, line: line)
    var samples = [Int](repeating: 0, count: image.samplesPerPixel)
    image.getPixel(&samples, atX: x, y: y)
    XCTAssertEqual(CGFloat(samples[0]) / 255, red, accuracy: 0.08, file: file, line: line)
    XCTAssertEqual(CGFloat(samples[1]) / 255, green, accuracy: 0.08, file: file, line: line)
    XCTAssertEqual(CGFloat(samples[2]) / 255, blue, accuracy: 0.08, file: file, line: line)
}
