import AppKit

/// Project color and stable, one-based thread position. Persistence belongs to the board.
struct KeyIdentity: Equatable {
    var colorIndex: Int
    var threadOrdinal: Int

    struct PaletteEntry {
        let name: String
        let color: NSColor
    }

    // Keep this order stable: configuration stores palette indices.
    static let palette: [PaletteEntry] = [
        .init(name: "Blue", color: .systemBlue),
        .init(name: "Teal", color: .systemTeal),
        .init(name: "Purple", color: .systemPurple),
        .init(name: "Orange", color: .systemOrange),
        .init(name: "Green", color: .systemGreen),
        .init(name: "Pink", color: .systemPink),
        .init(name: "Yellow", color: .systemYellow),
        .init(name: "Indigo", color: .systemIndigo)
    ]
    static var paletteCount: Int { palette.count }
    static var colorNames: [String] { palette.map(\.name) }

    private var paletteIndex: Int {
        let remainder = colorIndex % Self.paletteCount
        return remainder < 0 ? remainder + Self.paletteCount : remainder
    }

    var color: NSColor { Self.palette[paletteIndex].color }
    var colorName: String { Self.palette[paletteIndex].name }
    var name: String { colorName }

    /// Wrap without subtracting from a possibly minimal Int.
    var threadMarkCount: Int {
        let remainder = threadOrdinal % 3
        return remainder > 0 ? remainder : remainder + 3
    }
}
