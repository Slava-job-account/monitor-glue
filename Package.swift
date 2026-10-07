// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MonitorGlue",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // In-app updates for builds distributed outside the Mac App Store.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "MonitorGlue",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/MonitorGlue",
            linkerSettings: [
                // Sparkle.framework is embedded in Contents/Frameworks by Scripts/bundle.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(name: "MonitorGlueTests", dependencies: ["MonitorGlue"])
    ]
)
