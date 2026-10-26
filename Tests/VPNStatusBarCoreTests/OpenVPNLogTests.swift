import XCTest
@testable import VPNStatusBarCore

final class OpenVPNLogTests: XCTestCase {
    /// 真实日志形态：认证失败时 openvpn 会带 AUTH_FAILED 退出
    func testDetectsAuthFailure() {
        let log = """
        Tue Oct 10 11:00:01 2026 TCP/UDP: Preserving recently used remote address
        Tue Oct 10 11:00:02 2026 AUTH: Received control message: AUTH_FAILED
        Tue Oct 10 11:00:02 2026 SIGTERM[hard,] received, process exiting
        """
        XCTAssertTrue(OpenVPNLog.indicatesAuthFailure(in: log))
    }

    /// 服务端带原因的回执
    func testDetectsAuthFailureWithReason() {
        let log = "AUTH: Received control message: AUTH_FAILED,Your credentials are incorrect"
        XCTAssertTrue(OpenVPNLog.indicatesAuthFailure(in: log))
    }

    /// management 状态机上报的 auth-failure
    func testDetectsStateAuthFailure() {
        XCTAssertTrue(OpenVPNLog.indicatesAuthFailure(in: "1791602229,DISCONNECTED,auth-failure,,,,"))
    }

    /// 普通断开（ping-restart / 远端踢人）不应被当成凭据错误
    func testPlainDisconnectIsNotAuthFailure() {
        let log = """
        Tue Oct 10 11:00:01 2026 [server] Inactivity timeout (--ping-restart), restarting
        Tue Oct 10 11:00:01 2026 SIGUSR1[soft,ping-restart] received, process restarting
        """
        XCTAssertFalse(OpenVPNLog.indicatesAuthFailure(in: log))
    }

    func testEmptyLogIsNotAuthFailure() {
        XCTAssertFalse(OpenVPNLog.indicatesAuthFailure(in: ""))
        XCTAssertFalse(OpenVPNLog.indicatesAuthFailure(in: "（暂无日志）"))
    }
}

/// 日志改为追加模式后：会话分隔行的生成与「只看本次会话」的切片
final class OpenVPNLogSessionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_602_229)

    func testSessionNoteCarriesMetadata() {
        let note = OpenVPNLog.sessionNote(date: start, attempt: 3, profile: "ZTopenvpn")
        XCTAssertTrue(note.hasPrefix(OpenVPNLog.sessionMarker))
        XCTAssertTrue(note.contains("attempt=3"))
        XCTAssertTrue(note.contains("profile=ZTopenvpn"))
        XCTAssertFalse(note.contains("\n"), "分隔行必须是单行")
    }

    func testCurrentSessionTakesLastSegment() {
        let log = """
        \(OpenVPNLog.sessionNote(date: start, attempt: 1, profile: "A"))
        old session line
        \(OpenVPNLog.sessionNote(date: start.addingTimeInterval(60), attempt: 2, profile: "A"))
        new session line
        """
        let current = OpenVPNLog.currentSession(in: log)
        XCTAssertTrue(current.contains("new session line"))
        XCTAssertFalse(current.contains("old session line"))
    }

    /// 没有分隔行（老日志 / 手工脚本写的日志）→ 返回全文，行为与改造前一致
    func testCurrentSessionFallsBackToWholeLog() {
        let legacy = "Tue Oct 10 11:00:01 2026 TCP/UDP: Preserving recently used remote address"
        XCTAssertEqual(OpenVPNLog.currentSession(in: legacy), legacy)
    }

    func testCurrentSessionToleratesCRLF() {
        let log = "\(OpenVPNLog.sessionNote(date: start, attempt: 1, profile: "A"))\r\nold\r\n"
            + "\(OpenVPNLog.sessionNote(date: start, attempt: 2, profile: "A"))\r\nnew\r\n"
        let current = OpenVPNLog.currentSession(in: log)
        XCTAssertTrue(current.contains("new"))
        XCTAssertFalse(current.contains("old"))
    }

    /// 核心回归：上一轮凭据错误停过重连，这一轮正常启动——不能被历史字样再次触发“停止重连”
    func testPreviousSessionAuthFailureDoesNotLeakIntoCurrentSession() {
        let log = """
        \(OpenVPNLog.sessionNote(date: start, attempt: 1, profile: "A"))
        AUTH: Received control message: AUTH_FAILED
        SIGTERM[hard,] received, process exiting
        \(OpenVPNLog.sessionNote(date: start.addingTimeInterval(120), attempt: 1, profile: "A"))
        TCP/UDP: Preserving recently used remote address
        Peer Connection Initiated
        """
        XCTAssertTrue(OpenVPNLog.indicatesAuthFailure(in: log), "整份日志里确实有历史凭据错误")
        XCTAssertFalse(
            OpenVPNLog.indicatesAuthFailure(in: OpenVPNLog.currentSession(in: log)),
            "只看本次会话时不应误判"
        )
    }

    /// 反例：本次会话自己报的凭据错误仍要能检出
    func testCurrentSessionAuthFailureIsDetected() {
        let log = """
        \(OpenVPNLog.sessionNote(date: start, attempt: 1, profile: "A"))
        Peer Connection Initiated
        \(OpenVPNLog.sessionNote(date: start.addingTimeInterval(120), attempt: 2, profile: "A"))
        AUTH: Received control message: AUTH_FAILED
        """
        XCTAssertTrue(OpenVPNLog.indicatesAuthFailure(in: OpenVPNLog.currentSession(in: log)))
    }
}

/// 只读文件末尾窗口时的会话切片（app 侧不再整读 512 KB 日志）
final class OpenVPNLogTailTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_602_229)

    func testTailWithMarkerReturnsCurrentSession() {
        let tail = """
        \(OpenVPNLog.sessionNote(date: start, attempt: 1, profile: "A"))
        old session line
        \(OpenVPNLog.sessionNote(date: start.addingTimeInterval(60), attempt: 2, profile: "A"))
        new session line
        """
        let current = OpenVPNLog.currentSessionFromTail(tail, tailIsWholeFile: false)
        XCTAssertNotNil(current)
        XCTAssertTrue(current?.contains("new session line") ?? false)
        XCTAssertFalse(current?.contains("old session line") ?? true)
    }

    /// 窗口内没有分隔行、但窗口就是整个文件（老日志 / 手工脚本产物）→ 与 currentSession 一样返回全文
    func testTailIsWholeFileWithoutMarkerReturnsWholeText() {
        let legacy = "Tue Oct 10 11:00:01 2026 TCP/UDP: Preserving recently used remote address"
        XCTAssertEqual(OpenVPNLog.currentSessionFromTail(legacy, tailIsWholeFile: true), legacy)
    }

    /// 窗口内没有分隔行、文件更长（本次会话比窗口还长）→ nil，调用方必须改用整文件读，
    /// 否则会把上一轮的 AUTH_FAILED 误当本轮（这是追加日志模式下的核心回归）
    func testTruncatedTailWithoutMarkerReturnsNil() {
        let tail = """
        AUTH: Received control message: AUTH_FAILED
        SIGTERM[hard,] received, process exiting
        TCP/UDP: Preserving recently used remote address
        """
        XCTAssertNil(OpenVPNLog.currentSessionFromTail(tail, tailIsWholeFile: false))
    }

    /// 分隔行正好落在窗口开头（边界）→ 仍要能切出来
    func testMarkerAtWindowStartIsFound() {
        let tail = "\(OpenVPNLog.sessionNote(date: start, attempt: 1, profile: "A"))\nPeer Connection Initiated\n"
        let current = OpenVPNLog.currentSessionFromTail(tail, tailIsWholeFile: false)
        XCTAssertTrue(current?.contains("Peer Connection Initiated") ?? false)
    }
}
