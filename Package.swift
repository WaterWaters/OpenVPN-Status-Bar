// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VPNStatusBar",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "VPNStatusBarCore",
            path: "Sources/VPNStatusBarCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "VPNStatusBar",
            dependencies: ["VPNStatusBarCore"],
            path: "Sources/VPNStatusBar",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "VPNStatusBarCoreTests",
            dependencies: ["VPNStatusBarCore"],
            path: "Tests/VPNStatusBarCoreTests"
        )
    ]
)
