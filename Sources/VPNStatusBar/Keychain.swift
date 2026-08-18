import Foundation
import Security

// MARK: - Keychain 封装（密码安全存储）
// 密码唯一明文落点：macOS 钥匙串（kSecClassGenericPassword）。
// 用户名/配置文件名等非敏感信息存 UserDefaults（VPNManager 内管理）。

enum Keychain {

    /// 钥匙串服务标识（对应 app bundle id）
    static let service = "local.zhongtang.vpnstatusbar"

    /// 写入/更新密码（同 account 覆盖）
    @discardableResult
    static func savePassword(_ password: String, account: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // 先删旧值（不存在时报 errSecItemNotFound，忽略）
        SecItemDelete(baseQuery as CFDictionary)

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// 读取密码
    static func loadPassword(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 删除密码
    @discardableResult
    static func deletePassword(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}