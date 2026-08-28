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

    static func notifyConnected(profile: String) { notify(title: "VPN 已连接", body: "\(profile) · 隧道已建立") }
    static func notifyDisconnected(profile: String) { notify(title: "VPN 已断开", body: "\(profile) · 已断开连接") }
    static func notifyReconnectFailed(profile: String, attempt: Int) { notify(title: "重连失败", body: "\(profile) · 第 \(attempt) 次重连失败") }
}
