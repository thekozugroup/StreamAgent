import Foundation

enum ProjectColors {
    // Assign once, then keep the assignment even when a project disappears or moves.
    // Least-used colors spread new projects across the native semantic palette.
    static func assigning(_ projectIDs: [String], to existing: [String: Int] = [:]) -> [String: Int] {
        var result = existing
        var counts = Array(repeating: 0, count: KeyIdentity.paletteCount)
        for color in result.values where counts.indices.contains(color) { counts[color] += 1 }
        for id in projectIDs where result[id] == nil && result.count < 10_000 {
            let minimum = counts.min() ?? 0
            let color = counts.firstIndex(of: minimum) ?? 0
            result[id] = color; counts[color] += 1
        }
        return result
    }
}
