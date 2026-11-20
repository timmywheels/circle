// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Circle",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CircleCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "Circle", dependencies: ["CircleCore"]),
        .executableTarget(name: "circle-mcp", dependencies: ["CircleCore"]),
    ]
)
