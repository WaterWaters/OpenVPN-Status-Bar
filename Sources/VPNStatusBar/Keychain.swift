import Foundation
import Security

// MARK: - Keychain 封装（密码安全存储）
// 密码唯一明文落点：macOS 钥匙串（kSecClassGenericPassword）。
// 用户名/配置文件名等非敏感信息存 UserDefaults（VPNManager 内管理）。

enum Keychain {

    /// 钥匙串服务标识（对应 app bundle id）
    static let service = "local.zhongtang.vpnstatusbar"

    /// 进程内缓存，避免启动期频繁 IPC
    private static var cache: [String: String?] = [:]
    private static let cacheQueue = DispatchQueue(label: "vpn.keychain.cache")

    static func cachedPassword(account: String) -> String? {
        cacheQueue.sync { cache[account] ?? nil } ?? nil
    }

    static func hasCached(account: String) -> Bool {
        cacheQueue.sync { cache.keys.contains(account) }
    }

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
        let ok = status == errSecSuccess
        if ok {
            cacheQueue.sync { cache[account] = password }
        }
        return ok
    }

    /// 读取密码（带进程内缓存）
    static func loadPassword(account: String) -> String? {
        if hasCached(account: account) {
            return cachedPassword(account: account) ?? nil
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            cacheQueue.sync { cache[account] = nil }
            return nil
        }
        let pwd = String(data: data, encoding: .utf8)
        cacheQueue.sync { cache[account] = pwd }
        return pwd
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
        let ok = status == errSecSuccess || status == errSecItemNotFound
        if ok {
            cacheQueue.sync { cache[account] = nil }
        }
        return ok
    }

    static func invalidateCache(account: String) {
        cacheQueue.sync { cache[account] = nil }
    }
}