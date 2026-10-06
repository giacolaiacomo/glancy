// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Glancy",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Glancy", targets: ["Glancy"]),
    ],
    dependencies: [
        // In-app updates (Sources/GlancyKit/Updates). Embedded in Contents/Frameworks by build-app.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "GlancyKit",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/GlancyKit",
            exclude: ["Tiling/NOTICE.md"],
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        ),
        .executableTarget(
            name: "Glancy", dependencies: ["GlancyKit"], path: "Sources/Glancy",
            // Sparkle.framework lives in Glancy.app/Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // Renders every surface state to PNG off-screen, with real data, for review.
        .executableTarget(name: "glancy-render", dependencies: ["GlancyKit"], path: "Sources/glancy-render"),
        // Deletes the per-test preference files when the test process exits.
        .target(name: "TestPrefsSweeper", path: "Tests/TestPrefsSweeper"),
        .testTarget(name: "GlancyKitTests", dependencies: ["GlancyKit", "TestPrefsSweeper"], path: "Tests/GlancyKitTests"),
    ]
)
