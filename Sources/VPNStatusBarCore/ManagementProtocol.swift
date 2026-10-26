import Foundation

/// openvpn management 接口的一行报文（纯逻辑，可单元测试）。
///
/// 报文事实全部来自真机抓取（`openvpn --dev null --management 127.0.0.1 <port>` 实测）：
///
///     >INFO:OpenVPN Management Interface Version 5 -- type 'help' for more info
///     >HOLD:Waiting for hold release:0
///     1791612939,CONNECTING,,,,,,                ← 一次性 state 响应行（字段序见 OpenVPNMgmt）
///     SUCCESS: real-time state notification set to ON
///     SUCCESS: bytecount interval changed
///     SUCCESS: signal SIGTERM thrown
///     END
///     ENTER PASSWORD:                            ← 接口设了密码时，连接后先要这一句
///     >STATE:1791612939,CONNECTED,SUCCESS,10.8.0.24,1.2.3.4,1194,,
///     >BYTECOUNT:12345,6789
///     1791612950,D,MANAGEMENT: CMD 'state on'    ← `log on` 推送的日志行（注意没有 >LOG: 前缀）
public enum ManagementEvent: Equatable, Sendable {
    /// 连接后的 banner（`>INFO:…`）
    case banner(String)
    /// 服务器要求先送密码（`ENTER PASSWORD:`）
    case passwordPrompt
    /// 隧道状态（一次性响应行或 `>STATE:` 推送）
    case state(TunnelInfo)
    /// 流量计数推送（`>BYTECOUNT:rx,tx`）
    case bytecount(rx: Int64, tx: Int64)
    /// hold 状态（`>HOLD:…`）
    case hold(String)
    /// 日志推送（`log on` 之后的时间戳行）
    case log(String)
    /// 命令回执
    case reply(ManagementReply)
    /// 认不出来的行（不猜测、不崩）
    case unknown(String)
}

public enum ManagementReply: Equatable, Sendable {
    case success(String)
    case error(String)
    case end
}

/// 报文分类 + 命令构建。网络 I/O 不在这里（见 app 层 MgmtClient）。
public enum ManagementProtocol {
    /// management 端口：客户端与 runner 都从这里取，避免两处硬编码漂移。
    /// 固定端口同时也是「同时只允许一个隧道」的互斥来源（端口被占时 openvpn 启动失败）。
    public static let port: UInt16 = 7505

    // MARK: - 命令

    /// 订阅状态变化推送（之后由服务器主动推 `>STATE:`）
    public static let stateOnCommand = "state on\n"
    /// 接口密码：**发送原始密码行，不加任何前缀**。
    ///
    /// 真机实测（`--management 127.0.0.1 <port> <pw文件>`，文件为单行原始密码）：
    /// - 服务器先输出 `ENTER PASSWORD:`；
    /// - 客户端发 `PASSWORD:<pw>` 会被判为错误密码，三次后日志出现
    ///   `MAN: client connection rejected after 3 failed password attempts` 并断连；
    /// - 发送**裸密码行**才回 `SUCCESS: password is correct`，随后给 banner（`>INFO:…`），
    ///   之后命令正常可用。
    public static func interfacePasswordCommand(_ password: String) -> String { "\(password)\n" }
    /// 流量计数推送间隔（秒）；0 表示关闭推送
    public static func bytecountCommand(interval: Int) -> String { "bytecount \(max(0, interval))\n" }
    /// 让 openvpn 自行退出（唯一能停掉 root 进程的通道）
    public static let terminateCommand = "signal SIGTERM\n"

    // MARK: - 分类

    /// 把一行原始报文归类。入参可以是带 `\n`/`\r\n` 的整行。
    public static func classify(_ rawLine: String) -> ManagementEvent {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return .unknown("") }

        if line == "END" { return .reply(.end) }
        if let payload = payload(of: line, prefix: "SUCCESS:") { return .reply(.success(payload)) }
        if let payload = payload(of: line, prefix: "ERROR:") { return .reply(.error(payload)) }
        if line.hasPrefix("ENTER PASSWORD:") { return .passwordPrompt }
        if let payload = payload(of: line, prefix: ">INFO:") { return .banner(payload) }
        if let payload = payload(of: line, prefix: ">HOLD:") { return .hold(payload) }
        if let payload = payload(of: line, prefix: ">BYTECOUNT:") { return bytecount(payload) ?? .unknown(line) }
        // `>STATE:` 的载荷与一次性 state 响应行同为 CSV，走同一条解析
        if let payload = payload(of: line, prefix: ">STATE:") { return stateEvent(payload) }
        // 时间戳开头的行：state 行（第二字段是状态名）或日志行（第二字段是 D/I/W/E 这类单字母标记）
        if let first = line.first, first.isNumber { return stateEvent(line) }
        return .unknown(line)
    }

    private static func payload(of line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func stateEvent(_ csv: String) -> ManagementEvent {
        let info = OpenVPNMgmt.parseInfo(csv)
        if info.state != .unknown { return .state(info) }
        // 不是状态行：`<时间戳>,<标记>,<文本>` 形态的日志推送
        let fields = csv.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
        if fields.count >= 3, Int(fields[0]) != nil, fields[1].count <= 2 {
            return .log(String(fields[2]))
        }
        return .unknown(csv)
    }

    private static func bytecount(_ csv: String) -> ManagementEvent? {
        let fields = csv.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2,
              let rx = Int64(fields[0].trimmingCharacters(in: .whitespaces)),
              let tx = Int64(fields[1].trimmingCharacters(in: .whitespaces)),
              rx >= 0, tx >= 0 else { return nil }
        return .bytecount(rx: rx, tx: tx)
    }
}

// MARK: - 流量

/// 一次计数采样（openvpn 报告的是本次会话累计字节数）
public struct TrafficSample: Equatable, Sendable {
    public var bytesIn: Int64
    public var bytesOut: Int64
    public var at: Date

    public init(bytesIn: Int64, bytesOut: Int64, at: Date) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.at = at
    }
}

/// 速率 + 累计（面板展示用）
public struct TrafficRate: Equatable, Sendable {
    public var bytesInPerSecond: Double
    public var bytesOutPerSecond: Double
    public var totalIn: Int64
    public var totalOut: Int64

    public init(bytesInPerSecond: Double, bytesOutPerSecond: Double, totalIn: Int64, totalOut: Int64) {
        self.bytesInPerSecond = bytesInPerSecond
        self.bytesOutPerSecond = bytesOutPerSecond
        self.totalIn = totalIn
        self.totalOut = totalOut
    }
}

public enum TrafficCalculator {
    /// 由相邻两次采样算速率。采样间隔太短、或计数器回退（重连后归零）时返回 nil，避免显示假速率。
    public static func rate(from previous: TrafficSample, to current: TrafficSample) -> TrafficRate? {
        let elapsed = current.at.timeIntervalSince(previous.at)
        guard elapsed >= 0.5 else { return nil }
        let deltaIn = current.bytesIn - previous.bytesIn
        let deltaOut = current.bytesOut - previous.bytesOut
        guard deltaIn >= 0, deltaOut >= 0 else { return nil }
        return TrafficRate(
            bytesInPerSecond: Double(deltaIn) / elapsed,
            bytesOutPerSecond: Double(deltaOut) / elapsed,
            totalIn: current.bytesIn,
            totalOut: current.bytesOut
        )
    }
}

/// 字节格式化（自己实现而不用 ByteCountFormatter：输出稳定、可单测、不受区域设置影响）
public enum ByteFormat {
    private static let units = ["B", "KB", "MB", "GB", "TB"]

    /// 速率：`0 B/s`、`512 B/s`、`1.2 KB/s`、`1.2 MB/s`
    public static func perSecond(_ bytesPerSecond: Double) -> String {
        size(bytesPerSecond) + "/s"
    }

    /// 累计：`0 B`、`24.3 MB`、`1.8 GB`
    public static func size(_ bytes: Double) -> String {
        var value = max(0, bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let text = index == 0 ? String(Int(value.rounded())) : String(format: "%.1f", value)
        return "\(text) \(units[index])"
    }
}
