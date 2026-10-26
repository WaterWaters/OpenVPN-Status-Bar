import XCTest
@testable import VPNStatusBarCore

final class VPNStatusTests: XCTestCase {
    func testTitle() {
        // 单语言：简体中文（文案表在 L10nCore 内）
        XCTAssertEqual(VPNStatus.unconfigured.title, "未配置")
        XCTAssertEqual(VPNStatus.disconnected.title, "已断开")
        XCTAssertEqual(VPNStatus.connecting.title, "连接中…")
        XCTAssertEqual(VPNStatus.connected.title, "已连接")
        XCTAssertEqual(VPNStatus.reconnecting(attempt: 3).title, "重连中（第 3 次）")
    }

    func testSymbolName() {
        XCTAssertEqual(VPNStatus.connected.symbolName, "shield.fill")
        XCTAssertEqual(VPNStatus.reconnecting(attempt: 1).symbolName, "shield")
        XCTAssertEqual(VPNStatus.disconnected.symbolName, "shield.slash.fill")
        XCTAssertEqual(VPNStatus.unconfigured.symbolName, "shield.slash")
    }

    func testIsConnectedAndBusy() {
        XCTAssertTrue(VPNStatus.connected.isConnected)
        XCTAssertFalse(VPNStatus.disconnected.isConnected)

        XCTAssertTrue(VPNStatus.connecting.isBusy)
        XCTAssertTrue(VPNStatus.reconnecting(attempt: 2).isBusy)
        XCTAssertFalse(VPNStatus.connected.isBusy)
        XCTAssertFalse(VPNStatus.disconnected.isBusy)
    }

    /// 秒级时钟只在"有时长/倒计时可显示"的状态下需要：其余状态开着面板也不该有 1 Hz 唤醒
    func testNeedsClock() {
        XCTAssertTrue(VPNStatus.connected.needsClock)
        XCTAssertTrue(VPNStatus.reconnecting(attempt: 1).needsClock)
        XCTAssertFalse(VPNStatus.connecting.needsClock)
        XCTAssertFalse(VPNStatus.disconnected.needsClock)
        XCTAssertFalse(VPNStatus.unconfigured.needsClock)
    }

    func testIsReconnecting() {
        XCTAssertTrue(VPNStatus.reconnecting(attempt: 1).isReconnecting)
        XCTAssertFalse(VPNStatus.connecting.isReconnecting)
        XCTAssertFalse(VPNStatus.connected.isReconnecting)
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
