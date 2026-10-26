import Foundation

/// 启动代次：每次"开始一次新的启动"或"主动中断"都推进一代。
///
/// 为什么需要它：`Process.terminationHandler`、stderr 管道、management 推送都是**异步**回调，
/// 而用户可以在旧进程还没退干净时切配置、断开再连。没有代次时，旧进程的退出会被当成
/// "当前隧道断了"处理 —— 表现是新隧道连上约 5 秒后又被掐断重连一次。
///
/// 约定：调用方只做 `isCurrent` 判定，不比较大小（`&+=` 回绕后仍能正确区分新旧）。
/// 并发约定：只在主线程读写（与 `VPNManager` 一致）。
public struct LaunchTracker: Equatable, Sendable {
    public private(set) var current: UInt64

    public init(current: UInt64 = 0) {
        self.current = current
    }

    /// 开始一次新启动，返回本次代次；调用方把它捕获进该次启动的所有回调。
    @discardableResult
    public mutating func begin() -> UInt64 {
        current &+= 1
        return current
    }

    /// 主动中断：让此前所有在飞的回调失效。
    public mutating func invalidate() {
        current &+= 1
    }

    /// 该代次是否仍是当前代次（过期事件一律丢弃）。
    public func isCurrent(_ generation: UInt64) -> Bool {
        generation == current
    }
}
