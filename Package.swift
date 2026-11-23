// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Circle",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "CircleCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(
            name: "Circle",
            dependencies: ["CircleCore", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework is copied into Circle.app/Contents/Frameworks by build.command.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "circle-mcp", dependencies: ["CircleCore"]),
    ]
)
