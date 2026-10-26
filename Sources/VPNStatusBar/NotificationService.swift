import Foundation
import UserNotifications

enum NotificationService {
    /// 是否具备可用的应用身份。
    /// 以非 .app 方式启动（`swift run`、直接跑 `.build` 里的二进制）时 Bundle 没有标识，
    /// `UNUserNotificationCenter.current()` 会直接抛 ObjC 异常 → 进程 abort → 菜单栏图标永远不出现。
    private static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorizationIfNeeded() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        guard isAvailable else { return }
        guard UserDefaults.standard.bool(forKey: "notifyEnabled") else { return }
        // 若未授权，静默失败
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    static func notifyConnected(profile: String) { notify(title: L10n.tr("notify.connected.title"), body: L10n.tr("notify.connected.body", profile)) }
    static func notifyDisconnected(profile: String) { notify(title: L10n.tr("notify.disconnected.title"), body: L10n.tr("notify.disconnected.body", profile)) }
    static func notifyReconnectFailed(profile: String, attempt: Int) { notify(title: L10n.tr("notify.reconnectFailed.title"), body: L10n.tr("notify.reconnectFailed.body", profile, attempt)) }
}
