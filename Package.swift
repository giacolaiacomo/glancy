// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Glancy",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Glancy", targets: ["Glancy"]),
    ],
    targets: [
        .target(
            name: "GlancyKit",
            path: "Sources/GlancyKit",
            exclude: ["Tiling/NOTICE.md"],
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        ),
        .executableTarget(name: "Glancy", dependencies: ["GlancyKit"], path: "Sources/Glancy"),
        // Renders every surface state to PNG off-screen, with real data, for review.
        .executableTarget(name: "glancy-render", dependencies: ["GlancyKit"], path: "Sources/glancy-render"),
        // Deletes the per-test preference files when the test process exits.
        .target(name: "TestPrefsSweeper", path: "Tests/TestPrefsSweeper"),
        .testTarget(name: "GlancyKitTests", dependencies: ["GlancyKit", "TestPrefsSweeper"], path: "Tests/GlancyKitTests"),
    ]
)
