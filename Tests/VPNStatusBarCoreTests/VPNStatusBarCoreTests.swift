import XCTest
@testable import VPNStatusBarCore

final class VPNStatusTests: XCTestCase {
    func testTitle() {
        // defaultLocalization = en
        XCTAssertEqual(VPNStatus.unconfigured.title, "Not Configured")
        XCTAssertEqual(VPNStatus.disconnected.title, "Disconnected")
        XCTAssertEqual(VPNStatus.connecting.title, "Connecting...")
        XCTAssertEqual(VPNStatus.connected.title, "Connected")
        XCTAssertEqual(VPNStatus.reconnecting(attempt: 3).title, "Reconnecting (3)")
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
}

final class EngineAuthTests: XCTestCase {
    func testSummary() {
        XCTAssertEqual(EngineAuth.checking.summary, "Checking VPN engine...")
        XCTAssertEqual(EngineAuth.authorized.summary, "VPN engine authorized")
        XCTAssertEqual(EngineAuth.unauthorized.summary, "VPN engine not authorized")
        XCTAssertEqual(EngineAuth.broken.summary, "VPN engine error")
        XCTAssertEqual(EngineAuth.authorizing.summary, "Authorizing VPN engine...")
    }
}
