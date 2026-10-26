import Foundation
import Network
import os

/// 网络路径变化 → 立刻收敛连接（换 Wi-Fi、插拔网线、唤醒后重连）。
///
/// 边界（避免和既有退避/停止逻辑打架）：
/// - 只回报"网络从不可用变可用 / 可用网络发生了切换"，不回报中断本身；
/// - 具体要不要重连由 `VPNManager.handleNetworkPathChange` 判定（期望连接、未连上、没有因凭据错误停下…）；
/// - 去抖 1.5 秒：路径变化常连续来几次，避免连着重启进程。
final class NetworkMonitor {
    /// 并发约定：只在主线程访问（onPathChange 由 DispatchQueue.main 触发）
    nonisolated(unsafe) static let shared = NetworkMonitor()

    /// 网络可用性变化回调（主线程）
    var onPathChange: (() -> Void)?

    private let log = Logger(subsystem: "io.vpnstatusbar", category: "network")
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "vpnstatusbar.network")

    // 以下只在 queue 上访问
    private var lastSatisfied: Bool?
    private var lastInterfaces: Set<String> = []

    // 以下只在主线程访问
    private var pending: DispatchWorkItem?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = (path.status == .satisfied)
            let interfaces = Set(path.availableInterfaces.map { "\($0.type)/\($0.name)" })
            let firstReport = (self.lastSatisfied == nil)
            let changed = firstReport
                || self.lastSatisfied != satisfied
                || (satisfied && interfaces != self.lastInterfaces)
            self.lastSatisfied = satisfied
            self.lastInterfaces = interfaces
            guard changed, satisfied else { return }
            self.log.notice("网络可用（首次=\(firstReport, privacy: .public)）：\(interfaces.sorted().joined(separator: ","), privacy: .public)")
            self.schedule()
        }
        monitor.start(queue: queue)
    }

    /// 睡眠唤醒后调用（系统需要几秒恢复网络，调用方已延迟）
    func handleWake() {
        log.notice("唤醒后检查网络")
        schedule()
    }

    private func schedule() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.onPathChange?() }
            self.pending = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
        }
    }
}
