import Foundation
import Combine
import AppKit
import SwiftUI
import os
import VPNStatusBarCore

/// VPN 管理器：负责配置读写、连接/断开、隧道状态监控、断线自动重连
/// v2：不再依赖上一级文件夹的 *.ovpn / .user ——
///   配置在 app 内导入：ovpn 复制到 Application Support，密码存 Keychain，
///   连接时由 app 生成临时 auth 文件，经参数化 runner 启动 openvpn。
/// v2.1：openvpn 环境检测（路径探测 + sudo 免密授权校验），
///   未就绪时给出明确原因与修复命令（适配同事机器 brew 前缀/软链差异）。
/// 并发约定（写在这里是为了让后续改动有据可依）：
/// - 所有 `@Published`、定时器、进程句柄、本类的各种缓存**只在主线程读写**；
/// - 后台队列只做 I/O（Keychain IPC、sudo 探测、socket、读日志文件），算完的结果一律
///   `DispatchQueue.main.async` 回主线程再落到状态上；
/// - 少数确实要被两边访问的东西各自带锁：`Keychain`（cacheQueue）、`MgmtClient`（私有串行队列）、`mgmtLock`。
/// 改动时请保持这个形状：**不要**在后台闭包里直接改本类的属性。
final class VPNManager: ObservableObject {
    /// 同上：只在主线程访问
    nonisolated(unsafe) static let shared = VPNManager()

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

    /// legacy（v2 之前单文件时代）的配置路径：**仅在多档案索引还没建立时**才有效。
    /// 迁移时会保留 `config.ovpn` 以防回滚，但如果删光档案后还回退到它，
    /// 界面就会"复活"一份用户以为已删除的旧配置（并用旧凭据去连旧服务器）。
    private var legacyConfigPath: String? {
        store.hasIndex ? nil : "\(configDir)/config.ovpn"
    }

    /// 导入的 ovpn 配置（多配置：activeProfile 对应文件）
    var configPath: String {
        if let p = store.activeProfile() { return store.ovpnPath(for: p.id) }
        return legacyConfigPath ?? ""
    }
    /// 连接时临时生成的认证文件（0600，断开即删）
    private var authFile: String { "\(configDir)/.auth.tmp" }
    /// 本次连接的 management 接口密码文件（0600，断开即删；只传路径，密码本身不进 argv）
    private var mgmtPasswordFile: String { "\(configDir)/.mgmt.pw" }
    /// 日志文件（openvpn 输出，供面板展示）
    var logFile: String { "\(configDir)/vpn.log" }
    /// 状态机日志：log show --predicate 'subsystem == "io.vpnstatusbar"' --last 10m
    private let stateLog = Logger(subsystem: "io.vpnstatusbar", category: "vpnstate")
    /// management 接口串行锁：状态轮询与断开用的 SIGTERM 互斥（接口同时只服务一个客户端）
    private let mgmtLock = NSLock()

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

    /// 引擎稳定路径（授权时同步到此 —— 移动/升级 app 都不失效）
    private let engineStablePath = "/usr/local/vpnstatusbar/openvpn"
    /// 启动包装脚本的稳定路径：sudoers 只放行它（v4 起，权限面收严；见 Support/vpn-run.sh）
    private let engineWrapperPath = "/usr/local/vpnstatusbar/vpn-run.sh"

    /// 解析随 app 分发的支撑脚本：优先 app bundle 的 Resources；
    /// 开发态（swift run）向上找仓库里的 Support/ —— 产物布局变过多次，别再按固定层级推算
    private static func resolveSupportScript(named name: String) -> String? {
        if let inBundle = Bundle.main.resourceURL?.appendingPathComponent(name).path,
           FileManager.default.fileExists(atPath: inBundle) {
            return inBundle
        }
        var dir = Bundle.main.bundleURL
        for _ in 0..<6 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("Support/\(name)").path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }
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
        // 只有单文件时代的机器才允许走 legacy 回退（见 legacyConfigPath 的说明）
        guard let legacy = legacyConfigPath,
              FileManager.default.fileExists(atPath: legacy) else {
            cachedIsConfigured = false
            return false
        }
        let hasPwd = Keychain.loadPassword(account: keychainAccount) != nil
        cachedIsConfigured = hasPwd
        return hasPwd
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

    // MARK: - 启动脚本（参数化，优先使用 app 内置副本）

    private lazy var runnerScript: String = {
        if let found = Self.resolveSupportScript(named: "vpn-runner.sh") { return found }
        // 最后兜底：app 旁的常见位置（老布局）
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        let candidates = [
            parent.appendingPathComponent("vpn-runner.sh").path,
            parent.deletingLastPathComponent().appendingPathComponent("vpn-runner.sh").path,
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) { return c }
        return candidates[0]
    }()

    /// app 内置的包装脚本（授权时安装到 engineWrapperPath）
    private lazy var bundledWrapperPath: String? = Self.resolveSupportScript(named: "vpn-run.sh")

    // MARK: - 发布状态
    @Published var status: VPNStatus = .unconfigured {
        didSet {
            if oldValue != status {
                // 本次 connecting 起点：面板据此在超过阈值后给出「取消连接」入口
                if case .connecting = status { connectingSince = Date() } else { connectingSince = nil }
                stateLog.notice("status=\(String(describing: self.status), privacy: .public) from=\(String(describing: oldValue), privacy: .public)")
                switch status {
                case .connected:
                    NotificationService.notifyConnected(profile: profileName)
                case .disconnected:
                    if oldValue.isConnected || oldValue.isBusy { NotificationService.notifyDisconnected(profile: profileName) }
                case .reconnecting(let attempt) where attempt == 3:
                    // 只在本轮断线的第 3 次尝试提醒一次：attempt 每轮重连自增、间隔封顶 60s，
                    // 若按 >= 3 判断，通宵断网会累积上百条通知
                    NotificationService.notifyReconnectFailed(profile: profileName, attempt: attempt)
                default: break
                }
                // 状态类别变了：看门狗间隔/启停跟着变（busy 5s / 其余 30s / 空闲断开停表）
                updateWatchdog()
                // 秒级时钟只在"已连接 / 重连中"才有意义，其余状态别白醒
                updateTicker()
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
    /// VPN 引擎授权状态（连接前置校验 + 设置页展示）
    @Published private(set) var engineAuth: EngineAuth = .checking
    /// 引擎真实版本 / 架构（设置页展示真值，不再写死）
    @Published private(set) var engineVersion: String?
    @Published private(set) var engineArch: String?
    /// 检测到的 v2 时代遗留免密规则（如 /opt/homebrew/sbin/openvpn），非空时设置页提示清理
    @Published private(set) var legacyAuthRule: String?
    /// 仍是 v3 时代的旧规则（NOPASSWD 直指引擎二进制）→ 提示重新授权一次以切到包装脚本
    @Published private(set) var needsReauthorization = false
    /// 隧道本端地址（management `state` 报告的真值，连接后可用）
    @Published private(set) var tunnelLocalAddress: String?
    /// 实时流量（management `bytecount` 推送；面板可见时才订阅）。
    /// 单独一个 ObservableObject：1 Hz 的推送只让真正显示它的视图刷新，
    /// 不再每秒把整块面板 + 菜单栏 label 一起重绘（挂在 `@Published` 上会全量失效）。
    let trafficStore = TrafficStore()
    /// management 常驻连接是否处于推送中（用于面板显示与兜底轮询判断）
    @Published private(set) var mgmtStreaming = false
    /// 下一次自动重连的触发时刻（重连中用于倒计时显示）
    @Published private(set) var retryDeadline: Date?
    /// 本轮 connecting 的起始时刻（面板据此决定何时给出「取消连接」）
    @Published private(set) var connectingSince: Date?

    /// 用户意图：是否期望保持连接
    private var desiredConnected = false
    /// 是否为手动断开（避免触发自动重连）
    private var manualDisconnect = false
    /// 启动代次：丢弃上一次启动遗留的进程退出 / stderr / management 推送
    private var launch = LaunchTracker()

    /// management 常驻连接：openvpn 主动推送状态/流量，替代每 2 秒轮询
    private let mgmt = MgmtClient()
    /// 面板可见性订阅（1 秒时钟与流量推送按需开关）
    private var cancellables = Set<AnyCancellable>()
    /// 上一次流量采样（用于算速率）
    private var lastTrafficSample: TrafficSample?

    private var process: Process?
    private var statusTimer: Timer?
    private var retryTimer: Timer?
    private var retryDelay: TimeInterval = 5
    private let maxRetryDelay: TimeInterval = 60
    /// 防重入：terminationHandler 与定时器同时触发
    private var isHandlingExit = false
    /// 是否已处于等待重连状态（防止看门狗反复调度导致重连被无限推迟）
    private var isWaitingRetry = false
    /// 启动序列进行中（残留清理 + 拉起进程），期间不要把“进程还没起来”当成异常退出；
    /// 起点时间用于给收敛兜底一个宽限期（超过就当卡死处理）
    private var isStarting = false
    private var startingAt: Date?
    /// 授权探测进行中（同一时刻只拉一组 sudo；期间到来的请求排队复用同一个结果）
    private var isProbing = false
    private var probeWaiters: [(EngineAuthorizer.ProbeResult) -> Void] = []
    /// 引擎授权（探测/安装/规则）：与系统权限打交道的事都收在那里
    private lazy var engine = EngineAuthorizer(stablePath: engineStablePath,
                                               wrapperPath: engineWrapperPath,
                                               bundledPath: bundledEnginePath,
                                               bundledWrapperPath: bundledWrapperPath)
    /// 本轮断线区间内的重连次数：只用于状态文案与通知去重（成功连接后归零）
    private var outageAttempt = 0

    func refreshProfiles() {
        profiles = store.loadAll()
        cachedIsConfigured = nil
    }

    /// 切换档案：已连接时先断开再切，并按原意图自动连到新档案。
    /// 不这么做会出现“UI 显示新档案、隧道其实还是旧档案”的错位（2s 后状态还会翻回已连接、时长被重置）。
    func switchProfile(id: String) {
        guard store.activeId() != id else { return }
        let keepConnected = desiredConnected || status.isConnected || status.isBusy
        if keepConnected { disconnect() }
        store.setActiveId(id)
        refreshProfiles()
        // 切换后收敛状态
        status = isConfigured ? .disconnected : .unconfigured
        lastEvent = L10n.tr("event.profileSwitched", profileName)
        loadLogTail()
        if keepConnected { connect() }
    }

    /// 删除档案：删的是当前档案且隧道在用 → 先断开再删（配置/凭据删了隧道还在是最坏的一种状态）
    func deleteProfile(id: String) {
        let wasActive = store.activeId() == id
        if wasActive && (desiredConnected || status.isConnected || status.isBusy) {
            disconnect()
        }
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
        updateWatchdog()
        // management 常驻连接：推送状态/流量（回调在主线程）
        mgmt.onEvent = { [weak self] event, generation in
            self?.handleManagementEvent(event, generation: generation)
        }
        mgmt.onStateChange = { [weak self] state, generation in
            guard let self = self, self.launch.isCurrent(generation) else { return }
            self.mgmtStreaming = (state == .streaming)
        }
        // 网络路径变化（换 Wi-Fi / 唤醒）→ 立刻收敛，不再傻等退避倒计时
        NetworkMonitor.shared.onPathChange = { [weak self] in self?.handleNetworkPathChange() }
        // 面板可见性：只有人在看面板时才需要 1 秒时钟与流量推送；关掉面板两者归零
        PanelVisibility.shared.$isVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.mgmt.setBytecountInterval(visible ? 1 : 0)
                self?.updateTicker()
            }
            .store(in: &cancellables)
        // 首次日志读取（后台读文件、主线程发布，不挡启动）
        loadLogTail()
        // 引擎授权延迟 300ms，缓存 60s 内结果
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshEngineAuth()
        }
        // 后台校验真实 isConfigured（文件存在但 Keychain 缺失的边界）。
        // 后台只负责把 Keychain 的值取进缓存（真正的 IPC 成本在那里），判断与缓存写入都回主线程做 ——
        // 早期版本在后台闭包里直接读 `isConfigured`，会跨线程读写本类缓存（严格并发标出的真实竞态）。
        let accountForCheck = activeKeychainAccount
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Keychain.loadPassword(account: accountForCheck)
            DispatchQueue.main.async {
                self.cachedIsConfigured = nil          // 让 getter 重新判断（此时 Keychain 已命中缓存）
                let real = self.isConfigured
                if !real && self.status == .disconnected && quickConfigured {
                    self.status = .unconfigured
                    self.lastEvent = L10n.tr("event.noProfile")
                }
            }
        }
    }

    /// 面板展示用的日志窗口（只读文件末尾，不再整读最多 512 KB）
    private static let displayTailBytes = 16 * 1024
    /// 判定凭据错误用的窗口：比展示窗口宽，够覆盖一次正常会话；真超出时回落整文件读
    private static let verdictTailBytes = 64 * 1024

    /// 本次会话的日志：日志为追加模式，按会话分隔行切片，
    /// 历史会话里的 AUTH_FAILED 不能触发本次的“停止重连”判定。
    /// 先只读末尾窗口（命中分隔行即可判定）；窗口被截断且没有分隔行时才整文件读一次（罕见）。
    private func currentLogText() -> String {
        let tail = LogFile.tail(atPath: logFile, maxBytes: Self.verdictTailBytes)
        if let session = OpenVPNLog.currentSessionFromTail(tail.text, tailIsWholeFile: tail.isWholeFile) {
            return session
        }
        return LogFile.whole(atPath: logFile) ?? tail.text
    }

    /// 日志超过 maxBytes 时保留末尾一半（追加模式下的自保，避免文件无限增长）
    /// 注：按 Character 截取，保证切出来的内容仍是合法 UTF-8（按字节切会切断多字节字符）。
    /// 静态且只碰文件：调用点在后台队列上（见 prepareAndStart），不在主线程做整文件读写。
    private static func rotateLogIfNeeded(atPath path: String) {
        let maxBytes = 512 * 1024
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size > maxBytes,
              let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let kept = String(content.suffix(maxBytes / 2))
        try? kept.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    }

    /// 日志末尾 4 行（面板展示用）；文件缺失或为空时给本地化占位文案。
    /// 纯字符串处理，可后台执行；文件读取由调用方负责。
    private static func logTailText(from tail: LogFile.Tail) -> String {
        let lines = tail.text.split(separator: "\n").suffix(4).joined(separator: "\n")
        return lines.isEmpty ? L10n.tr("log.empty") : String(lines)
    }

    // MARK: - VPN 引擎授权（具体动作见 EngineAuthorizer）

    /// 触发引擎授权检测（异步，完成后发布 engineAuth / 版本 / 架构 / 遗留规则）
    func refreshEngineAuth() {
        probeEngine { _ in }
    }

    /// 探测（合并）：同一时刻只有一个探测在飞，期间的请求排进 waiter，
    /// 结果一次发布、一次回调。避免"启动探测"与"点连接时补探测"并发拉起两组 sudo。
    private func probeEngine(_ completion: @escaping (EngineAuthorizer.ProbeResult) -> Void) {
        probeWaiters.append(completion)
        guard !isProbing else { return }
        isProbing = true
        if engineAuth != .checking { engineAuth = .checking }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = self.engine.probe()
            DispatchQueue.main.async {
                self.isProbing = false
                self.applyProbe(result)
                let waiters = self.probeWaiters
                self.probeWaiters.removeAll()
                waiters.forEach { $0(result) }
            }
        }
    }

    /// 发布探测结果（先发布、再唤醒 waiter：waiter 里可能立刻调用 connect()）
    private func applyProbe(_ result: EngineAuthorizer.ProbeResult) {
        let previous = engineAuth
        engineAuth = result.state
        engineVersion = result.version
        engineArch = result.arch
        legacyAuthRule = result.legacyForeignRule
        needsReauthorization = result.legacyOwnRule
        // 只在"刚检测完 / 刚授权完"时覆盖事件行，避免把连接过程里的事件顶掉
        if result.state == .authorized, previous == .checking || previous == .authorizing {
            lastEvent = L10n.tr("event.engineAuthorized")
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
            let ok = self.engine.install()
            DispatchQueue.main.async {
                self.lastEvent = ok ? L10n.tr("event.engineAuthorized") : L10n.tr("event.authCancelled")
                self.refreshEngineAuth()
            }
        }
    }

    // MARK: - 配置读写（v2）

    /// 保存配置：ovpn 内容复制到 Application Support，用户名存档案，密码存 Keychain
    /// - Parameters:
    ///   - ovpnData: 导入 / 编辑后的 ovpn 内容
    ///   - fileName: 原始文件名（记录显示用）
    ///   - username: 鉴权用户名
    ///   - password: 鉴权密码（nil 表示保持原有密码）
    ///   - targetProfileId: 编辑模式传目标档案 id（原地更新）；nil 表示新建档案
    func saveConfig(ovpnData: Data, fileName: String, username: String, password: String?, targetProfileId: String?) {
        // 编辑模式由调用方显式指定目标档案，不再用“用户名是否变化”反推用户意图
        // （用户名与密码同时修改时那个判定会误算成新增，产生重复档案）
        if let id = targetProfileId, let active = profiles.first(where: { $0.id == id }) {
            try? ovpnData.write(to: URL(fileURLWithPath: store.ovpnPath(for: active.id)), options: .atomic)
            var updated = active
            updated.fileName = fileName
            updated.name = (fileName as NSString).deletingPathExtension
            updated.username = username
            updated.serverAddress = VPNProfile.parseServerAddress(from: String(data: ovpnData, encoding: .utf8) ?? "")
            updated.updatedAt = Date()
            store.update(updated)
            if let pwd = password, !pwd.isEmpty {
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

    /// 指定档案的 ovpn 内容（编辑模式下未重新选文件时复用 → 改用户名/密码不必重选文件）
    func profileOvpnData(id: String) -> (data: Data, fileName: String)? {
        guard let p = profiles.first(where: { $0.id == id }),
              let data = try? Data(contentsOf: URL(fileURLWithPath: store.ovpnPath(for: p.id))) else { return nil }
        return (data, p.fileName)
    }

    /// 清除配置（多配置：删除当前档案；兼容旧单文件）
    func clearConfig() {
        let fm = FileManager.default
        manualDisconnect = true
        desiredConnected = false
        launch.invalidate()
        signalTerminateSync()
        mgmt.stop()
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

        status = isConfigured ? .disconnected : .unconfigured
        lastEvent = profiles.isEmpty ? L10n.tr("event.profileCleared") : L10n.tr("event.profileDeleted")
        loadLogTail()
        updateWatchdog()
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
            // 探测还没出结果：等结果再继续，而不是把这次点击吞掉（首次连接/刚启动时最常见）
            awaitEngineAuthThenConnect()
            return
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
        outageAttempt = 0
        retryDelay = 5
        retryDeadline = nil
        lastEvent = L10n.tr("event.connecting")
        prepareAndStart()
    }

    /// 授权探测未完成时：等结果，已授权就继续这次连接意图
    private func awaitEngineAuthThenConnect() {
        lastEvent = L10n.tr("event.engineChecking")
        probeEngine { [weak self] result in
            guard let self = self else { return }
            switch result.state {
            case .authorized:
                // 并发点击/已有意图时只连一次
                if !self.desiredConnected { self.connect() }
            case .unauthorized:
                self.lastEvent = L10n.tr("event.engineUnauthorized")
                self.status = .disconnected
            case .broken:
                self.lastEvent = L10n.tr("event.engineBroken")
                self.status = .disconnected
            default:
                self.lastEvent = L10n.tr("event.engineChecking")
                self.status = .disconnected
            }
        }
    }

    /// 重连等待中立即重连（跳过剩余倒计时）
    func reconnectNow() {
        guard case .reconnecting = status else { return }
        lastEvent = L10n.tr("event.reconnectNow")
        prepareAndStart()
    }

    /// 启动序列：先等旧实例让出 management 端口（否则新实例绑定会失败），再拉起进程。
    /// 整段放在后台 —— 等待最长 3 秒，放主线程会把面板冻住。
    private func prepareAndStart() {
        retryTimer?.invalidate()
        retryTimer = nil
        retryDeadline = nil
        isWaitingRetry = false
        if status != .connected { status = .connecting }
        isStarting = true
        startingAt = Date()
        // 从此刻起，旧进程的退出事件、旧 management 流的推送一律作废：
        // 下面的"等端口释放"可能持续几秒，期间旧进程退出不能触发自动重连
        //（否则新隧道连上约 5 秒后会被无谓掐断重连一次 —— 切配置时最明显）。
        launch.invalidate()
        // 先同步断开常驻推送：它占着 management 接口（同时只服务一个客户端），
        // 不释放的话下面探测残留实例会连不上。
        mgmt.stopAndWait()
        let logPath = logFile
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let hadStale = self.waitForManagementPortFree()
            // 日志轮转（整文件读 + 写回）挪到后台，且发生在任何进程拉起之前，不会和 runner 抢文件
            Self.rotateLogIfNeeded(atPath: logPath)
            DispatchQueue.main.async {
                self.isStarting = false
                self.startingAt = nil
                guard self.desiredConnected, !self.manualDisconnect else {
                    // 等待期间用户改主意了（取消/断开）：不能把 .connecting 留在界面上
                    self.convergeToDisconnected(reason: "启动前用户已取消")
                    return
                }
                if hadStale { self.lastEvent = L10n.tr("event.foundStale") }
                self.startVPNProcess()
            }
        }
    }

    /// 断开 VPN（不触发自动重连）
    func disconnect() {
        guard isConfigured else {
            status = .unconfigured
            return
        }
        manualDisconnect = true
        desiredConnected = false
        // 主动断开：旧进程退出事件从此作废，否则它会被当成"隧道意外断开"再触发重连
        launch.invalidate()
        retryTimer?.invalidate()
        retryTimer = nil
        retryDeadline = nil
        isWaitingRetry = false
        tunnelLocalAddress = nil
        trafficStore.update(rate: nil)
        lastTrafficSample = nil
        status = .disconnected
        lastEvent = L10n.tr("event.disconnecting")
        // 优先通过 openvpn management 接口优雅退出（无需 root 权限）。
        // 不在主线程等回执：走流时立即返回，走一次性连接时交给后台（最长 3 秒，不能冻住面板）。
        signalTerminateAsync()
        // 兜底：直接终止进程（对 root 属主进程可能因权限失败，尽力而为）
        terminateProcess()
        mgmt.stop()
        process = nil
        cleanupAuthFile()
        loadLogTail()
        lastEvent = L10n.tr("event.disconnectedManual")
        updateWatchdog()      // 进程已收掉：空闲断开要停表，别再常驻唤醒
    }

    /// 退出前清理
    func shutdown() {
        retryTimer?.invalidate()
        statusTimer?.invalidate()
        manualDisconnect = true
        desiredConnected = false
        launch.invalidate()
        // 退出路径允许阻塞（≤3 秒）：必须确保进程被收掉，不能"发完就走"
        signalTerminateSync()
        mgmt.stop()
        terminateProcess()
        cleanupAuthFile()
    }

    // MARK: - 启动 / 停止 openvpn 进程

    private func startVPNProcess() {
        retryTimer?.invalidate()
        retryTimer = nil
        isWaitingRetry = false
        cleanupAuthFile()
        // 本次启动的代次：进程退出、stderr、management 推送都带着它回来
        let generation = launch.begin()

        // 由 app 生成 auth 文件（用户名 + Keychain 密码），0600 权限
        guard writeAuthFile() else {
            lastEvent = L10n.tr("event.authFailed")
            status = .disconnected
            return
        }

        // management 接口密码：每次连接随机生成、只落在 0600 文件里（同机其他用户无法对隧道发 SIGTERM）。
        // 写失败就不带密码（退回旧行为），不影响连接本身。
        let mgmtPassword = Self.randomPassword()
        let hasMgmtPassword = (try? mgmtPassword.write(toFile: mgmtPasswordFile, atomically: true, encoding: .utf8)) != nil
            && (try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mgmtPasswordFile)) != nil

        // 日志：超限轮转已在 prepareAndStart 的后台块里做过；本次启动会写一行会话分隔记录（runner 负责写入），
        // 日志是追加模式，断线后仍能回看之前几次发生了什么
        let note = OpenVPNLog.sessionNote(date: Date(), attempt: outageAttempt + 1, profile: profileName)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        // 参数化调用：runner 不再读取同目录 .ovpn/.user
        proc.arguments = [
            runnerScript,
            // 不再传 --openvpn：引擎路径由 root 属主包装脚本固定（权限面收严）
            "--ovpn", configPath,
            "--auth", authFile,
            "--log", logFile,
            "--session-note", note,
        ]
        if hasMgmtPassword {
            proc.arguments?.append(contentsOf: ["--mgmt-password-file", mgmtPasswordFile])
        }
        proc.standardOutput = FileHandle.nullDevice
        // 捕获 stderr：runner 探测/权限失败时给出可读原因（写入日志 + 事件行）
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.terminationHandler = { [weak self] _ in
            // 后台线程：先把管道抽干 —— 否则子进程（openvpn）往 stderr 写满 64 KB 会永久阻塞
            let stderrText = Self.drainText(errPipe, limit: 8192)
            DispatchQueue.main.async {
                guard let self = self, self.launch.isCurrent(generation) else { return }
                self.applyRunnerError(stderrText)
                self.handleProcessExit()
            }
        }

        do {
            try proc.run()
            process = proc
            updateWatchdog()        // 进程出现了：看门狗间隔/启停跟着重算
            if status != .connected {
                status = .connecting
            }
            lastEvent = L10n.tr("event.openvpnStarted")
            // 常驻推送：openvpn 绑定 management 端口略晚于进程启动，客户端会自己重试
            mgmt.start(password: hasMgmtPassword ? mgmtPassword : nil, generation: generation)
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
        // 目标进程以 root 运行（runner 内部 exec sudo），非 root 发信号会被拒绝 ——
        // 真正生效的是 management 通道的 SIGTERM，这里只作尽力而为，不假装“强杀”。
        if proc.isRunning { proc.terminate() }
        process = nil
    }

    // MARK: - openvpn management 接口

    /// **一次性** management 连接（发一条命令、读回执、断开）。
    /// 常驻推送由 `MgmtClient` 负责；这里只在推送未建立时兜底
    /// （例如启动前的残留实例探测、或流断开时的 SIGTERM）。
    /// openvpn 进程以 root 运行、普通用户无法直接 kill，management 通道是让 openvpn 自行退出的唯一途径。
    private func sendOneShotCommand(_ command: String) -> String? {
        mgmtLock.lock()
        defer { mgmtLock.unlock() }

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = ManagementProtocol.port.bigEndian
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
            // SUCCESS/ERROR 是命令类回执的结尾，END 是 state 等查询类命令的结尾
            if response.contains("SUCCESS") || response.contains("ERROR") || response.contains("END") { break }
        }
        return response.isEmpty ? nil : response
    }

    /// 查询 openvpn 报告的隧道状态与地址（一次性 `state` 查询）
    /// 仅用作兜底：常驻推送（MgmtClient）正常时状态由 `>STATE:` 驱动，不需要轮询。
    /// 返回 nil 表示查询失败（接口尚未监听 / 被别的客户端占用），调用方应保持当前状态而非误判
    private func queryTunnelInfo() -> TunnelInfo? {
        guard let resp = sendOneShotCommand("state\n") else { return nil }
        let info = OpenVPNMgmt.parseInfo(resp)
        return info.state == .unknown ? nil : info
    }

    /// 停止隧道（断开路径）：有常驻流就走流，没有流时把一次性连接丢到后台。
    /// 不在主线程等回执 —— 接口卡住时会阻塞最长 3 秒（面板跟着冻住）。
    private func signalTerminateAsync() {
        if mgmt.isStreaming {
            mgmt.send(ManagementProtocol.terminateCommand)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.sendOneShotCommand(ManagementProtocol.terminateCommand)
        }
    }

    /// 停止隧道（退出路径）：允许阻塞，确保 SIGTERM 真的发出去。
    /// 返回是否至少把 SIGTERM 发出去了。
    @discardableResult
    private func signalTerminateSync() -> Bool {
        if mgmt.isStreaming {
            mgmt.send(ManagementProtocol.terminateCommand)
            return true
        }
        return sendOneShotCommand(ManagementProtocol.terminateCommand) != nil
    }

    /// 等旧实例让出 management 端口，再允许拉起新进程。
    ///
    /// 为什么用"端口是否释放"而不是固定睡眠：端口是 openvpn 生存期内独占的资源，
    /// 也是新实例启动时会绑定的同一个资源 —— 它释放了才说明可以启动。
    /// 健康路径（从没跑过 openvpn / 已经退干净）第一次探测就会失败并立即返回，不引入额外延迟。
    /// - Returns: 是否曾发现残留实例（用于事件行提示）
    private func waitForManagementPortFree(timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var sawStale = false
        while Date() < deadline {
            // 连不上 = 端口已释放（或本来就没人监听）→ 可以启动
            guard sendOneShotCommand(ManagementProtocol.terminateCommand) != nil else { return sawStale }
            sawStale = true
            Thread.sleep(forTimeInterval: 0.1)
        }
        if sawStale {
            stateLog.notice("旧实例在 \(timeout, privacy: .public)s 内未让出 management 端口，继续启动")
        }
        return sawStale
    }

    /// 网络可用性变化（主线程回调）：只在"期望连接但没连上"时立刻重试。
    /// 严格不绕过既有停止条件：凭据错误停下（desiredConnected=false）、自动重连关闭、
    /// 引擎未授权 —— 一律不动；正在连接中的进程也不打断（openvpn 自己会重试）。
    private func handleNetworkPathChange() {
        guard desiredConnected, !manualDisconnect else { return }
        guard status == .disconnected || isWaitingRetry else { return }
        guard autoReconnect, engineAuth == .authorized else { return }
        lastEvent = L10n.tr("event.networkChanged")
        prepareAndStart()
    }

    /// management 推送事件（主线程回调）
    private func handleManagementEvent(_ event: ManagementEvent, generation: UInt64) {
        // 上一次启动遗留的推送（含断流后仍在队列里的那几条）不能在本次启动里生效
        guard launch.isCurrent(generation) else { return }
        switch event {
        case .state(let info):
            // 推送的状态直接喂给既有状态机（与轮询走同一条收敛路径）
            applyRefresh(tunnelInfo: info,
                         procRunning: process?.isRunning ?? false,
                         desired: desiredConnected,
                         currentStatus: status)
        case .bytecount(let rx, let tx):
            let sample = TrafficSample(bytesIn: rx, bytesOut: tx, at: Date())
            if let previous = lastTrafficSample, let rate = TrafficCalculator.rate(from: previous, to: sample) {
                trafficStore.update(rate: rate)
            } else {
                // 首个采样、或计数器重置（重连）→ 先只给累计值，速率为 0
                trafficStore.update(rate: TrafficRate(bytesInPerSecond: 0, bytesOutPerSecond: 0,
                                                      totalIn: sample.bytesIn, totalOut: sample.bytesOut))
            }
            lastTrafficSample = sample
        case .reply(.error(let text)):
            stateLog.notice("management 回执错误：\(text, privacy: .public)")
        default:
            break
        }
    }

    /// openvpn 进程退出（无论何种原因）
    private func handleProcessExit() {
        guard !isHandlingExit else { return }
        isHandlingExit = true
        defer { isHandlingExit = false }

        process = nil
        updateWatchdog()
        cleanupAuthFile()
        tunnelLocalAddress = nil
        trafficStore.update(rate: nil)
        lastTrafficSample = nil
        mgmt.stop()

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

        // 凭据错误（AUTH_FAILED）时继续重连没有意义：停止本轮自动重连并给出可操作的提示
        // （只看本次会话段，历史会话的同名字样不会误触发）
        if OpenVPNLog.indicatesAuthFailure(in: currentLogText()) {
            retryTimer?.invalidate()
            retryTimer = nil
            retryDeadline = nil
            isWaitingRetry = false
            desiredConnected = false
            status = .disconnected
            lastEvent = L10n.tr("event.authFailedCreds")
            loadLogTail()
            return
        }

        // 已在等待重连中：refreshState 定时器会重复触发本方法，直接忽略
        guard !isWaitingRetry else { return }

        reconnectCount += 1
        outageAttempt += 1
        status = .reconnecting(attempt: outageAttempt)
        lastEvent = L10n.tr("event.reconnectIn", Int(retryDelay))
        loadLogTail()
        isWaitingRetry = true
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        retryDeadline = Date().addingTimeInterval(retryDelay)
        let timer = Timer.scheduledTimer(withTimeInterval: retryDelay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.isWaitingRetry = false
            self.retryDeadline = nil
            guard self.desiredConnected, !self.manualDisconnect else {
                self.updateWatchdog()
                return
            }
            self.lastEvent = L10n.tr("event.reconnectNow")
            self.prepareAndStart()
        }
        timer.tolerance = min(1.0, retryDelay / 10)     // 重连晚个零点几秒无所谓，换系统合并唤醒
        // 必须进 .common：默认 run-loop 模式在 modal 循环（例如向导里打开文件选择面板）期间不触发，
        // 那会让"等待重连"永远等不到 —— 真机死状态的一条成因。
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
        retryDelay = min(retryDelay * 2, maxRetryDelay)
    }

    // MARK: - 隧道状态监控（看门狗）

    /// 看门狗按需启停：只在「有东西需要收敛」时开表。
    /// - busy（连接中/重连中）→ 5 秒：卡死状态要尽快被收敛兜底修回来；
    /// - 在跑或期望在跑（含已连接）→ 30 秒：状态本来就由 management 推送驱动，这里只兜"进程挂死且不再推送"；
    /// - 空闲断开 → 完全停表：这是菜单栏 app 最常见的状态，不该有常驻唤醒
    ///   （原来是 5 秒一次的常驻表，等于每小时 720 次唤醒，且 99% 的时间什么也不做）。
    private func updateWatchdog() {
        let interval = WatchdogPolicy.interval(status: status, desired: desiredConnected, hasProcess: process != nil)
        guard let interval else {
            statusTimer?.invalidate()
            statusTimer = nil
            return
        }
        if let timer = statusTimer, timer.timeInterval == interval { return }   // 间隔没变就别重启
        statusTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
        timer.tolerance = interval / 4      // 让系统合并唤醒；状态精度由 management 推送保证
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    /// 秒级时钟按需启停：面板可见 **且** 当前状态确实有时长/倒计时可显示。
    /// 面板开着但已断开时不再有 1 Hz 唤醒（那正是菜单栏 app 最常见的状态）。
    private func updateTicker() {
        TickProvider.shared.setActive(PanelVisibility.shared.isVisible && status.needsClock)
    }

    private func refreshState() {
        // 快照主线程状态，避免跨线程竞态
        let desired = desiredConnected
        let currentStatus = status
        let procRunning = process?.isRunning ?? false

        // 1) 收敛兜底：busy 但「没进程 / 没在启动 / 没有已武装的重试」= 卡死。
        //    真机出现过这种状态（一直"重连中"、无隧道、无重试、菜单栏图标一直呼吸且 9% CPU）：
        //    以前这里会在 isWaitingRetry 上直接 return，于是永不恢复。
        let verdict = TunnelConvergence.verdict(TunnelConvergenceInput(
            status: currentStatus,
            desired: desired,
            hasProcess: procRunning,
            isStarting: isStarting,
            secondsSinceStart: startingAt.map { Date().timeIntervalSince($0) } ?? 0,
            isWaitingRetry: isWaitingRetry,
            retryArmed: retryTimer != nil,
            autoReconnect: autoReconnect,
            engineAuthorized: engineAuth == .authorized
        ))
        switch verdict {
        case .forceDisconnected:
            convergeToDisconnected(reason: "状态与在飞的动作不一致")
            return
        case .scheduleRetry:
            stateLog.notice("收敛兜底：busy 状态没有在飞的动作，补一次重试")
            isWaitingRetry = false      // 清掉可能卡住的等待标记，让 handleProcessExit 走完整路径
            handleProcessExit()
            return
        case .none:
            break
        }

        // 2) 推送不可用时才做一次性查询（常驻推送正常时状态由 >STATE: 驱动，不需要轮询）
        let needsTunnelQuery = desired && procRunning && !mgmt.isStreaming
        guard needsTunnelQuery else { return }
        let generation = launch.current
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let tunnelInfo = self?.queryTunnelInfo()
            DispatchQueue.main.async { [weak self] in
                // 查询期间用户可能已经开始下一次启动：结果已过期，不能拿它推进状态
                guard let self = self, self.launch.isCurrent(generation) else { return }
                self.applyRefresh(tunnelInfo: tunnelInfo, procRunning: procRunning, desired: desired, currentStatus: currentStatus)
            }
        }
    }

    /// 收敛到「已断开」：清掉等待/重试标记、停表，并在有必要时收掉残留进程。
    /// 只维护状态与计时器，**不改 `desiredConnected`**（用户意图由 connect/disconnect 负责），
    /// 否则会把"用户还想连"的语义弄丢、让重连彻底停摆。
    private func convergeToDisconnected(reason: String) {
        // 收敛即主动中断：残留进程随后的退出事件不得再触发重连
        launch.invalidate()
        retryTimer?.invalidate()
        retryTimer = nil
        retryDeadline = nil
        isWaitingRetry = false
        startingAt = nil
        if process != nil {
            terminateProcess()
            cleanupAuthFile()
            mgmt.stop()
            tunnelLocalAddress = nil
            trafficStore.update(rate: nil)
            lastTrafficSample = nil
        }
        if status != .disconnected { status = .disconnected }
        stateLog.notice("收敛兜底：\(reason, privacy: .public) → disconnected")
        updateWatchdog()
    }

    private func applyRefresh(tunnelInfo: TunnelInfo?, procRunning: Bool, desired: Bool, currentStatus: VPNStatus) {
        if desired {
            if procRunning, let tunnelInfo {
                tunnelLocalAddress = tunnelInfo.localAddress
                if tunnelInfo.state.isConnected {
                    if status != .connected {
                        retryDelay = 5
                        retryDeadline = nil
                        outageAttempt = 0
                        status = .connected
                        connectedAt = Date()
                        lastEvent = L10n.tr("event.tunnelEstablished")
                        loadLogTail()
                    }
                } else if status != .connecting && !status.isConnected {
                    status = .connecting
                }
            } else if !procRunning {
                handleProcessExit()
            }
            // tunnelInfo == nil：管理接口查询失败，保持当前状态（进程存活即不误判为断开）
        } else {
            tunnelLocalAddress = nil
            if status.isConnected || (status != .disconnected && status != .unconfigured) {
                status = .disconnected
            }
        }
    }

    // MARK: - 辅助

    /// 后台线程：抽干 stderr 管道（限长，避免异常输出撑爆日志/内存）
    private static func drainText(_ pipe: Pipe, limit: Int) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard var text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return "" }
        if text.count > limit { text = String(text.prefix(limit)) + "…" }
        return text
    }

    /// 主线程：runner 启动失败的 stderr 反映到事件行并追加进日志（不再吞错误）
    private func applyRunnerError(_ text: String) {
        guard !text.isEmpty else { return }
        // 取第一行错误信息（去掉 ❌ 前缀）作事件
        if let firstLine = text.split(separator: "\n").first {
            lastEvent = String(firstLine).replacingOccurrences(of: "❌ ", with: "")
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
        try? FileManager.default.removeItem(atPath: mgmtPasswordFile)
    }

    /// management 接口密码（随机 hex；不进命令行参数、不落明文日志）
    private static func randomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// 刷新面板展示的日志末尾：后台只读文件末尾窗口，算好文案后回主线程发布。
    /// （以前每次状态变化都在主线程整读最多 512 KB 日志，重连循环里每轮还会读两遍）
    private func loadLogTail() {
        let path = logFile
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let tail = LogFile.tail(atPath: path, maxBytes: Self.displayTailBytes)
            let text = Self.logTailText(from: tail)
            DispatchQueue.main.async { self?.logTail = text }
        }
    }

    // MARK: - 格式化
}