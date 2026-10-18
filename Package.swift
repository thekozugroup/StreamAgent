// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StreamAgent",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "StreamAgent", targets: ["StreamAgent"]),
        .executable(name: "StreamDeckProbe", targets: ["StreamDeckProbe"]),
        .executable(name: "CodexProbe", targets: ["CodexProbe"]),
        .library(name: "StreamDeckKit", targets: ["StreamDeckKit"]),
        .library(name: "CodexBridge", targets: ["CodexBridge"])
    ],
    targets: [
        .target(name: "StreamDeckKit", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("AppKit")]),
        .target(name: "CodexBridge", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "StreamAgent", dependencies: ["StreamDeckKit", "CodexBridge"]),
        .executableTarget(name: "StreamDeckProbe", dependencies: ["StreamDeckKit"]),
        .executableTarget(name: "CodexProbe", dependencies: ["CodexBridge"]),
        .testTarget(name: "StreamDeckKitTests", dependencies: ["StreamDeckKit"]),
        .testTarget(name: "CodexBridgeTests", dependencies: ["CodexBridge"]),
        .testTarget(name: "StreamAgentTests", dependencies: ["StreamAgent"])
    ],
    swiftLanguageModes: [.v5]
)
