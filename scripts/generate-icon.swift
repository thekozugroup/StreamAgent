import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Pass output .iconset directory") }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let pixels = points * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let unit = CGFloat(pixels) / 1024
    let background = NSBezierPath(roundedRect: NSRect(x: 72*unit, y: 72*unit, width: 880*unit, height: 880*unit), xRadius: 200*unit, yRadius: 200*unit)
    NSColor(calibratedRed: 0.15, green: 0.23, blue: 0.34, alpha: 1).setFill(); background.fill()
    let deck = NSBezierPath(roundedRect: NSRect(x: 142*unit, y: 260*unit, width: 740*unit, height: 504*unit), xRadius: 64*unit, yRadius: 64*unit)
    NSColor(calibratedWhite: 0.05, alpha: 0.8).setFill(); deck.fill()
    for row in 0..<3 { for column in 0..<5 {
        let rect = NSRect(x: CGFloat(177+column*139)*unit, y: CGFloat(297+row*143)*unit, width: 114*unit, height: 114*unit)
        let key = NSBezierPath(roundedRect: rect, xRadius: 22*unit, yRadius: 22*unit)
        if column == 0 { NSColor(calibratedRed: 0.35, green: 0.65, blue: 0.98, alpha: 1).setFill() }
        else { NSColor(calibratedWhite: 0.92, alpha: row == 1 && column == 2 ? 1 : 0.75).setFill() }
        key.fill()
    }}
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    let url = output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}
