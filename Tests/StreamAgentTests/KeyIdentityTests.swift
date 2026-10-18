import AppKit
import CodexBridge
import XCTest
@testable import StreamAgent

final class KeyIdentityTests: XCTestCase {
    func testPaletteIsNamedDistinctAndSafeForAnyInteger() throws {
        XCTAssertGreaterThanOrEqual(KeyIdentity.paletteCount, 4)
        XCTAssertEqual(KeyIdentity.paletteCount, KeyIdentity.palette.count)
        XCTAssertEqual(KeyIdentity.colorNames.count, KeyIdentity.paletteCount)
        XCTAssertEqual(Set(KeyIdentity.colorNames).count, KeyIdentity.paletteCount)
        var colors = Set<String>()
        for index in 0..<KeyIdentity.paletteCount {
            let identity = KeyIdentity(colorIndex: index, threadOrdinal: 1)
            XCTAssertFalse(identity.colorName.isEmpty)
            XCTAssertEqual(identity.colorName, KeyIdentity.colorNames[index])
            XCTAssertEqual(identity.name, identity.colorName)
            let color = try darkColor(identity.color)
            colors.insert("\(color.redComponent),\(color.greenComponent),\(color.blueComponent)")
        }
        XCTAssertEqual(colors.count, KeyIdentity.paletteCount)
        for index in [Int.min, -1001, -1, KeyIdentity.paletteCount, Int.max] {
            let expected = ((index % KeyIdentity.paletteCount) + KeyIdentity.paletteCount) % KeyIdentity.paletteCount
            let identity = KeyIdentity(colorIndex: index, threadOrdinal: 1)
            XCTAssertEqual(identity.colorName, KeyIdentity.colorNames[expected])
            XCTAssertEqual(try darkColor(identity.color), try darkColor(KeyIdentity.palette[expected].color))
        }
    }

    func testOneBasedOrdinalsWrapWithoutOverflow() {
        for ordinal in [Int.min, -4, -1, 0, 1, 2, 3, 4, Int.max] {
            let identity = KeyIdentity(colorIndex: Int.min, threadOrdinal: ordinal)
            XCTAssertTrue((1...3).contains(identity.threadMarkCount))
        }
        XCTAssertEqual(KeyIdentity(colorIndex: 0, threadOrdinal: 1).threadMarkCount, 1)
        XCTAssertEqual(KeyIdentity(colorIndex: 0, threadOrdinal: 2).threadMarkCount, 2)
        XCTAssertEqual(KeyIdentity(colorIndex: 0, threadOrdinal: 3).threadMarkCount, 3)
        XCTAssertEqual(KeyIdentity(colorIndex: 0, threadOrdinal: 4).threadMarkCount, 1)
        XCTAssertEqual(KeyIdentity(colorIndex: 0, threadOrdinal: 0).threadMarkCount, 3)
    }

    func testNotchGeometryMeetsTopAndRightEdgesAndRoundsOnlyInnerCorner() {
        for scale: CGFloat in [1, 2, 3] {
            let bounds = NSRect(x: 10, y: 20, width: 72 * scale, height: 72 * scale)
            let path = DeckRenderer.identityPath(in: bounds)
            XCTAssertEqual(path.bounds, NSRect(x: bounds.maxX - 18 * scale, y: bounds.maxY - 18 * scale,
                                               width: 18 * scale, height: 18 * scale))
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: bounds.maxX - x * scale, y: bounds.maxY - y * scale)
            }
            XCTAssertTrue(path.contains(point(17.5, 0.5)), "Top edge must be attached")
            XCTAssertTrue(path.contains(point(0.5, 17.5)), "Right edge must be attached")
            XCTAssertTrue(path.contains(point(0.5, 0.5)), "Outer corner must stay square")
            XCTAssertFalse(path.contains(point(17.5, 17.5)), "Inner corner must be rounded")
            XCTAssertTrue(path.contains(point(9, 17.5)))
            XCTAssertTrue(path.contains(point(17.5, 9)))
            XCTAssertFalse(path.contains(point(19, 9)))
            XCTAssertFalse(path.contains(point(9, 19)))
            // Even a square primary glyph has clearance from the rounded corner.
            XCTAssertFalse(path.contains(point(16, 16)))
        }
    }

    func testBitmapNotchIsAtTopRightFlushWithBothEdgesAndHasRoundedCutout() throws {
        let tile = agentTile(color: 0, ordinal: 1)
        for scale in [1, 2] {
            let bitmap = try render(tile, size: 72 * scale)
            XCTAssertEqual(bitmap.pixelsWide, 72 * scale)
            XCTAssertEqual(bitmap.pixelsHigh, 72 * scale)
            let expected = try darkColor(try XCTUnwrap(tile.identity).color)
            // Bitmap rows start at the top; the renderer uses bottom-left drawing coordinates.
            for (x, y) in [(71, 0), (54, 0), (71, 17)] {
                try assertColor(bitmap, x: x * scale, y: y * scale, equals: expected)
            }
            let background = try pixelColor(bitmap, x: 0, y: 0)
            try assertColor(bitmap, x: 54 * scale, y: 17 * scale, equals: background)
            try assertColor(bitmap, x: 71 * scale, y: 71 * scale, equals: background)
        }
    }

    func testEachThreadPositionHasOneTwoOrThreeDarkDotsForEveryProjectColor() throws {
        for color in 0..<KeyIdentity.paletteCount {
            for ordinal in 1...3 {
                let bitmap = try render(agentTile(color: color, ordinal: ordinal))
                var runs = 0, wasDark = false
                for x in 55..<71 {
                    let pixel = try pixelColor(bitmap, x: x, y: 5)
                    let isDark = (pixel.redComponent + pixel.greenComponent + pixel.blueComponent) / 3 < 0.15
                    if isDark && !wasDark { runs += 1 }
                    wasDark = isDark
                }
                XCTAssertEqual(runs, ordinal, "\(KeyIdentity.colorNames[color]), thread \(ordinal)")
            }
        }
    }

    func testColorAndThreadChangesOnlyAffectTopRightCornerPixels() throws {
        let original = agentTile(color: 0, ordinal: 1)
        for changed in [agentTile(color: 1, ordinal: 1), agentTile(color: 0, ordinal: 2), agentTile(color: 0, ordinal: 3)] {
            for scale in [1, 2] {
                let first = try render(original, size: 72 * scale), second = try render(changed, size: 72 * scale)
                let differences = changedPixels(first, second)
                XCTAssertFalse(differences.isEmpty)
                XCTAssertTrue(differences.allSatisfy { $0.x >= 54 * scale && $0.y < 18 * scale },
                              "Identity changes must leave the status glyph and other corners alone")
            }
        }
    }

    func testProjectMarkerStaysIdenticalAcrossAllAgentStatuses() throws {
        let identity = KeyIdentity(colorIndex: 2, threadOrdinal: 3)
        var tiles = AgentStatus.allCases.map { status in
            DeckRenderer.presentation(for: AgentSession(id: "test-thread", title: "Test", projectPath: "/fixture",
                                                        projectName: "Fixture", status: status,
                                                        updatedAt: Date(timeIntervalSince1970: 0), statusDetail: "Fixture"))
        }
        for index in tiles.indices { tiles[index].identity = identity }
        let reference = try render(try XCTUnwrap(tiles.first))
        for tile in tiles.dropFirst() {
            let bitmap = try render(tile)
            XCTAssertEqual(region(reference, x: 54..<72, y: 0..<18), region(bitmap, x: 54..<72, y: 0..<18))
            XCTAssertFalse(tile.hasSameFace(as: tiles[0]))
        }
    }

    func testIdentityAccessoriesAndDimmingInvalidateFaceButMetadataDoesNot() throws {
        let original = agentTile(color: 0, ordinal: 1)
        var metadata = original
        metadata.title = "Renamed thread"; metadata.subtitle = "Different inspector detail"
        XCTAssertNotEqual(original, metadata)
        XCTAssertTrue(original.hasSameFace(as: metadata))
        XCTAssertEqual(bytes(try render(original)), bytes(try render(metadata)))
        XCTAssertEqual(DeckDiff.changedKeys(previous: [0: original], current: [metadata]), [])
        var color = original; color.identity?.colorIndex = 1
        var ordinal = original; ordinal.identity?.threadOrdinal = 2
        var noIdentity = original; noIdentity.identity = nil
        var dimmed = original; dimmed.dimmed = true
        var changes = [color, ordinal, noIdentity, dimmed]
        changes += DeckTilePresentation.Accessory.allCases.filter { $0 != .none }.map { accessory in
            var tile = original; tile.accessory = accessory; return tile
        }
        for tile in changes {
            XCTAssertFalse(original.hasSameFace(as: tile))
            XCTAssertEqual(DeckDiff.changedKeys(previous: [0: original, 1: metadata], current: [tile, metadata]), [0])
        }
    }

    func testAccessoriesHaveDistinctLowerRightFacesAndPreservePrimaryGlyphAndIdentity() throws {
        let original = agentTile(color: 1, ordinal: 2)
        let reference = try render(original)
        var accessoryFaces = Set<Data>()
        for accessory in DeckTilePresentation.Accessory.allCases where accessory != .none {
            var tile = original; tile.accessory = accessory
            XCTAssertEqual(tile.symbol, original.symbol)
            let bitmap = try render(tile)
            let differences = changedPixels(reference, bitmap)
            XCTAssertFalse(differences.isEmpty, accessory.rawValue)
            XCTAssertTrue(differences.allSatisfy { $0.x >= 53 && $0.y >= 53 }, accessory.rawValue)
            XCTAssertEqual(region(reference, x: 54..<72, y: 0..<18), region(bitmap, x: 54..<72, y: 0..<18))
            accessoryFaces.insert(bytes(bitmap))
        }
        XCTAssertEqual(accessoryFaces.count, 6, "Each accessory needs a distinct non-color cue")
    }

    func testDimmingLeavesIdentityAndAccessoryLegibleAndChangesOnlyMainFace() throws {
        var tile = agentTile(color: 3, ordinal: 1); tile.accessory = .locked
        let original = try render(tile)
        tile.dimmed = true
        let dimmed = try render(tile)
        XCTAssertFalse(changedPixels(original, dimmed).isEmpty)
        XCTAssertEqual(region(original, x: 54..<72, y: 0..<18), region(dimmed, x: 54..<72, y: 0..<18))
        XCTAssertEqual(region(original, x: 53..<72, y: 53..<72), region(dimmed, x: 53..<72, y: 53..<72))
        let bright = try pixelColor(original, x: 36, y: 36), dark = try pixelColor(dimmed, x: 36, y: 36)
        XCTAssertLessThan(dark.redComponent + dark.greenComponent + dark.blueComponent,
                          bright.redComponent + bright.greenComponent + bright.blueComponent)
    }

    func testEmptyKeysRemainUniformWithEveryDecoration() throws {
        for pressed in [false, true] {
            var empty = DeckTilePresentation(title: "Empty", symbol: "square.fill", pressed: pressed, isEmpty: true)
            let reference = try render(empty)
            empty.identity = .init(colorIndex: Int.max, threadOrdinal: 3)
            empty.dimmed = true; empty.progress = 0.5
            for accessory in DeckTilePresentation.Accessory.allCases {
                empty.accessory = accessory
                let bitmap = try render(empty)
                XCTAssertEqual(bytes(reference), bytes(bitmap))
                XCTAssertTrue(changedPixelsFromFirstPixel(bitmap).isEmpty)
            }
        }
    }

    func testDrawingUsesDarkSemanticColorsAndRestoresCallingAppearance() throws {
        var tile = agentTile(color: 0, ordinal: 3); tile.accessory = .failure; tile.tint = .blue
        var light: NSBitmapImageRep?, dark: NSBitmapImageRep?
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAqua = try XCTUnwrap(NSAppearance(named: .darkAqua))
        aqua.performAsCurrentDrawingAppearance {
            light = DeckRenderer.image(tile).representations.first as? NSBitmapImageRep
            XCTAssertEqual(NSAppearance.currentDrawing().name, aqua.name)
        }
        darkAqua.performAsCurrentDrawingAppearance {
            dark = DeckRenderer.image(tile).representations.first as? NSBitmapImageRep
            XCTAssertEqual(NSAppearance.currentDrawing().name, darkAqua.name)
        }
        XCTAssertEqual(bytes(try XCTUnwrap(light)), bytes(try XCTUnwrap(dark)))
    }

    private func agentTile(color: Int, ordinal: Int) -> DeckTilePresentation {
        DeckTilePresentation(title: "Fixture thread", symbol: "square.fill",
                             identity: .init(colorIndex: color, threadOrdinal: ordinal))
    }

    private func render(_ tile: DeckTilePresentation, size: Int = 72) throws -> NSBitmapImageRep {
        try XCTUnwrap(DeckRenderer.image(tile, size: size).representations.first as? NSBitmapImageRep)
    }

    private func darkColor(_ color: NSColor) throws -> NSColor {
        var resolved: NSColor?
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        return try XCTUnwrap(resolved)
    }

    private func pixelColor(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    private func assertColor(_ bitmap: NSBitmapImageRep, x: Int, y: Int, equals expected: NSColor,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try pixelColor(bitmap, x: x, y: y)
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.015, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.015, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.015, file: file, line: line)
    }

    private func bytes(_ bitmap: NSBitmapImageRep) -> Data {
        Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    private func region(_ bitmap: NSBitmapImageRep, x: Range<Int>, y: Range<Int>) -> Data {
        var data = Data()
        for row in y {
            data.append(bitmap.bitmapData! + row * bitmap.bytesPerRow + x.lowerBound * 4, count: x.count * 4)
        }
        return data
    }

    private func changedPixels(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> [(x: Int, y: Int)] {
        var changed: [(x: Int, y: Int)] = []
        for y in 0..<lhs.pixelsHigh {
            for x in 0..<lhs.pixelsWide {
                let offset = y * lhs.bytesPerRow + x * 4
                if (0..<4).contains(where: { lhs.bitmapData![offset + $0] != rhs.bitmapData![offset + $0] }) {
                    changed.append((x, y))
                }
            }
        }
        return changed
    }

    private func changedPixelsFromFirstPixel(_ bitmap: NSBitmapImageRep) -> [(x: Int, y: Int)] {
        var changed: [(x: Int, y: Int)] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let offset = y * bitmap.bytesPerRow + x * 4
                if (0..<4).contains(where: { bitmap.bitmapData![offset + $0] != bitmap.bitmapData![$0] }) {
                    changed.append((x, y))
                }
            }
        }
        return changed
    }
}
