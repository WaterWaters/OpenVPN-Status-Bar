import Foundation
import Combine
import AppKit
import SwiftUI
import VPNStatusBarCore

/// VPN 管理器：负责配置读写、连接/断开、隧道状态监控、断线自动重连
/// v2：不再依赖上一级文件夹的 *.ovpn / .user ——
///   配置在 app 内导入：ovpn 复制到 Application Support，密码存 Keychain，
///   连接时由 app 生成临时 auth 文件，经参数化 runner 启动 openvpn。
/// v2.1：openvpn 环境检测（路径探测 + sudo 免密授权校验），
///   未就绪时给出明确原因与修复命令（适配同事机器 brew 前缀/软链差异）。
final class VPNManager: ObservableObject {
    static let shared = VPNManager()

    // MARK: - 配置存储（v2：应用内导入，不依赖本地文件）

    /// 数据目录：~/Library/Application Support/VPNStatusBar/（懒加载，启动期不建目录）
    private lazy var _configDir: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("VPNStatusBar", isDirectory: true).path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()
    private var configDir: String { _configDir }

    /// 导入的 ovpn 配置（多配置：activeProfile 对应文件；兼容 legacy 单文件）
    var configPath: String {
        if let p = store.activeProfile() { return store.ovpnPath(for: p.id) }
        return "\(configDir)/config.ovpn"
    }
    /// 连接时临时生成的认证文件（0600，断开即删）
    private var authFile: String { "\(configDir)/.auth.tmp" }
    /// 日志文件（openvpn 输出，供面板展示）
    var logFile: String { "\(configDir)/vpn.log" }
    private let routePattern = "10.8/16"

    // 多配置
    let store = ProfileStore.shared
    @Published var profiles: [VPNProfile] = []

    var activeProfile: VPNProfile? { store.activeProfile() }

    private var activeKeychainAccount: String {
        if let p = activeProfile { return store.keychainAccount(for: p.id) }
        return store.legacyAccount
    }

    // 启动期缓存
    private var cachedIsConfigured: Bool?
    private var cachedServerAddress: String?
    private var serverAddressLoaded = false

    /// 内置引擎稳定路径（首启同步到此，sudoers 免密指向此处 —— 移动/升级 app 不失效）
    private let engineStablePath = "/usr/local/vpnstatusbar/openvpn"
    /// app 内置的自包含 openvpn（build-openvpn.sh 静态编译，build.sh 打进 Contents/Resources）
    private var bundledEnginePath: String? {
        Bundle.main.resourceURL?.appendingPathComponent("openvpn").path
    }

    /// Keychain 中用户名/密码的存储标识（兼容旧单账户，实际按 profile 区分）
    private let keychainAccount = "vpn-user"
    let legacyKeychainAccount = "vpn-user"

    /// 用户默认键（保留兼容，实际主数据源为 ProfileStore）
    private let kProfileName = "vpn.profileName"
    private let kUsername = "vpn.username"

    /// 是否已导入配置（多配置感知 + 缓存）
    var isConfigured: Bool {
        if let cached = cachedIsConfigured { return cached }
        // 多配置路径
        if !profiles.isEmpty {
            let result = activeProfile != nil && FileManager.default.fileExists(atPath: configPath)
                && Keychain.loadPassword(account: activeKeychainAccount) != nil
            cachedIsConfigured = result
            return result
        }
        let exists = FileManager.default.fileExists(atPath: configPath)
        guard exists else {
            cachedIsConfigured = false
            return false
        }
        let hasPwd = Keychain.loadPassword(account: keychainAccount) != nil
        let result = exists && hasPwd
        cachedIsConfigured = result
        return result
    }

    private func invalidateIsConfiguredCache() {
        cachedIsConfigured = nil
    }

    /// 配置文件名（多配置优先）
    var profileName: String {
        if let p = activeProfile { return p.name }
        return UserDefaults.standard.string(forKey: kProfileName) ?? "VPN"
    }

    /// 用户名（多配置优先）
    var username: String {
        get {
            if let p = activeProfile { return p.username }
            return UserDefaults.standard.string(forKey: kUsername) ?? ""
        }
        set {
            if var p = activeProfile {
                p.username = newValue
                store.update(p)
                refreshProfiles()
            } else {
                UserDefaults.standard.set(newValue, forKey: kUsername)
            }
        }
    }

    /// 服务器地址（多配置优先，带缓存）
    var serverAddress: String {
        if let p = activeProfile { return p.serverAddress }
        if serverAddressLoaded, let cached = cachedServerAddress { return cached }
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            cachedServerAddress = "—"
            serverAddressLoaded = true
            return "—"
        }
        for line in content.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("remote ") {
                let addr = t.dropFirst(7).trimmingCharacters(in: .whitespaces)
                cachedServerAddress = addr
                serverAddressLoaded = true
                return addr
            }
        }
        cachedServerAddress = "—"
        serverAddressLoaded = true
        return "—"
    }

    private func invalidateServerAddressCache() {
        cachedServerAddress = nil
        serverAddressLoaded = false
    }

    // MARK: - 启动脚本（参数化，优先使用 app 内置副本）

    private lazy var runnerScript: String = {
        // 1. app bundle 内副本（build.sh 打包进 Contents/Resources，自包含）
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("vpn-runner.sh").path,
           FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        // 2. 通用回退：app 旁常见位置（已去中唐硬编码）
        let bundle = Bundle.main.bundleURL
        let candidates = [
            bundle.deletingLastPathComponent().appendingPathComponent("vpn-runner.sh").path,
            bundle.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("vpn-runner.sh").path,
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return c
        }
        return candidates[0]
    }()

    // MARK: - 发布状态
    @Published var status: VPNStatus = .unconfigured {
        didSet {
            if oldValue != status {
                switch status {
                case .connected:
                    NotificationService.notifyConnected(profile: profileName)
                case .disconnected:
                    if oldValue.isConnected || oldValue.isBusy { NotificationService.notifyDisconnected(profile: profileName) }
                case .reconnecting(let attempt) where attempt >= 3:
                    NotificationService.notifyReconnectFailed(profile: profileName, attempt: attempt)
                default: break
                }
            }
        }
    }
    @Published var autoReconnect: Bool = true {
        didSet {
            // 重连等待中关闭自动重连 → 立即停止重连
            if !autoReconnect && isWaitingRetry {
                retryTimer?.invalidate()
                retryTimer = nil
                retryDeadline = nil
                isWaitingRetry = false
                status = .disconnected
                lastEvent = L10n.tr("event.stoppedReconnect")
            }
        }
    }
    @Published var reconnectCount: Int = 0
    @Published var connectedAt: Date?
    @Published var lastEvent: String = "Ready"
    @Published var logTail: String = ""
    var desiredConnectedPublic: Bool { desiredConnected }
    /// VPN 引擎授权状态（连接前置校验 + 设置页展示）
    @Published private(set) var engineAuth: EngineAuth = .checking
    /// 下一次自动重连的触发时刻（重连中用于倒计时显示）
    @Published private(set) var retryDeadline: Date?
    /// 秒级时钟：保留兼容（P1 后由 TickProvider 驱动，避免全量刷新）
    @Published private(set) var clock: Date = Date()
    /// 是否需要时钟 tick（供 TickProvider 过滤）
    var needsTick: Bool { status.isConnected || retryDeadline != nil }

    /// 用户意图：是否期望保持连接
    private var desiredConnected = false
    /// 是否为手动断开（避免触发自动重连）
    private var manualDisconnect = false

    private var process: Process?
    private var statusTimer: Timer?
    private var clockTimer: Timer?
    private var retryTimer: Timer?
    private var retryDelay: TimeInterval = 5
    private let maxRetryDelay: TimeInterval = 60
    private let monitorInterval: TimeInterval = 2.0
    /// 防重入：terminationHandler 与定时器同时触发
    private var isHandlingExit = false
    /// 是否已处于等待重连状态（防止 refreshState 反复调度导致重连被无限推迟）
    private var isWaitingRetry = false

    func refreshProfiles() {
        profiles = store.loadAll()
        cachedIsConfigured = nil
        invalidateServerAddressCache()
    }

    func switchProfile(id: String) {
        store.setActiveId(id)
        refreshProfiles()
        // 切换后收敛状态
        status = isConfigured ? .disconnected : .unconfigured
        lastEvent = L10n.tr("event.profileSwitched", profileName)
        loadLogTail()
    }

    func deleteProfile(id: String) {
        let wasActive = store.activeId() == id
        store.remove(id: id)
        refreshProfiles()
        if wasActive {
            status = isConfigured ? .disconnected : .unconfigured
            lastEvent = L10n.tr("event.profileDeleted")
        }
    }

    private init() {
        // 迁移旧单文件
        store.migrateIfNeeded()
        profiles = store.loadAll()
        // 轻量初始：仅文件存在性快速判断，不触发 Keychain IPC；日志/授权异步
        let quickConfigured = FileManager.default.fileExists(atPath: configPath) || !profiles.isEmpty
        status = quickConfigured ? .disconnected : .unconfigured
        lastEvent = quickConfigured ? L10n.tr("event.ready") : L10n.tr("event.noProfile")
        // 延迟非关键任务，避免阻塞启动首帧
        startMonitoring()
        startClock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let tail = self.readLogTailSync()
            DispatchQueue.main.async { self.logTail = tail }
        }
        // 引擎授权延迟 300ms，缓存 60s 内结果
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshEngineAuth()
        }
        // 后台校验真实 isConfigured，修正状态（文件存在但 Keychain 缺失的边界）
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let real = self.isConfigured
            DispatchQueue.main.async {
                if !real && self.status == .disconnected && quickConfigured {
                    self.status = .unconfigured
                    self.lastEvent = L10n.tr("event.noProfile")
                }
            }
        }
    }

    private func readLogTailSync() -> String {
        guard let content = try? String(contentsOfFile: logFile, encoding: .utf8) else {
            return "（暂无日志）"
        }
        let lines = content.split(separator: "\n")
        let tail = lines.suffix(4).joined(separator: "\n")
        return tail.isEmpty ? "（暂无日志）" : String(tail)
    }

    // MARK: - VPN 引擎授权（v3：内置 openvpn + 一次性免密授权）

    /// 触发引擎授权检测（异步，完成后发布 engineAuth）
    func refreshEngineAuth() {
        engineAuth = .checking
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            let binExists = fm.isExecutableFile(atPath: self.engineStablePath)
            let sudoOk = binExists && self.sudoAllows(self.engineStablePath)
            let result: EngineAuth
            if binExists && sudoOk {
                result = .authorized
            } else if binExists {
                result = .unauthorized
            } else {
                result = .broken
            }
            DispatchQueue.main.async {
                self.engineAuth = result
                if result == .authorized { self.lastEvent = L10n.tr("event.engineAuthorized") }
            }
        }
    }

    /// 该路径是否已被 sudoers 授权免密运行（sudo -n -l 退出码 0 = 已授权）
    private func sudoAllows(_ path: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proc.arguments = ["-n", "-l", path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// 发起一次性授权（弹一次系统管理员密码，安装引擎到稳定路径 + 写入 sudoers 免密）
    /// 未授权 / 异常均调用此方法（授权中去重）
    func authorizeEngine() {
        guard engineAuth != .authorizing else { return }
        let repairing = (engineAuth == .broken)
        engineAuth = .authorizing
        lastEvent = repairing ? L10n.tr("event.repairing") : L10n.tr("event.authorizing")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let ok = self.installEnginePrivileged()
            DispatchQueue.main.async {
                if ok {
                    self.lastEvent = L10n.tr("event.engineAuthorized")
                } else {
                    self.lastEvent = L10n.tr("event.authCancelled")
                }
                self.refreshEngineAuth()
            }
        }
    }

    /// 以管理员权限完成：创建稳定目录 → 安装内置引擎 → 写入 /etc/sudoers.d 免密规则
    private func installEnginePrivileged() -> Bool {
        guard let bundled = bundledEnginePath,
              FileManager.default.fileExists(atPath: bundled) else { return false }
        let user = NSUserName()
        let rule = "\(user) ALL=(root) NOPASSWD: \(engineStablePath)\n"
        let shell = """
        mkdir -p /usr/local/vpnstatusbar
        /bin/cp -f '\(bundled)' /usr/local/vpnstatusbar/openvpn
        /bin/chmod 755 /usr/local/vpnstatusbar/openvpn
        printf '%s' '\(rule)' > /etc/sudoers.d/vpnstatusbar
        /bin/chmod 440 /etc/sudoers.d/vpnstatusbar
        """
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let osa = "do shell script \"\(escaped)\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", osa]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - 配置读写（v2）

    /// 保存配置：ovpn 内容复制到 Application Support，用户名存 UserDefaults，密码存 Keychain
    /// - Parameters:
    ///   - ovpnData: 导入的 ovpn 文件内容
    ///   - fileName: 原始文件名（记录显示用）
    ///   - username: 鉴权用户名
    ///   - password: 鉴权密码（可传 nil 表示保持原有）
    func saveConfig(ovpnData: Data, fileName: String, username: String, password: String?) {
        // 多配置路径：新建档案
        if store.loadAll().isEmpty && FileManager.default.fileExists(atPath: "\(configDir)/config.ovpn") && !FileManager.default.fileExists(atPath: store.ovpnPath(for: "tmp")) {
            // 已在 init 迁移，此分支保留兼容
        }
        // 若处于编辑模式（已有 activeProfile），更新该档案而非新建
        if let active = activeProfile, profiles.contains(where: { $0.id == active.id }), username == active.username || password == nil {
            // 编辑：更新 ovpn 与用户名
            try? ovpnData.write(to: URL(fileURLWithPath: store.ovpnPath(for: active.id)), options: .atomic)
            var updated = active
            updated.fileName = fileName
            updated.name = (fileName as NSString).deletingPathExtension
            updated.username = username
            updated.serverAddress = VPNProfile.parseServerAddress(from: String(data: ovpnData, encoding: .utf8) ?? "")
            updated.updatedAt = Date()
            store.update(updated)
            if let pwd = password {
                if !Keychain.savePassword(pwd, account: store.keychainAccount(for: active.id)) {
                    lastEvent = L10n.tr("event.credFailed")
                    return
                }
            }
            refreshProfiles()
            status = .disconnected
            lastEvent = L10n.tr("event.profileSaved", fileName)
            loadLogTail()
            return
        }
        let p = store.add(ovpnData: ovpnData, fileName: fileName, username: username)
        if let pwd = password {
            if !Keychain.savePassword(pwd, account: store.keychainAccount(for: p.id)) {
                lastEvent = L10n.tr("event.credFailed")
                return
            }
        } else if let legacyPwd = Keychain.loadPassword(account: legacyKeychainAccount) {
            _ = Keychain.savePassword(legacyPwd, account: store.keychainAccount(for: p.id))
        }
        refreshProfiles()
        // 兼容旧 UserDefaults
        UserDefaults.standard.set(fileName, forKey: kProfileName)
        UserDefaults.standard.set(username, forKey: kUsername)
        status = .disconnected
        lastEvent = L10n.tr("event.profileSaved", fileName)
        loadLogTail()
    }

    /// 更新当前档案的凭据（用户名/密码）而不新建
    func updateActiveCredentials(username: String, password: String?) {
        guard var p = activeProfile else { return }
        p.username = username
        p.updatedAt = Date()
        store.update(p)
        UserDefaults.standard.set(username, forKey: kUsername)
        if let pwd = password, !pwd.isEmpty {
            _ = Keychain.savePassword(pwd, account: store.keychainAccount(for: p.id))
        }
        refreshProfiles()
        lastEvent = L10n.tr("event.credUpdated")
    }

    /// 清除配置（多配置：删除当前档案；兼容旧单文件）
    func clearConfig() {
        let fm = FileManager.default
        manualDisconnect = true
        desiredConnected = false
        _ = sendManagementCommand("signal SIGTERM\n")
        terminateProcess()
        process = nil
        cleanupAuthFile()

        if let p = activeProfile {
            store.remove(id: p.id)
        } else {
            try? fm.removeItem(atPath: configPath)
            Keychain.deletePassword(account: keychainAccount)
        }
        try? fm.removeItem(atPath: logFile)
        UserDefaults.standard.removeObject(forKey: kProfileName)
        UserDefaults.standard.removeObject(forKey: kUsername)
        refreshProfiles()
        invalidateIsConfiguredCache()
        invalidateServerAddressCache()

        status = isConfigured ? .disconnected : .unconfigured
        lastEvent = profiles.isEmpty ? L10n.tr("event.profileCleared") : L10n.tr("event.profileDeleted")
        loadLogTail()
    }

    // MARK: - 对外操作

    /// 连接 VPN
    func connect() {
        guard isConfigured else {
            lastEvent = L10n.tr("event.needConfig")
            status = .unconfigured
            return
        }
        // VPN 引擎授权前置校验（内置 openvpn 需一次免密授权）
        switch engineAuth {
        case .checking:
            refreshEngineAuth()
            lastEvent = L10n.tr("event.engineChecking")
        case .authorizing:
            lastEvent = L10n.tr("event.engineAuthorizing")
            status = .disconnected
            return
        case .unauthorized:
            lastEvent = L10n.tr("event.engineUnauthorized")
            status = .disconnected
            return
        case .broken:
            lastEvent = L10n.tr("event.engineBroken")
            status = .disconnected
            return
        case .authorized:
            break
        }
        manualDisconnect = false
        desiredConnected = true
        reconnectCount = 0
        retryDelay = 5
        isWaitingRetry = false
        retryDeadline = nil
        lastEvent = L10n.tr("event.connecting")
        // 清理上次异常退出残留的 openvpn 实例（否则 management 端口被占，新实例无法启动）
        stopExistingInstance()
        startVPNProcess()
    }

    /// 重连等待中立即重连（跳过剩余倒计时）
    func reconnectNow() {
        guard case .reconnecting = status else { return }
        retryTimer?.invalidate()
        retryTimer = nil
        retryDeadline = nil
        isWaitingRetry = false
        lastEvent = L10n.tr("event.reconnectNow")
        startVPNProcess()
    }

    /// 检测并优雅停止残留的 openvpn 实例（app 崩溃/强杀后可能遗留）
    private func stopExistingInstance() {
        guard sendManagementCommand("signal SIGTERM\n") != nil else { return }
        lastEvent = L10n.tr("event.foundStale")
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// 断开 VPN（不触发自动重连）
    func disconnect() {
        guard isConfigured else {
            status = .unconfigured
            return
        }
        manualDisconnect = true
        desiredConnected = false
        retryTimer?.invalidate()
        retryTimer = nil
        retryDeadline = nil
        isWaitingRetry = false
        status = .disconnected
        lastEvent = L10n.tr("event.disconnecting")
        // 优先通过 openvpn management 接口优雅退出（无需 root 权限）
        let resp = sendManagementCommand("signal SIGTERM\n")
        if resp == nil {
            // 兜底：直接终止进程（对 root 属主进程可能因权限失败）
            terminateProcess()
        }
        process = nil
        cleanupAuthFile()
        loadLogTail()
        lastEvent = L10n.tr("event.disconnectedManual")
    }

    /// 退出前清理
    func shutdown() {
        retryTimer?.invalidate()
        statusTimer?.invalidate()
        clockTimer?.invalidate()
        manualDisconnect = true
        desiredConnected = false
        _ = sendManagementCommand("signal SIGTERM\n")
        terminateProcess()
        cleanupAuthFile()
    }

    // MARK: - 启动 / 停止 openvpn 进程

    private func startVPNProcess() {
        retryTimer?.invalidate()
        retryTimer = nil
        isWaitingRetry = false
        cleanupAuthFile()

        // 由 app 生成 auth 文件（用户名 + Keychain 密码），0600 权限
        guard writeAuthFile() else {
            lastEvent = L10n.tr("event.authFailed")
            status = .disconnected
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        // 参数化调用：runner 不再读取同目录 .ovpn/.user
        proc.arguments = [
            runnerScript,
            "--openvpn", engineStablePath,
            "--ovpn", configPath,
            "--auth", authFile,
            "--log", logFile,
        ]
        proc.standardOutput = FileHandle.nullDevice
        // 捕获 stderr：runner 探测/权限失败时给出可读原因（写入日志 + 事件行）
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.captureRunnerError(errPipe)
                self?.handleProcessExit()
            }
        }

        do {
            try proc.run()
            process = proc
            if status != .connected {
                status = .connecting
            }
            lastEvent = L10n.tr("event.openvpnStarted")
            // 启动后立即读一次日志
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.loadLogTail()
            }
        } catch {
            lastEvent = L10n.tr("event.startFailed", error.localizedDescription)
            status = .disconnected
        }
    }

    /// 生成认证文件（用户名\n密码，0600，多配置感知）
    private func writeAuthFile() -> Bool {
        guard let password = Keychain.loadPassword(account: activeKeychainAccount) else { return false }
        let content = "\(username)\n\(password)\n"
        let url = URL(fileURLWithPath: authFile)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFile)
            return true
        } catch {
            return false
        }
    }

    private func terminateProcess() {
        guard let proc = process else { return }
        if proc.isRunning {
            proc.terminate() // SIGTERM，openvpn 会优雅清理 tun
            // 兜底：5 秒后仍存活则强杀（root 属主进程可能无权限，尽力而为）
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak proc] in
                if let p = proc, p.isRunning {
                    p.terminate()
                }
            }
        }
        process = nil
    }

    // MARK: - openvpn management 接口

    /// 通过 management 接口发送命令（如 signal SIGTERM）
    /// openvpn 进程以 root 运行，普通用户无法直接 kill；
    /// management 监听 127.0.0.1:7505，通过 socket 让 openvpn 自行退出。
    private func sendManagementCommand(_ command: String) -> String? {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(7505).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        // 设置读取超时 3 秒
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        command.withCString { buf in
            _ = send(sock, buf, strlen(buf), 0)
        }

        // 读取响应（最多 8KB）
        var buffer = [UInt8](repeating: 0, count: 8192)
        var response = ""
        var received = 0
        while received < 8192 {
            let n = recv(sock, &buffer[received], 8192 - received, 0)
            if n <= 0 { break }
            received += n
            response += String(decoding: buffer[0..<received], as: UTF8.self)
            if response.contains("SUCCESS") || response.contains("ERROR") { break }
        }
        return response.isEmpty ? nil : response
    }

    /// openvpn 进程退出（无论何种原因）
    private func handleProcessExit() {
        guard !isHandlingExit else { return }
        isHandlingExit = true
        defer { isHandlingExit = false }

        process = nil
        cleanupAuthFile()

        // 手动断开：直接结束
        if manualDisconnect || !desiredConnected {
            status = .disconnected
            isWaitingRetry = false
            retryDeadline = nil
            return
        }

        // 自动重连
        guard autoReconnect else {
            status = .disconnected
            retryDeadline = nil
            lastEvent = L10n.tr("event.autoReconnectOff")
            loadLogTail()
            return
        }

        // VPN 引擎授权不可用（未授权/异常）时不再徒劳重连
        if engineAuth != .authorized {
            status = .disconnected
            retryDeadline = nil
            lastEvent = engineAuth.summary
            loadLogTail()
            return
        }

        // 已在等待重连中：refreshState 定时器会重复触发本方法，直接忽略
        guard !isWaitingRetry else { return }

        reconnectCount += 1
        status = .reconnecting(attempt: reconnectCount)
        lastEvent = L10n.tr("event.reconnectIn", Int(retryDelay))
        loadLogTail()
        isWaitingRetry = true
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        retryDeadline = Date().addingTimeInterval(retryDelay)
        retryTimer = Timer.scheduledTimer(withTimeInterval: retryDelay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.isWaitingRetry = false
            self.retryDeadline = nil
            guard self.desiredConnected, !self.manualDisconnect else { return }
            self.lastEvent = L10n.tr("event.reconnectNow")
            self.startVPNProcess()
        }
        retryDelay = min(retryDelay * 2, maxRetryDelay)
    }

    // MARK: - 隧道状态监控

    private func startMonitoring() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: monitorInterval, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
        RunLoop.main.add(statusTimer!, forMode: .common)
    }

    /// 秒级时钟：P1 改为代理到 TickProvider，保留兼容发布以便旧订阅过渡
    private func startClock() {
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.needsTick else { return }
            let now = Date()
            self.clock = now
            DispatchQueue.main.async {
                TickProvider.shared.setNow(now)
            }
        }
        RunLoop.main.add(clockTimer!, forMode: .common)
    }

    private func refreshState() {
        // 快照主线程状态，避免跨线程竞态
        let desired = desiredConnected
        let currentStatus = status
        let procRunning = process?.isRunning ?? false
        // 仅当需要探测路由时才开后台线程（避免每次都起线程）
        let needsRouteCheck = desired && procRunning
        guard needsRouteCheck else {
            // 无需路由探测，直接在主线程收敛状态
            if !desired {
                if currentStatus.isConnected || (currentStatus != .disconnected && currentStatus != .unconfigured) {
                    DispatchQueue.main.async { [weak self] in self?.status = .disconnected }
                }
            } else if !procRunning {
                DispatchQueue.main.async { [weak self] in self?.handleProcessExit() }
            }
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let hasRoute = self?.checkTunnelRoute() ?? false
            DispatchQueue.main.async { [weak self] in
                self?.applyRefresh(hasRoute: hasRoute, procRunning: procRunning, desired: desired, currentStatus: currentStatus)
            }
        }
    }

    private func applyRefresh(hasRoute: Bool, procRunning: Bool, desired: Bool, currentStatus: VPNStatus) {
        if desired {
            if procRunning && hasRoute {
                if status != .connected {
                    retryDelay = 5
                    retryDeadline = nil
                    status = .connected
                    connectedAt = Date()
                    lastEvent = L10n.tr("event.tunnelEstablished")
                    loadLogTail()
                }
            } else if procRunning && !hasRoute {
                if status != .connecting && !status.isConnected {
                    status = .connecting
                }
            } else if !procRunning {
                handleProcessExit()
            }
        } else {
            if status.isConnected || (status != .disconnected && status != .unconfigured) {
                status = .disconnected
            }
        }
    }

    /// 检查 VPN 内网路由是否建立（route-nopull + 静态路由 10.8/16 → utun）
    /// 注意：netstat 输出中路由为缩写格式 "10.8/16"，不是 "10.8.0.0/16"
    private func checkTunnelRoute() -> Bool {
        let output = runCommand("/usr/sbin/netstat", ["-rn", "-f", "inet"])
        guard output.contains(routePattern) else { return false }
        // 路由必须指向 utun 隧道接口
        return output.contains("utun")
    }

    // MARK: - 辅助

    private func runCommand(_ path: String, _ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    /// 执行一段 bash 命令并返回输出（用于 openvpn 探测）
    private func runShell(_ script: String) -> String {
        runCommand("/bin/bash", ["-c", script])
    }

    /// runner 启动失败时读取 stderr，写入日志并反映到事件行（不再吞错误）
    private func captureRunnerError(_ pipe: Pipe) {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }

        // 取第一行错误信息（去掉 ❌ 前缀）作事件
        if let firstLine = text.split(separator: "\n").first {
            let msg = String(firstLine).replacingOccurrences(of: "❌ ", with: "")
            lastEvent = msg
        }
        // 完整输出追加到日志文件，供「日志」查看
        if let handle = FileHandle(forWritingAtPath: logFile) {
            handle.seekToEndOfFile()
            handle.write(Data("\n[app] \(text)\n".utf8))
            try? handle.close()
        }
        loadLogTail()
    }

    private func cleanupAuthFile() {
        try? FileManager.default.removeItem(atPath: authFile)
    }

    private func loadLogTail() {
        guard let content = try? String(contentsOfFile: logFile, encoding: .utf8) else {
            logTail = "（暂无日志）"
            return
        }
        let lines = content.split(separator: "\n")
        let tail = lines.suffix(4).joined(separator: "\n")
        logTail = tail.isEmpty ? "（暂无日志）" : String(tail)
    }

    // MARK: - 格式化

    /// 距离下次自动重连的剩余秒数（倒计时显示）
    var retryRemaining: Int {
        guard let deadline = retryDeadline else { return 0 }
        return max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
    }

    func formattedDuration() -> String {
        guard let start = connectedAt else { return "--:--:--" }
        let elapsed = Int(Date().timeIntervalSince(start))
        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        let s = elapsed % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}