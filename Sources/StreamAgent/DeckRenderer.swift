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
    var isEmpty = false
    var progress: Double?

    // Names remain available to VoiceOver and the inspector, never on the LCD.
    func hasSameFace(as other: Self) -> Bool {
        symbol == other.symbol && tint == other.tint && pressed == other.pressed
            && isEmpty == other.isEmpty && progress == other.progress
    }
}

enum DeckRenderer {
    // Original Stream Deck key displays are 72 x 72, not miniature desktop cards.
    static let nativeSide = 72
    static let symbolInset: CGFloat = 15

    static func presentation(for action: ActionTile, focus: FocusState) -> DeckTilePresentation {
        var tile = DeckTilePresentation(title: action.label.isEmpty ? "Empty" : action.label,
                                        symbol: action.symbol, isEmpty: action.action.kind == .none)
        // Resolve old generic defaults without modifying the saved configuration.
        if action.symbol == "folder" {
            if action.action.kind == .openApp, action.action.value == "com.apple.finder" { tile.symbol = "macwindow" }
            if action.action.kind == .openFile, URL(fileURLWithPath: action.action.value).lastPathComponent == "Applications" { tile.symbol = "square.grid.2x2" }
        }
        if action.action.kind == .focus {
            if action.action.value == "startPause" {
                tile.title = "\(action.label.isEmpty ? "Start / Pause" : action.label) · \(focus.display)"
                tile.subtitle = focus.phase.rawValue.capitalized
                tile.symbol = focus.phase == .running ? "pause.fill" : focus.phase == .finished ? "checkmark" : "play.fill"
                tile.tint = focus.phase == .finished ? .green : .purple
                tile.progress = (max(0, min(1, focus.remaining / max(1, focus.duration))) * 60).rounded() / 60
            } else if action.symbol == "timer", let minutes = Int(action.action.value) {
                // Essential duration glyphs work on custom pages and profiles too.
                tile.symbol = minutes == 60 ? "hourglass" : "\(minutes).circle"
            }
        }
        return tile
    }

    static func presentation(for agent: AgentSession) -> DeckTilePresentation {
        let tint: DeckTilePresentation.Tint
        let symbol: String
        switch agent.status {
        case .working: tint = .blue; symbol = "arrow.triangle.2.circlepath"
        case .thinking: tint = .blue; symbol = "ellipsis"
        case .waiting: tint = .amber; symbol = "hand.raised"
        case .done: tint = .green; symbol = "checkmark"
        case .failed: tint = .red; symbol = "exclamationmark.triangle"
        case .idle: tint = .neutral; symbol = "pause"
        case .unknown: tint = .neutral; symbol = "questionmark"
        }
        return .init(title: agent.displayName, subtitle: agent.status.label, symbol: symbol, tint: tint)
    }

    static func symbolRect(for imageSize: NSSize, in bounds: NSRect, inset: CGFloat) -> NSRect {
        let available = bounds.insetBy(dx: inset, dy: inset)
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let factor = min(available.width / imageSize.width, available.height / imageSize.height)
        let size = NSSize(width: imageSize.width * factor, height: imageSize.height * factor)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    static func image(_ tile: DeckTilePresentation, size: Int = nativeSide) -> NSImage {
        let side = CGFloat(size)
        // An explicit bitmap avoids dependence on a window or screen during --smoke-test.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        let bounds = NSRect(x: 0, y: 0, width: side, height: side)
        NSColor(calibratedWhite: tile.pressed ? 0.16 : 0.015, alpha: 1).setFill(); bounds.fill()
        let scale = side / CGFloat(nativeSide)
        if !tile.isEmpty {
            // The physical display stays dark even when the Mac uses Light Mode.
            var color = NSColor.white
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                color = tile.tint.color.usingColorSpace(.deviceRGB) ?? .white
            }
            if let progress = tile.progress, progress.isFinite {
                let ringBounds = bounds.insetBy(dx: 7 * scale, dy: 7 * scale)
                let track = NSBezierPath(ovalIn: ringBounds); track.lineWidth = 2 * scale
                color.withAlphaComponent(0.22).setStroke(); track.stroke()
                let arc = NSBezierPath(); arc.lineWidth = 2 * scale; arc.lineCapStyle = .round
                arc.appendArc(withCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: ringBounds.width / 2,
                              startAngle: 90, endAngle: 90 - CGFloat(min(1, max(0, progress))) * 360, clockwise: true)
                color.setStroke(); arc.stroke()
            }
            let configuration = NSImage.SymbolConfiguration(pointSize: 40 * scale, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            let base = NSImage(systemSymbolName: tile.symbol, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil)!
            let symbol = base.withSymbolConfiguration(configuration) ?? base
            let inset = (tile.progress == nil ? symbolInset : 22) * scale
            symbol.draw(in: symbolRect(for: symbol.size, in: bounds, inset: inset))
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: side, height: side)); image.addRepresentation(bitmap)
        return image
    }
}


enum DeckDiff {
    static func changedKeys(previous: [Int: DeckTilePresentation], current: [DeckTilePresentation]) -> [Int] {
        current.indices.filter { index in
            guard let old = previous[index] else { return true }
            return !old.hasSameFace(as: current[index])
        }
    }
}
