import XCTest
@testable import VPNStatusBarCore

final class VPNStatusTests: XCTestCase {
    func testTitle() {
        XCTAssertEqual(VPNStatus.unconfigured.title, "未配置")
        XCTAssertEqual(VPNStatus.disconnected.title, "已断开")
        XCTAssertEqual(VPNStatus.connecting.title, "连接中…")
        XCTAssertEqual(VPNStatus.connected.title, "已连接")
        XCTAssertEqual(VPNStatus.reconnecting(attempt: 3).title, "重连中（第 3 次）")
    }

    func testSymbolName() {
        XCTAssertEqual(VPNStatus.connected.symbolName, "network.badge.shield.half.filled")
        XCTAssertEqual(VPNStatus.reconnecting(attempt: 1).symbolName, "network")
        XCTAssertEqual(VPNStatus.disconnected.symbolName, "network.slash")
        XCTAssertEqual(VPNStatus.unconfigured.symbolName, "network.slash")
    }

    func testIsConnectedAndBusy() {
        XCTAssertTrue(VPNStatus.connected.isConnected)
        XCTAssertFalse(VPNStatus.disconnected.isConnected)

        XCTAssertTrue(VPNStatus.connecting.isBusy)
        XCTAssertTrue(VPNStatus.reconnecting(attempt: 2).isBusy)
        XCTAssertFalse(VPNStatus.connected.isBusy)
        XCTAssertFalse(VPNStatus.disconnected.isBusy)
    }
}

final class EngineAuthTests: XCTestCase {
    func testSummary() {
        XCTAssertEqual(EngineAuth.checking.summary, "VPN 引擎检测中…")
        XCTAssertEqual(EngineAuth.authorized.summary, "VPN 引擎已授权")
        XCTAssertEqual(EngineAuth.unauthorized.summary, "VPN 引擎未授权（需要授权 VPN）")
        XCTAssertEqual(EngineAuth.broken.summary, "VPN 引擎异常（需要修复）")
        XCTAssertEqual(EngineAuth.authorizing.summary, "VPN 引擎授权中…")
    }
}
