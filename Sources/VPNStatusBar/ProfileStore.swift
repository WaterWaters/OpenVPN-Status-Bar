import Foundation
import VPNStatusBarCore

/// 多配置存储（文件 + 索引），迁移兼容旧单文件 config.ovpn
final class ProfileStore {
    static let shared = ProfileStore()

    private let fm = FileManager.default
    private let kActiveId = "vpn.activeProfileId"

    private var baseDir: String {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("VPNStatusBar", isDirectory: true).path
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private var profilesDir: String { "\(baseDir)/profiles" }
    private var indexPath: String { "\(baseDir)/profiles.json" }
    private var legacyPath: String { "\(baseDir)/config.ovpn" }

    // MARK: - CRUD

    func loadAll() -> [VPNProfile] {
        migrateIfNeeded()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: indexPath)),
              let list = try? JSONDecoder().decode([VPNProfile].self, from: data) else { return [] }
        return list
    }

    func saveAll(_ list: [VPNProfile]) {
        try? fm.createDirectory(atPath: profilesDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: URL(fileURLWithPath: indexPath), options: .atomic)
        }
    }

    func ovpnPath(for id: String) -> String { "\(profilesDir)/\(id).ovpn" }

    func activeId() -> String? { UserDefaults.standard.string(forKey: kActiveId) }

    func setActiveId(_ id: String?) {
        if let id { UserDefaults.standard.set(id, forKey: kActiveId) }
        else { UserDefaults.standard.removeObject(forKey: kActiveId) }
    }

    @discardableResult
    func add(ovpnData: Data, fileName: String, username: String) -> VPNProfile {
        let ovpnStr = String(data: ovpnData, encoding: .utf8) ?? ""
        let server = VPNProfile.parseServerAddress(from: ovpnStr)
        let p = VPNProfile(name: (fileName as NSString).deletingPathExtension, fileName: fileName, username: username, serverAddress: server)
        try? fm.createDirectory(atPath: profilesDir, withIntermediateDirectories: true)
        try? ovpnData.write(to: URL(fileURLWithPath: ovpnPath(for: p.id)), options: .atomic)
        var list = loadAll()
        list.append(p)
        saveAll(list)
        if activeId() == nil { setActiveId(p.id) }
        return p
    }

    func update(_ profile: VPNProfile) {
        var list = loadAll()
        if let idx = list.firstIndex(where: { $0.id == profile.id }) {
            list[idx] = profile
            saveAll(list)
        }
    }

    func remove(id: String) {
        var list = loadAll()
        list.removeAll { $0.id == id }
        saveAll(list)
        try? fm.removeItem(atPath: ovpnPath(for: id))
        Keychain.deletePassword(account: keychainAccount(for: id))
        if activeId() == id {
            setActiveId(list.first?.id)
        }
    }

    func keychainAccount(for id: String) -> String { "vpn-user-\(id)" }
    // 兼容旧单账户
    var legacyAccount: String { "vpn-user" }

    // MARK: - Migration

    func migrateIfNeeded() {
        guard fm.fileExists(atPath: legacyPath),
              !fm.fileExists(atPath: indexPath) else { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: legacyPath)) else { return }
        let ovpnStr = String(data: data, encoding: .utf8) ?? ""
        let server = VPNProfile.parseServerAddress(from: ovpnStr)
        let name = UserDefaults.standard.string(forKey: "vpn.profileName") ?? "VPN"
        let username = UserDefaults.standard.string(forKey: "vpn.username") ?? ""
        let p = VPNProfile(name: name, fileName: name.hasSuffix(".ovpn") ? name : "\(name).ovpn", username: username, serverAddress: server)
        try? fm.createDirectory(atPath: profilesDir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: ovpnPath(for: p.id)), options: .atomic)
        saveAll([p])
        setActiveId(p.id)
        // 迁移 Keychain 旧密码
        if let pwd = Keychain.loadPassword(account: legacyAccount) {
            _ = Keychain.savePassword(pwd, account: keychainAccount(for: p.id))
        }
        // 保留 legacy 文件以防回滚，不删除
    }

    func activeProfile() -> VPNProfile? {
        guard let id = activeId() else { return loadAll().first }
        return loadAll().first(where: { $0.id == id }) ?? loadAll().first
    }
}
