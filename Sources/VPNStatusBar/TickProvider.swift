import Foundation
import Combine
import os

/// 秒级时钟源：只给"需要每秒刷新"的子视图用（连接时长、重连倒计时）。
///
/// 按需启停：面板可见时才走表（由 `VPNManager` 依 `PanelVisibility` 驱动），
/// 面板关闭后不再有任何 1 秒唤醒 —— 时长在面板重新打开时用 `setNow` 立刻校正。
final class TickProvider: ObservableObject {
    /// 并发约定：只在主线程访问（SwiftUI 视图 + 主线程回调调用 setActive/setNow）
    nonisolated(unsafe) static let shared = TickProvider()

    @Published private(set) var now: Date = Date()

    private let log = Logger(subsystem: "io.vpnstatusbar", category: "tick")
    private var timer: Timer?

    private init() {}

    /// 面板可见性 + 状态变化时调用
    func setActive(_ active: Bool) {
        if active {
            setNow(Date())   // 立刻校正：面板刚打开时时长/倒计时必须是对的
            guard timer == nil else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.now = Date()
            }
            // 0.1 秒容差：让系统把这次唤醒和别的定时器合并（秒级展示差个零点几秒看不出来）
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            log.debug("ticker 启动")
        } else {
            if timer != nil { log.debug("ticker 停止") }
            timer?.invalidate()
            timer = nil
        }
    }

    /// 立即把时钟推进到当前时刻（外部只想刷新一次时用）
    func setNow(_ date: Date) {
        now = date
    }

    var isTicking: Bool { timer != nil }
}
