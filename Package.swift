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
            path: "Sources/VPNStatusBarCore",
            // 严格并发当护栏（Swift 5 模式下是警告）：**只加在 Core**。
            // Core 是纯逻辑层，必须保持并发干净；app 目标与 AppKit/SwiftUI 互操作会产生上百条
            // 无法短期清零的噪声（捕获 non-Sendable 的 self 等），护栏作用为负，故不加 ——
            // app 层的线程纪律写在 VPNManager 顶部的注释里，迁移 Swift 6 时再统一处理。
            swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]
        ),
        .executableTarget(
            name: "VPNStatusBar",
            dependencies: ["VPNStatusBarCore"],
            path: "Sources/VPNStatusBar"
        ),
        .testTarget(
            name: "VPNStatusBarCoreTests",
            dependencies: ["VPNStatusBarCore"],
            path: "Tests/VPNStatusBarCoreTests",
            swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]
        )
    ]
)
