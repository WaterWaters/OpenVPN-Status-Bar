// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VPNStatusBar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "VPNStatusBarCore",
            path: "Sources/VPNStatusBarCore"
        ),
        .executableTarget(
            name: "VPNStatusBar",
            dependencies: ["VPNStatusBarCore"],
            path: "Sources/VPNStatusBar"
        ),
        .testTarget(
            name: "VPNStatusBarCoreTests",
            dependencies: ["VPNStatusBarCore"],
            path: "Tests/VPNStatusBarCoreTests"
        )
    ]
)
