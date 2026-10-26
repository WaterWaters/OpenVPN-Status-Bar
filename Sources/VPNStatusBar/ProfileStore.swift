import Foundation
import VPNStatusBarCore

/// 多配置存储（文件 + 索引），迁移兼容旧单文件 config.ovpn
final class ProfileStore {
    /// 并发约定：只在主线程访问（VPNManager 的读写都在主线程；后台只做 Keychain IPC）
    nonisolated(unsafe) static let shared = ProfileStore()

    private let fm = FileManager.default
    private let kActiveId = "vpn.activeProfileId"

    /// 数据目录：**只解析/创建一次**（原来每次访问都 `createDirectory`，
    /// 而 `ovpnPath`/`configPath` 会频繁走到这里 —— 面板每次重绘都在做无谓的系统调用）
    private lazy var baseDirectory: String = {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("VPNStatusBar", isDirectory: true).path
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var baseDir: String { baseDirectory }

    private var profilesDir: String { "\(baseDir)/profiles" }
    private var indexPath: String { "\(baseDir)/profiles.json" }
    private var legacyPath: String { "\(baseDir)/config.ovpn" }

    // MARK: - CRUD

    /// 进程内缓存：profiles.json 只在首次与写操作时落盘，其余都是内存查找。
    /// （原来每次 `loadAll()` 都读盘 + JSON 解码，而 `activeProfile()` 一次最多调 3 次，
    ///  配置卡每行又都会调它 —— 面板每重绘一次就是 N×3 次磁盘 I/O。）
    private var cachedList: [VPNProfile]?

    func loadAll() -> [VPNProfile] {
        if let cachedList { return cachedList }
        migrateIfNeeded()
        let list = readIndexFromDisk()
        cachedList = list
        return list
    }

    private func readIndexFromDisk() -> [VPNProfile] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: indexPath)),
              let list = try? JSONDecoder().decode([VPNProfile].self, from: data) else { return [] }
        return list
    }

    func saveAll(_ list: [VPNProfile]) {
        cachedList = list      // 先更新内存：写盘失败也不至于让界面回退到旧列表
        try? fm.createDirectory(atPath: profilesDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: URL(fileURLWithPath: indexPath), options: .atomic)
        }
    }

    func ovpnPath(for id: String) -> String { "\(profilesDir)/\(id).ovpn" }

    /// 多档案索引是否已建立（`profiles.json` 是否存在）。
    /// 一旦为 true，就说明已经走过 v2 的多档案迁移，不该再回退到 legacy 的 `config.ovpn`。
    var hasIndex: Bool { fm.fileExists(atPath: indexPath) }

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
        let list = loadAll()
        guard let id = activeId() else { return list.first }
        return list.first(where: { $0.id == id }) ?? list.first
    }
}
