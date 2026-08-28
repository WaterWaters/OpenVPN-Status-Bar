import Foundation
import Combine

/// 轻量时钟源：仅承载每秒 tick，隔离 `VPNManager.clock` 对全量视图的无效刷新
/// 使用单例，前向兼容 `VPNManager.clock`（保留但不再作为主要订阅源）
final class TickProvider: ObservableObject {
    static let shared = TickProvider()

    @Published private(set) var now: Date = Date()

    private var timer: Timer?

    private init() {
        start()
    }

    private func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.now = Date()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func setNow(_ date: Date) {
        now = date
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
