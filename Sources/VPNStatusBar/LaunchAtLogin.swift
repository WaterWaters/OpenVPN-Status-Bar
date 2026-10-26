import Foundation
import ServiceManagement

enum LaunchAtLogin {
    /// 非 .app 启动（`swift run`）时没有应用身份，SMAppService 不可用 —— 按“不支持”处理，
    /// 既避免异常，也避免在开发态误注册登录项
    private static var isSupported: Bool { Bundle.main.bundleIdentifier != nil }

    static var isEnabled: Bool {
        guard isSupported else { return false }
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return UserDefaults.standard.bool(forKey: "launchAtLogin")
    }

    static func setEnabled(_ enabled: Bool) {
        guard isSupported else { return }
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // 失败回退到 UserDefaults 记录（至少 UI 状态一致）
                UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
            }
        } else {
            UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
        }
    }
}
