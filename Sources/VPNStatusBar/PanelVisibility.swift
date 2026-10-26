import AppKit
import Combine

/// 面板是否正在被使用（MenuBarExtra 的面板窗口成为/失去 key）。
///
/// 用途：把"只有看面板时才需要的工作"按需开关 —— 1 秒时钟、流量推送订阅。
/// 面板关闭时这些归零，笔记本上不再有常驻唤醒。
final class PanelVisibility: ObservableObject {
    /// 并发约定：只在主线程访问（NSWindow 通知的 queue 是 .main）
    nonisolated(unsafe) static let shared = PanelVisibility()

    @Published private(set) var isVisible = false

    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow, PanelWindow.isPanel(window) else { return }
            self?.update(true)
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow, PanelWindow.isPanel(window) else { return }
            self?.update(false)
        })
        // 兜底：面板被直接关闭时（不经 resignKey）也要算作不可见
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow, PanelWindow.isPanel(window) else { return }
            self?.update(false)
        })
    }

    private func update(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
    }
}

/// 面板窗口的识别（面板是否可见 / 流量推送与时钟的按需开关都用它）。
/// SwiftUI 的类名是 `MenuBarExtraWindow<…>`，高度门槛用于排除菜单栏自己的 NSStatusBarWindow。
enum PanelWindow {
    static func isPanel(_ window: NSWindow) -> Bool {
        guard window.isVisible, window.frame.height > 60 else { return false }
        return String(describing: type(of: window)).contains("MenuBarExtra")
    }
}
