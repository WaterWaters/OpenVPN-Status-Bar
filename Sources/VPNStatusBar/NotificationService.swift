import Foundation
import UserNotifications

enum NotificationService {
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String) {
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
