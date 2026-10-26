import Foundation

/// openvpn 自己报告的隧道状态（纯逻辑，可单元测试）
public enum TunnelState: Equatable, Sendable {
    case connected
    case connecting
    case reconnecting
    case disconnected
    case unknown

    /// 隧道已真正建立（openvpn 完成 TLS / ifconfig / 路由下发）
    public var isConnected: Bool { self == .connected }
}

/// management 接口 `state` 报告的一条状态（含地址信息，供面板展示真实数据而非硬编码）
public struct TunnelInfo: Equatable, Sendable {
    public var state: TunnelState
    /// 隧道本端地址（connected 后由服务端下发，如 10.8.0.24）
    public var localAddress: String?
    /// 对端地址（host:port）
    public var remote: String?

    public init(state: TunnelState, localAddress: String? = nil, remote: String? = nil) {
        self.state = state
        self.localAddress = localAddress
        self.remote = remote
    }
}

/// openvpn management 接口 `state` 命令的响应解析
public enum OpenVPNMgmt {
    /// 解析 `state` 命令响应，取最后一个可识别的状态行。
    ///
    /// 典型响应（首行是本机 banner，末行是结束标记）：
    ///     >INFO:OpenVPN Management Interface Version 5 -- type 'help' for more info
    ///     1791602229,CONNECTED,SUCCESS,10.8.0.24,183.222.16.242,7777,,
    ///     END
    ///
    /// 字段：时间戳,状态名,事件,本地 IP,远端 IP,远端端口,本地端口
    /// 状态名取值：CONNECTING / WAIT / AUTH / GET_CONFIG / ASSIGN_IP / ADD_ROUTES /
    ///            CONNECTED / RECONNECTING / DISCONNECTED / EXITING
    ///
    /// 注意：management 接口按 CRLF 换行，而 Swift 里 "\r\n" 是单个 Character
    /// （扩展字形簇），用 split(separator: "\n") 切不开 —— 必须按 isNewline 切。
    public static func parseState(_ response: String) -> TunnelState {
        parseInfo(response).state
    }

    /// 同 `parseState`，但一并取出本端/对端地址（未连接时为空）
    public static func parseInfo(_ response: String) -> TunnelInfo {
        for line in response.split(whereSeparator: \.isNewline).reversed() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            // 时间戳必须是数字，借此滤掉 banner / END / 命令回执等非状态行
            guard fields.count >= 2, Int(fields[0].trimmingCharacters(in: .whitespaces)) != nil else { continue }
            guard let state = state(named: fields[1].trimmingCharacters(in: .whitespaces).uppercased()) else {
                continue // 未知状态名（将来新增）不作猜测
            }
            var info = TunnelInfo(state: state)
            if fields.count >= 4 {
                let local = fields[3].trimmingCharacters(in: .whitespaces)
                if !local.isEmpty { info.localAddress = local }
            }
            if fields.count >= 6 {
                let host = fields[4].trimmingCharacters(in: .whitespaces)
                let port = fields[5].trimmingCharacters(in: .whitespaces)
                if !host.isEmpty { info.remote = port.isEmpty ? host : "\(host):\(port)" }
            }
            return info
        }
        return TunnelInfo(state: .unknown)
    }

    private static func state(named name: String) -> TunnelState? {
        switch name {
        case "CONNECTED": return .connected
        case "RECONNECTING": return .reconnecting
        case "DISCONNECTED", "EXITING": return .disconnected
        case "CONNECTING", "WAIT", "AUTH", "GET_CONFIG", "ASSIGN_IP", "ADD_ROUTES": return .connecting
        default: return nil
        }
    }
}

/// openvpn 日志判读（纯字符串逻辑：“凭据错了就别再徒劳重连”依赖它）
public enum OpenVPNLog {
    /// 会话分隔行前缀：日志改为追加模式后，用它定位「本次会话」——
    /// 判定凭据错误只能看本次启动之后的日志，历史会话里的 AUTH_FAILED 不能误触发。
    public static let sessionMarker = "===== [vpnstatusbar] session start"

    /// 日志里出现这些字样即认证失败（用户名/密码错），继续重连没有意义
    private static let authFailureMarkers = [
        "auth_failed",
        "auth-failure",
        "authentication failed",
        "cannot authenticate",
    ]

    /// 生成会话分隔行（app 每次拉起 openvpn 前交给 runner 写入日志，事后可按会话查阅）
    public static func sessionNote(date: Date, attempt: Int, profile: String) -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
        return "\(sessionMarker) \(stamp) attempt=\(attempt) profile=\(profile) ====="
    }

    /// 取最后一个会话分隔行之后的日志；没有分隔行（老日志/手工脚本写的日志）时返回全文
    public static func currentSession(in log: String) -> String {
        guard let last = log.range(of: sessionMarker, options: .backwards) else { return log }
        return String(log[last.lowerBound...])
    }

    /// 从「文件末尾窗口」的日志文本里取本次会话切片（app 侧只读尾部若干 KB，不再整读最多 512 KB）。
    ///
    /// 与 `currentSession(in:)` 的关键差别：窗口里找不到分隔行时**不能**拿窗口内容当"本次会话"——
    /// 那会把上一轮的 AUTH_FAILED 误当成本轮（见 AGENTS.md 的追加日志约定）。所以：
    /// - 窗口里有分隔行 → 返回切片；
    /// - 窗口没分隔行、但窗口就是整个文件（老日志 / 手工脚本产物）→ 返回全文（与 `currentSession` 一致）；
    /// - 窗口没分隔行且文件更长（本次会话比窗口还长）→ 返回 nil，调用方改用整文件读一次再判定。
    public static func currentSessionFromTail(_ tail: String, tailIsWholeFile: Bool) -> String? {
        if let last = tail.range(of: sessionMarker, options: .backwards) {
            return String(tail[last.lowerBound...])
        }
        return tailIsWholeFile ? tail : nil
    }

    public static func indicatesAuthFailure(in log: String) -> Bool {
        let lowered = log.lowercased()
        return authFailureMarkers.contains { lowered.contains($0) }
    }
}
