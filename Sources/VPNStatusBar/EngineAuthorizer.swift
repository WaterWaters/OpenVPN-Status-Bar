import Foundation
import os
import VPNStatusBarCore

/// 引擎授权：探测 / 安装 / 免密规则。
///
/// 从 `VPNManager` 里拆出的独立职责 —— 这一层只跟系统权限打交道：跑 `sudo -n`、
/// 读写 `/usr/local/vpnstatusbar` 与 `/etc/sudoers.d`（经 osascript 提权）、解析引擎版本。
/// 授权状态与界面文案仍由 `VPNManager` 持有并发布（回调式，和 `MgmtClient` 一致）。
final class EngineAuthorizer {
    /// 引擎稳定路径（app 移动/升级都不失效）
    let stablePath: String
    /// **启动包装脚本**的稳定路径 —— sudoers 免密只放行这一个脚本（v4 起，收严权限面）
    let wrapperPath: String
    /// app 内置的自包含 openvpn 路径（打包后是 Contents/Resources/openvpn）
    private let bundledPath: String?
    /// app 内置的包装脚本路径（打包后是 Contents/Resources/vpn-run.sh）
    private let bundledWrapperPath: String?

    private let log = Logger(subsystem: "io.vpnstatusbar", category: "engine")

    init(stablePath: String, wrapperPath: String, bundledPath: String?, bundledWrapperPath: String?) {
        self.stablePath = stablePath
        self.wrapperPath = wrapperPath
        self.bundledPath = bundledPath
        self.bundledWrapperPath = bundledWrapperPath
    }

    // MARK: - 探测

    /// 授权探测结果（状态 + 引擎版本 / 架构真值 + 是否还留着旧规则）
    struct ProbeResult {
        let state: EngineAuth
        let version: String?
        let arch: String?
        /// 仍存在「NOPASSWD 指向引擎二进制」的 v3 时代旧规则 → 需要重新授权切到包装脚本
        let legacyOwnRule: Bool
        /// v2 时代遗留的、指向别处 openvpn 的免密规则（非空时设置页提示清理）
        let legacyForeignRule: String?
    }

    /// 真·免密探测：以 `sudo -n` 直接运行包装脚本的 `status`（即 `openvpn --version`），退出码 0 才算免密可用。
    ///
    /// 不能用 `sudo -n -l <路径>` 判断：admin 组用户的 sudo 策略里有 `(ALL) ALL`（需密码），
    /// `-l` 只回答"是否有权运行"，对任何命令都返回 0 —— 会把"未授权"误判成"已授权"，
    /// 直到连接时才报 "sudo: a password is required"。
    /// 也不用 `-k`（会顺手清掉用户在终端里的 sudo 时间戳）：缓存命中时能跑通本身就说明
    /// "此刻免密可用"，不构成有害的假阳性；真失效时这里会失败，下面的策略列表再给出原因。
    ///
    /// `sudo -n -l` 只读列一次，两条遗留规则判断都复用它的输出（原来要拉 3–4 个进程）。
    func probe() -> ProbeResult {
        let listing = sudoPolicyListing() ?? ""
        let legacyOwn = SudoPolicy.hasNoPasswdRule(for: stablePath, in: listing)
        let foreign = SudoPolicy.firstForeignOpenVPNRule(in: listing, excluding: [stablePath, wrapperPath])

        // 包装脚本没装 = 还没授权过（或只有 v3 旧规则）
        guard FileManager.default.isExecutableFile(atPath: wrapperPath) else {
            return ProbeResult(state: .unauthorized, version: nil, arch: nil,
                               legacyOwnRule: legacyOwn, legacyForeignRule: foreign)
        }
        // 真·免密 + 引擎版本：让包装脚本打印 `openvpn --version`（见 vpn-run.sh 的 status 动作）
        let (status, output) = runCapturing("/usr/bin/sudo", ["-n", wrapperPath, "status"])
        if status == 0 {
            let parsed = OpenVPNSignature.parse(output)
            return ProbeResult(state: .authorized, version: parsed.version, arch: parsed.arch,
                               legacyOwnRule: legacyOwn, legacyForeignRule: foreign)
        }
        // 失败时用策略列表区分原因（列出策略不需要密码，也不依赖 sudo 的本地化错误文案）：
        // 规则在但跑不起来 → 引擎/脚本异常（该走"修复"）；规则不在 → 未授权（该走"授权"）
        let rulePresent = SudoPolicy.hasNoPasswdRule(for: wrapperPath, in: listing)
        return ProbeResult(state: rulePresent ? .broken : .unauthorized, version: nil, arch: nil,
                           legacyOwnRule: legacyOwn, legacyForeignRule: foreign)
    }

    // MARK: - 安装

    /// 以管理员权限完成：创建稳定目录 → 安装内置引擎 → 写入 /etc/sudoers.d 免密规则。
    /// 会弹一次系统管理员密码；用户取消返回 false。
    func install() -> Bool {
        guard let bundled = bundledPath,
              FileManager.default.fileExists(atPath: bundled) else {
            log.error("缺少内置引擎：bundledPath=\(self.bundledPath ?? "nil", privacy: .public)")
            return false
        }
        guard let bundledWrapper = bundledWrapperPath,
              FileManager.default.fileExists(atPath: bundledWrapper) else {
            log.error("缺少启动包装脚本：bundledWrapperPath=\(self.bundledWrapperPath ?? "nil", privacy: .public)")
            return false
        }
        let user = NSUserName()
        // 免密规则只放行包装脚本；它内部固定引擎路径、只接受 validate/start/stop/status 四个动作，
        // 并对配置做指令白名单校验（见 Support/vpn-run.sh 的文件头）
        let rule = "\(user) ALL=(root) NOPASSWD: \(wrapperPath)\n"
        let shell = """
        mkdir -p /usr/local/vpnstatusbar
        /bin/cp -f '\(bundled)' /usr/local/vpnstatusbar/openvpn
        /bin/chmod 755 /usr/local/vpnstatusbar/openvpn
        /bin/cp -f '\(bundledWrapper)' /usr/local/vpnstatusbar/vpn-run.sh
        /bin/chmod 755 /usr/local/vpnstatusbar/vpn-run.sh
        /usr/sbin/chown root:wheel /usr/local/vpnstatusbar/openvpn /usr/local/vpnstatusbar/vpn-run.sh
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
            let ok = proc.terminationStatus == 0
            log.notice("引擎安装\(ok ? "成功" : "失败/被取消", privacy: .public)")
            return ok
        } catch {
            log.error("osascript 启动失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - 命令执行

    /// `sudo -n -l` 只读列出当前用户的 sudo 策略（列策略本身不需要密码）；失败或无权限返回 nil
    private func sudoPolicyListing() -> String? {
        let (status, output) = runCapturing("/usr/bin/sudo", ["-n", "-l"])
        return status == 0 ? output : nil
    }

    /// 执行命令并同时取回退出码与输出（授权探测用，输出含 stderr）
    private func runCapturing(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, "")
        }
    }
}
