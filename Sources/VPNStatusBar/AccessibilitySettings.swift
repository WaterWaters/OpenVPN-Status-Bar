import AppKit
import Combine

/// 系统辅助功能设置的实时镜像。
///
/// 面板里的呼吸/脉冲动画此前无条件播放，而设计稿把 `prefers-reduced-motion` 列为验收项
/// （design/mockup.html:417-425、:553）。这里读 `NSWorkspace` 并在用户在系统设置里改动时实时更新。
final class MotionSettings: ObservableObject {
    /// 并发约定：只在主线程访问（视图读取 + 通知回调 queue 是 .main）
    nonisolated(unsafe) static let shared = MotionSettings()

    @Published private(set) var reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }
}
