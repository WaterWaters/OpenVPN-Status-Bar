import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return UserDefaults.standard.bool(forKey: "launchAtLogin")
    }

    static func setEnabled(_ enabled: Bool) {
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
