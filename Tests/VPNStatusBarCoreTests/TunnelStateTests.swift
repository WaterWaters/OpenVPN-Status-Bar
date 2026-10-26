import XCTest
@testable import VPNStatusBarCore

final class TunnelStateTests: XCTestCase {
    private let banner = ">INFO:OpenVPN Management Interface Version 5 -- type 'help' for more info\n"

    func testConnected() {
        let resp = banner + "1791602229,CONNECTED,SUCCESS,10.8.0.24,183.222.16.242,7777,,\nEND\n"
        XCTAssertEqual(OpenVPNMgmt.parseState(resp), .connected)
        XCTAssertTrue(OpenVPNMgmt.parseState(resp).isConnected)
    }

    /// management 接口实际按 CRLF 换行；"\r\n" 在 Swift 里是单个 Character，
    /// 用 split(separator: "\n") 会切不开，这里锁住真实字节形态
    func testCRLFResponse() {
        let resp = ">INFO:OpenVPN Management Interface Version 5 -- type 'help' for more info\r\n"
            + "1791602229,CONNECTED,SUCCESS,10.8.0.24,183.222.16.242,7777,,\r\n"
            + "END\r\n"
        XCTAssertEqual(OpenVPNMgmt.parseState(resp), .connected)

        let connecting = ">INFO:banner\r\n1791602229,CONNECTING,AUTH,,,,\r\nEND\r\n"
        XCTAssertEqual(OpenVPNMgmt.parseState(connecting), .connecting)

        // 只有 CR（老式 Mac 换行）也要能切
        XCTAssertEqual(OpenVPNMgmt.parseState("1,CONNECTED,SUCCESS,,,,\rEND\r"), .connected)
    }

    func testConnectingStages() {
        // 连接过程中会出现多个中间状态，都应判为“未连接”
        for stage in ["CONNECTING", "WAIT", "AUTH", "GET_CONFIG", "ASSIGN_IP", "ADD_ROUTES"] {
            let resp = banner + "1791602229,\(stage),AUTH,,,,\nEND\n"
            XCTAssertEqual(OpenVPNMgmt.parseState(resp), .connecting, "stage \(stage)")
            XCTAssertFalse(OpenVPNMgmt.parseState(resp).isConnected)
        }
    }

    func testReconnectingAndDisconnected() {
        XCTAssertEqual(OpenVPNMgmt.parseState("1,RECONNECTING,ping-restart,,,,\nEND\n"), .reconnecting)
        XCTAssertEqual(OpenVPNMgmt.parseState("1,DISCONNECTED,auth-failure,,,,\nEND\n"), .disconnected)
        XCTAssertEqual(OpenVPNMgmt.parseState("1,EXITING,sigterm,,,,\nEND\n"), .disconnected)
    }

    func testTakesLastRecognisableLine() {
        let resp = "1,CONNECTING,WAIT,,,,\n2,CONNECTED,SUCCESS,10.8.0.24,,,,\nEND\n"
        XCTAssertEqual(OpenVPNMgmt.parseState(resp), .connected)
    }

    func testUnknownAndJunk() {
        XCTAssertEqual(OpenVPNMgmt.parseState(""), .unknown)
        XCTAssertEqual(OpenVPNMgmt.parseState(banner + "END\n"), .unknown)
        XCTAssertEqual(OpenVPNMgmt.parseState("SUCCESS: signal SIGTERM thrown\n"), .unknown)
        XCTAssertEqual(OpenVPNMgmt.parseState("not,a,state,line\nEND\n"), .unknown)
        XCTAssertEqual(OpenVPNMgmt.parseState("1,FUTURE_STATE,x,,,,\nEND\n"), .unknown)
    }

    func testStateNameIsCaseAndSpaceTolerant() {
        XCTAssertEqual(OpenVPNMgmt.parseState("1, connected ,SUCCESS,,,,\nEND\n"), .connected)
    }
}

/// 面板要显示真实的本端地址 / 对端地址（此前是硬编码的 10.8.0.0/16）
final class TunnelInfoTests: XCTestCase {
    func testConnectedCarriesAddresses() {
        let resp = "1791602229,CONNECTED,SUCCESS,10.8.0.24,183.222.16.242,7777,,\nEND\n"
        let info = OpenVPNMgmt.parseInfo(resp)
        XCTAssertEqual(info.state, .connected)
        XCTAssertEqual(info.localAddress, "10.8.0.24")
        XCTAssertEqual(info.remote, "183.222.16.242:7777")
    }

    /// 中间状态没有地址字段 → 保持 nil，不能显示成空串或占位
    func testConnectingHasNoAddresses() {
        let info = OpenVPNMgmt.parseInfo("1,WAIT,AUTH,,,,\nEND\n")
        XCTAssertEqual(info.state, .connecting)
        XCTAssertNil(info.localAddress)
        XCTAssertNil(info.remote)
    }

    /// 字段不足（老版本或裁剪过的回执）不能崩、也不能造数据
    func testShortLineIsTolerated() {
        let info = OpenVPNMgmt.parseInfo("1,CONNECTED\nEND\n")
        XCTAssertEqual(info.state, .connected)
        XCTAssertNil(info.localAddress)
        XCTAssertNil(info.remote)
    }

    /// 只有 host 没有 port 时不要拼出 "host:"
    func testRemoteWithoutPort() {
        let info = OpenVPNMgmt.parseInfo("1,CONNECTED,SUCCESS,10.8.0.24,vpn.example.com,,\nEND\n")
        XCTAssertEqual(info.remote, "vpn.example.com")
    }

    func testUnknownStateHasNoInfo() {
        let info = OpenVPNMgmt.parseInfo(">INFO:banner\nEND\n")
        XCTAssertEqual(info.state, .unknown)
        XCTAssertNil(info.localAddress)
        XCTAssertNil(info.remote)
    }
}
