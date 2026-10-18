import AppKit
import ImageIO
import UniformTypeIdentifiers

struct StreamDeckRaster: Equatable {
    // Top-down RGBA, opaque black background, fixed size: 72 * 72 * 4.
    let rgba: Data
}

enum StreamDeckImageEncoder {
    static func rasterize(_ image: NSImage) -> StreamDeckRaster? {
        precondition(Thread.isMainThread, "NSImage rendering must run on the main thread")
        let side = StreamDeckProtocol.imageSide
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .high
        // Aspect-fit rather than stretching caller artwork.
        let scale = min(CGFloat(side) / CGFloat(source.width), CGFloat(side) / CGFloat(source.height))
        let size = CGSize(width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
        context.draw(source, in: CGRect(x: (CGFloat(side) - size.width) / 2,
            y: (CGFloat(side) - size.height) / 2, width: size.width, height: size.height))
        return StreamDeckRaster(rgba: Data(bytes: pixels, count: side * side * 4))
    }

    static func rotatedPixels(_ raster: StreamDeckRaster) -> Data? {
        let count = StreamDeckProtocol.imageSide * StreamDeckProtocol.imageSide
        guard raster.rgba.count == count * 4 else { return nil }
        let source = [UInt8](raster.rgba)
        var output = [UInt8](repeating: 0, count: source.count)
        for index in 0..<count {
            let target = (count - index - 1) * 4
            output[target..<(target + 4)] = source[(index * 4)..<(index * 4 + 4)]
        }
        return Data(output)
    }

    static func encode(_ raster: StreamDeckRaster, model: StreamDeckModel) -> Data? {
        guard let rotated = rotatedPixels(raster) else { return nil }
        let side = StreamDeckProtocol.imageSide
        if model == .original2017 {
            // Positive BMP height means rows are bottom-up. 72 * 3 is already 4-byte aligned.
            var bmp = Data([0x42, 0x4D])
            func appendLE(_ value: UInt32, bytes: Int = 4) {
                for byte in 0..<bytes { bmp.append(UInt8((value >> (byte * 8)) & 255)) }
            }
            appendLE(UInt32(StreamDeckProtocol.legacyImageSize))
            appendLE(0); appendLE(54); appendLE(40)
            appendLE(UInt32(side)); appendLE(UInt32(side))
            appendLE(1, bytes: 2); appendLE(24, bytes: 2)
            appendLE(0); appendLE(UInt32(side * side * 3))
            appendLE(3780); appendLE(3780); appendLE(0); appendLE(0)
            let pixels = [UInt8](rotated)
            for y in (0..<side).reversed() {
                for x in 0..<side {
                    let offset = (y * side + x) * 4
                    bmp.append(contentsOf: [pixels[offset + 2], pixels[offset + 1], pixels[offset]])
                }
            }
            return bmp
        }
        guard let provider = CGDataProvider(data: rotated as CFData),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= StreamDeckProtocol.maximumJPEGSize else { return nil }
        return data as Data
    }
}
