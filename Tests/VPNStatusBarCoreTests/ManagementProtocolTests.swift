import XCTest
@testable import VPNStatusBarCore

/// 样例全部是真机抓到的报文原文（`openvpn --dev null --management …` + nc 交互）。
final class ManagementProtocolTests: XCTestCase {
    private let banner = ">INFO:OpenVPN Management Interface Version 5 -- type 'help' for more info"

    func testClassifiesBannerAndHoldAndReplies() {
        XCTAssertEqual(ManagementProtocol.classify(banner), .banner("OpenVPN Management Interface Version 5 -- type 'help' for more info"))
        XCTAssertEqual(ManagementProtocol.classify(">HOLD:Waiting for hold release:0"), .hold("Waiting for hold release:0"))
        XCTAssertEqual(ManagementProtocol.classify("SUCCESS: real-time state notification set to ON"), .reply(.success("real-time state notification set to ON")))
        XCTAssertEqual(ManagementProtocol.classify("SUCCESS: bytecount interval changed"), .reply(.success("bytecount interval changed")))
        XCTAssertEqual(ManagementProtocol.classify("SUCCESS: signal SIGTERM thrown"), .reply(.success("signal SIGTERM thrown")))
        XCTAssertEqual(ManagementProtocol.classify("ERROR: unknown command"), .reply(.error("unknown command")))
        XCTAssertEqual(ManagementProtocol.classify("END"), .reply(.end))
        XCTAssertEqual(ManagementProtocol.classify("ENTER PASSWORD:"), .passwordPrompt)
    }

    /// 一次性 state 响应行（带 `\n` 的真实形态）
    func testClassifiesOneShotStateLine() {
        let event = ManagementProtocol.classify("1791612939,CONNECTING,,,,,,\n")
        guard case .state(let info) = event else { return XCTFail("应为 state，实为 \(event)") }
        XCTAssertEqual(info.state, .connecting)
        XCTAssertNil(info.localAddress)
    }

    /// `>STATE:` 推送与一次性响应行是同一份 CSV，字段序一致
    func testClassifiesPushedStateWithAddresses() {
        let event = ManagementProtocol.classify(">STATE:1791612939,CONNECTED,SUCCESS,10.8.0.24,183.222.16.242,7777,,\r\n")
        guard case .state(let info) = event else { return XCTFail("应为 state，实为 \(event)") }
        XCTAssertEqual(info.state, .connected)
        XCTAssertEqual(info.localAddress, "10.8.0.24")
        XCTAssertEqual(info.remote, "183.222.16.242:7777")
    }

    func testClassifiesBytecount() {
        XCTAssertEqual(ManagementProtocol.classify(">BYTECOUNT:12345,6789"), .bytecount(rx: 12345, tx: 6789))
        XCTAssertEqual(ManagementProtocol.classify(">BYTECOUNT:0,0"), .bytecount(rx: 0, tx: 0))
    }

    /// 计数异常（负数/非数字/缺字段）不崩、不猜，归为 unknown
    func testMalformedBytecountIsUnknown() {
        XCTAssertEqual(ManagementProtocol.classify(">BYTECOUNT:-1,20"), .unknown(">BYTECOUNT:-1,20"))
        XCTAssertEqual(ManagementProtocol.classify(">BYTECOUNT:abc,def"), .unknown(">BYTECOUNT:abc,def"))
        XCTAssertEqual(ManagementProtocol.classify(">BYTECOUNT:123"), .unknown(">BYTECOUNT:123"))
    }

    /// `log on` 推送的日志行：`<时间戳>,<标记>,<文本>`，注意它没有 `>LOG:` 前缀，
    /// 且文本里可能含逗号（命令回显就有）
    func testClassifiesPushedLogLine() {
        XCTAssertEqual(
            ManagementProtocol.classify("1791612950,D,MANAGEMENT: CMD 'state on'"),
            .log("MANAGEMENT: CMD 'state on'")
        )
        XCTAssertEqual(
            ManagementProtocol.classify("1791612951,I,TLS: Initial packet from [AF_INET]1.2.3.4:1194, sid=abc"),
            .log("TLS: Initial packet from [AF_INET]1.2.3.4:1194, sid=abc")
        )
    }

    func testUnknownAndEmptyLines() {
        XCTAssertEqual(ManagementProtocol.classify(""), .unknown(""))
        XCTAssertEqual(ManagementProtocol.classify("   \r\n"), .unknown(""))
        XCTAssertEqual(ManagementProtocol.classify("nonsense"), .unknown("nonsense"))
        XCTAssertEqual(ManagementProtocol.classify("1,FUTURE_STATE,x,,,,"), .unknown("1,FUTURE_STATE,x,,,,"))
    }

    func testCommandBuilders() {
        XCTAssertEqual(ManagementProtocol.stateOnCommand, "state on\n")
        XCTAssertEqual(ManagementProtocol.terminateCommand, "signal SIGTERM\n")
        XCTAssertEqual(ManagementProtocol.bytecountCommand(interval: 5), "bytecount 5\n")
        XCTAssertEqual(ManagementProtocol.bytecountCommand(interval: 0), "bytecount 0\n")
        XCTAssertEqual(ManagementProtocol.bytecountCommand(interval: -3), "bytecount 0\n")
        // 接口密码：实测必须发裸密码行（带 PASSWORD: 前缀会被判为错误密码）
        XCTAssertEqual(ManagementProtocol.interfacePasswordCommand("s3cret"), "s3cret\n")
        XCTAssertEqual(ManagementProtocol.port, 7505)
    }
}

final class TrafficCalculatorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_791_600_000)

    func testRatesFromTwoSamples() {
        let first = TrafficSample(bytesIn: 1_000, bytesOut: 500, at: t0)
        let second = TrafficSample(bytesIn: 3_000, bytesOut: 1_500, at: t0.addingTimeInterval(2))
        let rate = TrafficCalculator.rate(from: first, to: second)
        XCTAssertEqual(rate?.bytesInPerSecond ?? 0, 1_000, accuracy: 0.01)
        XCTAssertEqual(rate?.bytesOutPerSecond ?? 0, 500, accuracy: 0.01)
        XCTAssertEqual(rate?.totalIn, 3_000)
        XCTAssertEqual(rate?.totalOut, 1_500)
    }

    /// 采样间隔太短 → 不出速率（避免抖动）
    func testTooShortIntervalYieldsNoRate() {
        let first = TrafficSample(bytesIn: 0, bytesOut: 0, at: t0)
        let second = TrafficSample(bytesIn: 100, bytesOut: 100, at: t0.addingTimeInterval(0.2))
        XCTAssertNil(TrafficCalculator.rate(from: first, to: second))
    }

    /// 重连后计数器归零 → 不出速率（不显示负值/假峰值）
    func testCounterResetYieldsNoRate() {
        let first = TrafficSample(bytesIn: 10_000, bytesOut: 10_000, at: t0)
        let second = TrafficSample(bytesIn: 100, bytesOut: 100, at: t0.addingTimeInterval(2))
        XCTAssertNil(TrafficCalculator.rate(from: first, to: second))
    }

    func testByteFormatting() {
        XCTAssertEqual(ByteFormat.perSecond(0), "0 B/s")
        XCTAssertEqual(ByteFormat.perSecond(512), "512 B/s")
        XCTAssertEqual(ByteFormat.perSecond(2048), "2.0 KB/s")
        XCTAssertEqual(ByteFormat.perSecond(1_258_291), "1.2 MB/s")
        XCTAssertEqual(ByteFormat.perSecond(2_147_483_648), "2.0 GB/s")
        XCTAssertEqual(ByteFormat.perSecond(-5), "0 B/s")
        XCTAssertEqual(ByteFormat.size(0), "0 B")
        XCTAssertEqual(ByteFormat.size(24_300_000), "23.2 MB")
        XCTAssertEqual(ByteFormat.size(1_932_735_283), "1.8 GB")
    }
}
