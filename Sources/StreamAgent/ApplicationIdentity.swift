import Foundation

enum ApplicationIdentity {
    static func bundleID(for value: String) -> String? {
        guard value.hasPrefix("/") else { return value.isEmpty ? nil : value }
        return Bundle(url: URL(fileURLWithPath: value))?.bundleIdentifier
    }
}
