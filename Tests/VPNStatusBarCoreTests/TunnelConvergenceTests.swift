import XCTest
@testable import VPNStatusBarCore

/// 收敛兜底：busy 状态必须至少有一个在飞的动作（进程 / 启动序列 / 已武装的重试）
final class TunnelConvergenceTests: XCTestCase {
    /// 真机复现的死状态：一直"重连中"、没有 openvpn 进程、也没有重试在跑（菜单栏图标一直呼吸 + 9% CPU）
    func testStuckReconnectingWithoutArmedTimerIsRepaired() {
        let input = TunnelConvergenceInput(
            status: .reconnecting(attempt: 3),
            desired: true,
            hasProcess: false,
            isWaitingRetry: true,      // 标记卡住
            retryArmed: false          // 但计时器并没有武装
        )
        XCTAssertEqual(TunnelConvergence.verdict(input), .scheduleRetry)
    }

    /// 卡在"连接中"且什么都没在跑（prepareAndStart 早退留下的状态）→ 也要能收敛
    func testStuckConnectingWithoutProcessIsRepaired() {
        let input = TunnelConvergenceInput(status: .connecting, desired: true, hasProcess: false)
        XCTAssertEqual(TunnelConvergence.verdict(input), .scheduleRetry)
    }

    /// 正常等待重连：重试确实已武装 → 不能重复调度
    func testArmedRetryIsLeftAlone() {
        let input = TunnelConvergenceInput(
            status: .reconnecting(attempt: 2),
            desired: true,
            hasProcess: false,
            isWaitingRetry: true,
            retryArmed: true
        )
        XCTAssertEqual(TunnelConvergence.verdict(input), .none)
    }

    /// 启动序列正在跑（宽限期内）→ 别打断
    func testStartingWithinGraceIsLeftAlone() {
        let input = TunnelConvergenceInput(
            status: .connecting,
            desired: true,
            hasProcess: false,
            isStarting: true,
            secondsSinceStart: 2
        )
        XCTAssertEqual(TunnelConvergence.verdict(input), .none)
    }

    /// 启动序列卡死（超过宽限期还没有进程、也没有重试）→ 收敛
    func testStaleStartSequenceIsRepaired() {
        let input = TunnelConvergenceInput(
            status: .connecting,
            desired: true,
            hasProcess: false,
            isStarting: true,
            secondsSinceStart: TunnelConvergence.startGrace + 1
        )
        XCTAssertEqual(TunnelConvergence.verdict(input), .scheduleRetry)
    }

    /// 有进程在跑（busy 期间 openvpn 自己会重连）→ 不动
    func testBusyWithLiveProcessIsLeftAlone() {
        let input = TunnelConvergenceInput(status: .reconnecting(attempt: 1), desired: true, hasProcess: true)
        XCTAssertEqual(TunnelConvergence.verdict(input), .none)
    }

    /// 用户已经不期望连接，却还停在连接类状态上 → 收敛到已断开（旧 refreshState 的 !desired 分支）
    func testConnectedWithoutIntentConvergesToDisconnected() {
        let input = TunnelConvergenceInput(status: .connected, desired: false, hasProcess: true)
        XCTAssertEqual(TunnelConvergence.verdict(input), .forceDisconnected)
    }

    func testBusyWithoutIntentConvergesToDisconnected() {
        let input = TunnelConvergenceInput(status: .connecting, desired: false, hasProcess: false)
        XCTAssertEqual(TunnelConvergence.verdict(input), .forceDisconnected)
    }

    /// 自动重连关掉 / 引擎不可用：补重试没有意义，回到已断开（与 handleProcessExit 的既有语义一致）
    func testStuckStateWithoutRetryPreconditionsDisconnects() {
        XCTAssertEqual(
            TunnelConvergence.verdict(TunnelConvergenceInput(
                status: .reconnecting(attempt: 4), desired: true, hasProcess: false, autoReconnect: false)),
            .forceDisconnected
        )
        XCTAssertEqual(
            TunnelConvergence.verdict(TunnelConvergenceInput(
                status: .reconnecting(attempt: 4), desired: true, hasProcess: false, engineAuthorized: false)),
            .forceDisconnected
        )
    }

    /// 平静状态（已断开、用户也不期望连接）什么都不用做
    func testQuietStatesAreLeftAlone() {
        XCTAssertEqual(
            TunnelConvergence.verdict(TunnelConvergenceInput(status: .disconnected, desired: false, hasProcess: false)),
            .none
        )
        XCTAssertEqual(
            TunnelConvergence.verdict(TunnelConvergenceInput(status: .connected, desired: true, hasProcess: true)),
            .none
        )
        XCTAssertEqual(
            TunnelConvergence.verdict(TunnelConvergenceInput(status: .unconfigured, desired: false, hasProcess: false)),
            .none
        )
    }
}

/// 看门狗节奏：空闲断开必须完全停表（这是菜单栏 app 最常见的状态）
final class WatchdogPolicyTests: XCTestCase {
    func testBusyUsesFastInterval() {
        XCTAssertEqual(WatchdogPolicy.interval(status: .connecting, desired: true, hasProcess: false),
                       WatchdogPolicy.busyInterval)
        XCTAssertEqual(WatchdogPolicy.interval(status: .reconnecting(attempt: 1), desired: true, hasProcess: false),
                       WatchdogPolicy.busyInterval)
    }

    /// 空闲断开（用户不连、也没有进程）→ 停表：不再有任何唤醒
    func testIdleDisconnectedStopsTimer() {
        XCTAssertNil(WatchdogPolicy.interval(status: .disconnected, desired: false, hasProcess: false))
        XCTAssertNil(WatchdogPolicy.interval(status: .unconfigured, desired: false, hasProcess: false))
    }

    /// 已连接 / 期望连接 → 慢速兜底（openvpn 挂死不再推送时还能被看见）
    func testRunningOrDesiredUsesSlowInterval() {
        XCTAssertEqual(WatchdogPolicy.interval(status: .connected, desired: true, hasProcess: true),
                       WatchdogPolicy.idleInterval)
        XCTAssertEqual(WatchdogPolicy.interval(status: .disconnected, desired: true, hasProcess: false),
                       WatchdogPolicy.idleInterval)
    }

    /// 已连接但用户意图已变 → 仍要开表，否则没人把状态收敛回来
    func testConnectedWithoutIntentKeepsTimerArmed() {
        XCTAssertEqual(WatchdogPolicy.interval(status: .connected, desired: false, hasProcess: true),
                       WatchdogPolicy.idleInterval)
    }
}
