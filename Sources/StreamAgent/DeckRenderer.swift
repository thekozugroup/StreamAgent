import AppKit
import CodexBridge

struct DeckTilePresentation: Equatable {
    enum Accessory: String, CaseIterable { case none, running, selected, locked, busy, success, failure }
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
    var identity: KeyIdentity? = nil
    var accessory: Accessory = .none
    var dimmed = false

    // Names remain available to VoiceOver and the inspector, never on the LCD.
    func hasSameFace(as other: Self) -> Bool {
        symbol == other.symbol && tint == other.tint && pressed == other.pressed
            && isEmpty == other.isEmpty && progress == other.progress
            && identity == other.identity && accessory == other.accessory && dimmed == other.dimmed
    }
}

enum DeckRenderer {
    // Original Stream Deck key displays are 72 x 72, not miniature desktop cards.
    static let nativeSide = 72
    static let symbolInset: CGFloat = 15
    static let identitySide: CGFloat = 18
    static let identityInnerRadius: CGFloat = 8

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

    /// The only rounded corner faces the glyph. Top and right meet the LCD edges.
    static func identityPath(in bounds: NSRect) -> NSBezierPath {
        let scale = bounds.width / CGFloat(nativeSide)
        let side = identitySide * scale, radius = identityInnerRadius * scale
        let corner = NSRect(x: bounds.maxX - side, y: bounds.maxY - side, width: side, height: side)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: corner.minX, y: corner.maxY))
        path.line(to: NSPoint(x: corner.maxX, y: corner.maxY))
        path.line(to: NSPoint(x: corner.maxX, y: corner.minY))
        path.line(to: NSPoint(x: corner.minX + radius, y: corner.minY))
        path.appendArc(withCenter: NSPoint(x: corner.minX + radius, y: corner.minY + radius),
                       radius: radius, startAngle: 270, endAngle: 180, clockwise: true)
        path.close()
        return path
    }

    private static func drawIdentity(_ identity: KeyIdentity, in bounds: NSRect, scale: CGFloat) {
        let color = identity.color.usingColorSpace(.deviceRGB) ?? .white
        color.setFill(); identityPath(in: bounds).fill()
        let count = identity.threadMarkCount
        let spacing = 5 * scale, diameter = 2.6 * scale
        let centerX = bounds.maxX - identitySide * scale / 2
        let centerY = bounds.maxY - 6 * scale
        NSColor(calibratedWhite: 0.025, alpha: 1).setFill()
        for index in 0..<count {
            let x = centerX + (CGFloat(index) - CGFloat(count - 1) / 2) * spacing
            NSBezierPath(ovalIn: NSRect(x: x - diameter / 2, y: centerY - diameter / 2,
                                       width: diameter, height: diameter)).fill()
        }
    }

    private static func drawSymbol(_ name: String, in rect: NSRect, pointSize: CGFloat, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil)!
        let symbol = base.withSymbolConfiguration(configuration) ?? base
        symbol.draw(in: symbolRect(for: symbol.size, in: rect, inset: 0))
    }

    private static func drawAccessory(_ accessory: DeckTilePresentation.Accessory, in bounds: NSRect, scale: CGFloat) {
        guard accessory != .none else { return }
        let backing = NSRect(x: bounds.maxX - 18 * scale, y: bounds.minY + 2 * scale,
                             width: 16 * scale, height: 16 * scale)
        let path = NSBezierPath(ovalIn: backing)
        NSColor(calibratedWhite: 0.035, alpha: 1).setFill(); path.fill()
        NSColor(calibratedWhite: 1, alpha: 0.18).setStroke(); path.lineWidth = scale; path.stroke()
        let name: String, color: NSColor
        switch accessory {
        case .none: return
        case .running: name = "circle.fill"; color = .systemGreen
        case .selected: name = "checkmark.circle.fill"; color = .systemBlue
        case .locked: name = "lock.fill"; color = .systemOrange
        case .busy: name = "ellipsis"; color = .white
        case .success: name = "checkmark"; color = .systemGreen
        case .failure: name = "exclamationmark"; color = .systemRed
        }
        let inset = (accessory == .running ? 6 : 3) * scale
        drawSymbol(name, in: backing.insetBy(dx: inset, dy: inset), pointSize: 12 * scale,
                   color: color.usingColorSpace(.deviceRGB) ?? .white)
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
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                let tint = tile.tint.color.usingColorSpace(.deviceRGB) ?? .white
                // Preserve recognition on a small LCD even when permission is missing.
                let color = tile.dimmed ? tint.withAlphaComponent(0.68) : tint
                if let progress = tile.progress, progress.isFinite {
                    let ringBounds = bounds.insetBy(dx: 7 * scale, dy: 7 * scale)
                    let track = NSBezierPath(ovalIn: ringBounds); track.lineWidth = 2 * scale
                    color.withAlphaComponent(tile.dimmed ? 0.08 : 0.22).setStroke(); track.stroke()
                    let arc = NSBezierPath(); arc.lineWidth = 2 * scale; arc.lineCapStyle = .round
                    arc.appendArc(withCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: ringBounds.width / 2,
                                  startAngle: 90, endAngle: 90 - CGFloat(min(1, max(0, progress))) * 360, clockwise: true)
                    color.setStroke(); arc.stroke()
                }
                // Two extra pixels keep even square glyphs clear of either corner decoration.
                let decorated = tile.identity != nil || tile.accessory != .none
                let inset = (tile.progress == nil ? (decorated ? symbolInset + 2 : symbolInset) : 22) * scale
                drawSymbol(tile.symbol, in: bounds.insetBy(dx: inset, dy: inset), pointSize: 40 * scale, color: color)
                if let identity = tile.identity { drawIdentity(identity, in: bounds, scale: scale) }
                drawAccessory(tile.accessory, in: bounds, scale: scale)
            }
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
