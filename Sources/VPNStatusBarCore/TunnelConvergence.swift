import Foundation

// MARK: - 状态收敛兜底（纯逻辑，可单元测试）
//
// 背景：真机实测出现过「一直在重连中、但没有隧道、也没有重试在跑、菜单栏图标一直呼吸」的
// 死状态 —— 同时把 CPU 拖在 9%（呼吸动画是 SwiftUI 无限动画，见 app 层 PulseLayer.swift）。
// 成因是状态机允许「busy 状态 + 没有任何在飞的动作」同时存在：
//   - `refreshState` 在 `isWaitingRetry` 上直接 return，一旦这个标记卡住就永不收敛；
//   - 重试用的 Timer 挂在默认 run-loop 模式，modal 循环（如打开文件选择面板）期间不触发；
//   - `prepareAndStart` 的背景清理回来时若 `desiredConnected`/`manualDisconnect` 变了，会带着
//     先前设好的 `.connecting` 直接 return。
//
// 这里把「busy 必须有一个在飞的动作」写成显式的、可测的判定：调用方（看门狗）按结论收敛。

/// 一个"忙碌中"的状态（连接中 / 重连中）必须至少满足其一，否则就是卡死：
/// 有进程在跑（`hasProcess`）、启动序列在飞（`isStarting` 且未超宽限期）、重试已武装（`retryArmed`）。
public enum ConvergenceVerdict: Equatable, Sendable {
    /// 状态自洽，什么都不用做
    case none
    /// 补一次重试：状态卡在 busy，但用户仍期望连接、自动重连开着、引擎可用
    case scheduleRetry
    /// 收敛到「已断开」：清掉等待/重试标记并停表（用户意图或前置条件已不允许继续）
    case forceDisconnected
}

/// 判定输入（显式列出来，方便单测只改动关心的那一两项）
public struct TunnelConvergenceInput: Equatable, Sendable {
    public var status: VPNStatus
    /// 用户意图：是否期望保持连接
    public var desired: Bool
    /// openvpn 进程是否还活着
    public var hasProcess: Bool
    /// 启动序列（残留清理 + 拉起）是否在进行中
    public var isStarting: Bool
    /// 距启动序列开始过了多久（仅当 `isStarting` 时有意义）
    public var secondsSinceStart: TimeInterval
    /// 是否处于"等待重连"标记
    public var isWaitingRetry: Bool
    /// 重试计时器是否真的已经武装（`retryTimer != nil`）
    public var retryArmed: Bool
    public var autoReconnect: Bool
    public var engineAuthorized: Bool

    public init(status: VPNStatus,
                desired: Bool,
                hasProcess: Bool,
                isStarting: Bool = false,
                secondsSinceStart: TimeInterval = 0,
                isWaitingRetry: Bool = false,
                retryArmed: Bool = false,
                autoReconnect: Bool = true,
                engineAuthorized: Bool = true) {
        self.status = status
        self.desired = desired
        self.hasProcess = hasProcess
        self.isStarting = isStarting
        self.secondsSinceStart = secondsSinceStart
        self.isWaitingRetry = isWaitingRetry
        self.retryArmed = retryArmed
        self.autoReconnect = autoReconnect
        self.engineAuthorized = engineAuthorized
    }
}

public enum TunnelConvergence {
    /// 启动序列的宽限期：残留清理要等旧实例让出端口（1.5s）+ 一次一次性查询，正常几秒内结束。
    /// 超过这个时长还停在"启动中"就当成卡死，交给收敛兜底，避免再次出现"永远连接中"。
    public static let startGrace: TimeInterval = 30

    public static func verdict(_ input: TunnelConvergenceInput) -> ConvergenceVerdict {
        // 用户已经不期望连接，界面却还停在连接/已连接上：先把状态收敛回来（旧 refreshState 的 !desired 分支）
        if !input.desired, input.status.isConnected || input.status.isBusy {
            return .forceDisconnected
        }
        // 非 busy：不归这里管（已连接由 management 推送/进程退出事件驱动）
        guard input.status.isBusy else { return .none }
        // 有进程在跑：openvpn 自己的重连状态机 + 推送负责推进
        if input.hasProcess { return .none }
        // 启动序列在飞（未超宽限期）
        if input.isStarting, input.secondsSinceStart < startGrace { return .none }
        // 重试确实已武装：等它触发即可
        if input.isWaitingRetry, input.retryArmed { return .none }
        // 到这里就是「busy 但没有任何在飞的动作」：能重试就补一次重试，否则回到已断开
        let canRetry = input.desired && input.autoReconnect && input.engineAuthorized
        return canRetry ? .scheduleRetry : .forceDisconnected
    }
}

// MARK: - 看门狗节奏（纯逻辑，可单元测试）
//
// 看门狗的职责只有两件事：收敛上面那种卡死状态、以及在 management 推送不可用时补一次状态查询。
// 它不需要在"空闲断开"时醒来 —— 那正是菜单栏 app 最常见的状态，5 秒一次的表会让进程
// 每小时醒 720 次、永远进不了深度空闲（实测空闲基线 CPU 只有 0.1%，所以这里省的是唤醒与续航）。

public enum WatchdogPolicy {
    /// 忙碌（连接中/重连中）：要快速收敛，5 秒
    public static let busyInterval: TimeInterval = 5
    /// 在跑或期望在跑（含已连接）：只兜"openvpn 挂死且不再推送"这一种情况，30 秒足够
    public static let idleInterval: TimeInterval = 30

    /// 返回 nil 表示完全停表（空闲断开：没有任何需要收敛的东西）
    public static func interval(status: VPNStatus, desired: Bool, hasProcess: Bool) -> TimeInterval? {
        if status.isBusy { return busyInterval }
        let quiet = !status.isConnected && !desired && !hasProcess
        return quiet ? nil : idleInterval
    }
}
