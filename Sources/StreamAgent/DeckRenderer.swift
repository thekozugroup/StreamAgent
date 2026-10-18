import AppKit
import CodexBridge

struct DeckTilePresentation: Equatable {
    enum Tint: String { case neutral, blue, green, amber, red, purple
        var color: NSColor {
            switch self { case .neutral: return .white; case .blue: return .systemBlue; case .green: return .systemGreen; case .amber: return .systemOrange; case .red: return .systemRed; case .purple: return .systemPurple }
        }
    }
    var title: String
    var subtitle = ""
    var symbol: String
    var tint: Tint = .neutral
    var pressed = false
}

enum DeckRenderer {
    static func presentation(for agent: AgentSession) -> DeckTilePresentation {
        let tint: DeckTilePresentation.Tint
        switch agent.status {
        case .working, .thinking: tint = .blue
        case .waiting: tint = .amber
        case .done: tint = .green
        case .failed: tint = .red
        case .idle, .unknown: tint = .neutral
        }
        return .init(title: agent.displayName, subtitle: agent.status.label, symbol: agent.status.symbol, tint: tint)
    }
    static func image(_ tile: DeckTilePresentation, size: Int = 144) -> NSImage {
        let side = CGFloat(size)
        // An explicit bitmap avoids dependence on a window or screen during --smoke-test.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        let bounds = NSRect(x: 0, y: 0, width: side, height: side)
        NSColor(calibratedWhite: tile.pressed ? 0.22 : 0.055, alpha: 1).setFill(); bounds.fill()
        let scale = side / 144
        let configuration = NSImage.SymbolConfiguration(pointSize: 42 * scale, weight: .medium).applying(NSImage.SymbolConfiguration(paletteColors: [tile.tint.color]))
        let symbol = NSImage(systemSymbolName: tile.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            ?? NSImage(systemSymbolName: "questionmark.square", accessibilityDescription: nil)!
        let symbolRect = NSRect(x: (side - 48 * scale) / 2, y: 65 * scale, width: 48 * scale, height: 48 * scale)
        context.saveGraphicsState()
        symbol.draw(in: symbolRect)
        context.restoreGraphicsState()
        draw(tile.title, rect: NSRect(x: 7 * scale, y: 28 * scale, width: side - 14 * scale, height: 31 * scale), font: .systemFont(ofSize: 17 * scale, weight: .semibold), color: .white, lines: 2)
        draw(tile.subtitle, rect: NSRect(x: 5 * scale, y: 7 * scale, width: side - 10 * scale, height: 20 * scale), font: .systemFont(ofSize: 13 * scale, weight: .medium), color: tile.tint.color, lines: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: side, height: side)); image.addRepresentation(bitmap)
        return image
    }
    private static func draw(_ text: String, rect: NSRect, font: NSFont, color: NSColor, lines: Int) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [.font:font, .foregroundColor:color, .paragraphStyle:paragraph])
    }
}


enum DeckDiff {
    static func changedKeys(previous: [Int: DeckTilePresentation], current: [DeckTilePresentation]) -> [Int] {
        current.indices.filter { previous[$0] != current[$0] }
    }
}
