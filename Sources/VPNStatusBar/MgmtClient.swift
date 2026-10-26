import Foundation
import os
import VPNStatusBarCore

/// management 接口的**常驻单连接**。
///
/// 为什么要常驻：接口同时只服务一个客户端，而 `state on` 之后由 openvpn 主动推 `>STATE:`，
/// 所以维持一条长连接收推送，比每 2 秒新建连接去问 `state` 延迟低、唤醒少。
///
/// 关键约定：
/// - 连上后**不主动发命令**：等 banner（未设密码）或 `ENTER PASSWORD:`（设了密码）；
///   设了密码时发送**裸密码行**（实测带 `PASSWORD:` 前缀会被判为错误密码），
///   待 `SUCCESS: password is correct` 后再发 `state on` 订阅推送，并补一次 `state` 取当前快照
///   （`state on` 只推变化，不补这一下的话"连上时隧道已 CONNECTED"会一直看不到状态）。
/// - 因为"同时只服务一个客户端"，停机用的 `signal SIGTERM` 优先走这条连接（见 VPNManager.signalTerminate）；
///   流不可用时仍保留一次性连接的兜底路径，停隧道的能力不依赖流的健康。
/// - 断线按 1/2/5 秒退避重连；`stop()` 之后不再重连。
/// - 所有 socket 操作与可变状态都在私有串行队列 `queue` 上；对外回调一律切回主线程。
final class MgmtClient {
    enum State: Equatable {
        case idle
        case connecting
        case streaming
        /// 无法使用（例如服务器要求密码但 app 没拿到）
        case unavailable(String)
    }

    private let log = Logger(subsystem: "io.vpnstatusbar", category: "mgmt")
    private let queue = DispatchQueue(label: "vpnstatusbar.mgmtclient")

    /// 事件回调（主线程）。第二个参数是本次连接的代次：调用方据此丢弃上一次启动遗留的推送。
    var onEvent: ((ManagementEvent, UInt64) -> Void)?
    /// 连接状态回调（主线程）。同样携带代次。
    var onStateChange: ((State, UInt64) -> Void)?

    // 以下状态只在 queue 上访问
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var pending = Data()
    private var shouldRun = false
    private var password: String?
    private var subscribed = false
    private var bytecountInterval = 0
    private var backoff: TimeInterval = 1
    private var retry: DispatchWorkItem?
    private var state: State = .idle
    /// 由上层（VPNManager）给出的启动代次：只做透传，本类型不解释它
    private var generation: UInt64 = 0

    /// 单行上限：防止异常对端不带换行地灌数据把内存撑大
    private let maxPendingBytes = 64 * 1024

    // MARK: - 对外接口

    func start(password: String?, generation: UInt64) {
        queue.async {
            self.password = password
            // 即使连接已经在跑也要更新代次：后续事件必须带当前代次，否则会被上层当成过期推送丢掉。
            self.generation = generation
            guard !self.shouldRun else { return }
            self.shouldRun = true
            self.backoff = 1
            self.connect()
        }
    }

    func stop() {
        queue.async { self.stopLocked() }
    }

    /// 同步关流：保证"探测残留实例 / 启动新进程"时接口确实已经空出来
    /// （接口同时只服务一个客户端）。**只能在主线程调用**，在 queue 上调用会自锁。
    func stopAndWait() {
        queue.sync { self.stopLocked() }
    }

    private func stopLocked() {
        shouldRun = false
        retry?.cancel()
        retry = nil
        closeSocket()
        setState(.idle)
    }

    /// 通过常驻连接发命令（调用方需先判断 `isStreaming`，否则走一次性连接兜底）
    func send(_ command: String) {
        queue.async { self.write(command) }
    }

    /// 流量推送间隔（0 = 退订）；面板可见时才开，关闭面板零开销
    func setBytecountInterval(_ seconds: Int) {
        queue.async {
            let value = max(0, seconds)
            guard self.bytecountInterval != value else { return }
            self.bytecountInterval = value
            if self.state == .streaming {
                self.write(ManagementProtocol.bytecountCommand(interval: value))
            }
        }
    }

    /// 是否处于推送中（同步查询，供状态机决策；队列上只做短操作，不会久等）
    var isStreaming: Bool { queue.sync { state == .streaming } }

    // MARK: - 连接维护（queue 上执行）

    private func connect() {
        guard shouldRun, fd < 0 else { return }
        setState(.connecting)

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            scheduleReconnect("socket() 失败")
            return
        }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = ManagementProtocol.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(sock)
            scheduleReconnect("connect() 失败（openvpn 尚未监听？）")
            return
        }

        fd = sock
        subscribed = false
        pending.removeAll()

        let src = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }
            close(self.fd)
            self.fd = -1
        }
        source = src
        src.resume()
        backoff = 1
    }

    private func readAvailable() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else {
            teardownAndReconnect()
            return
        }
        pending.append(contentsOf: buffer[0..<count])
        if pending.count > maxPendingBytes {
            log.error("management 单行超限，丢弃缓冲")
            pending.removeAll()
            return
        }
        drainLines()
    }

    /// 按 `\n` / `\r\n` / 单个 `\r` 切行（management 接口实际用 CRLF）
    private func drainLines() {
        var lineStart = pending.startIndex
        var index = pending.startIndex
        while index < pending.endIndex {
            let byte = pending[index]
            guard byte == 0x0A || byte == 0x0D else {
                index = pending.index(after: index)
                continue
            }
            let line = String(decoding: pending[lineStart..<index], as: UTF8.self)
            var next = pending.index(after: index)
            if byte == 0x0D, next < pending.endIndex, pending[next] == 0x0A {
                next = pending.index(after: next)
            }
            lineStart = next
            index = next
            handleLine(line)
        }
        if lineStart > pending.startIndex {
            pending.removeSubrange(pending.startIndex..<lineStart)
        }
        // `ENTER PASSWORD:` 是**提示**、不带换行（真机实测），按行切永远切不出来 ——
        // 必须单独识别缓冲区末尾的这个提示，否则密码发不出去、连接永远卡在未认证
        if pending.count >= Self.passwordPromptBytes.count,
           pending.suffix(Self.passwordPromptBytes.count).elementsEqual(Self.passwordPromptBytes) {
            pending.removeLast(Self.passwordPromptBytes.count)
            handleLine("ENTER PASSWORD:")
        }
    }

    private static let passwordPromptBytes = Array("ENTER PASSWORD:".utf8)

    private func handleLine(_ line: String) {
        let event = ManagementProtocol.classify(line)
        switch event {
        case .passwordPrompt:
            if let password {
                write(ManagementProtocol.interfacePasswordCommand(password))
            } else {
                // 服务器要密码但我们没有：这条连接无法使用，交给上层显示原因
                setState(.unavailable("management 接口要求密码，但本次连接未生成密码"))
            }
        case .banner:
            becomeStreaming()
        case .reply(.success(let text)) where text.lowercased().contains("password is correct"):
            becomeStreaming()
        case .state, .bytecount:
            forward(event)
        case .reply(.error(let text)):
            log.notice("management ERROR: \(text, privacy: .public)")
            forward(event)
        default:
            break
        }
    }

    private func becomeStreaming() {
        guard !subscribed else { return }
        subscribed = true
        setState(.streaming)
        write(ManagementProtocol.stateOnCommand)
        write("state\n")   // 补一次快照：state on 只推变化
        if bytecountInterval > 0 {
            write(ManagementProtocol.bytecountCommand(interval: bytecountInterval))
        }
        log.notice("management 推送已建立（state on 已订阅）")
    }

    private func forward(_ event: ManagementEvent) {
        let gen = generation
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event, gen) }
    }

    private func write(_ command: String) {
        guard fd >= 0 else { return }
        let bytes = Array(command.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBufferPointer { pointer in
                Darwin.send(fd, pointer.baseAddress, pointer.count, 0)   // 显式限定：本类型有个同名方法 send(_:)
            }
            guard n > 0 else {
                log.error("management 写入失败，转为重连")
                teardownAndReconnect()
                return
            }
            sent += n
        }
    }

    private func teardownAndReconnect() {
        closeSocket()
        if shouldRun {
            scheduleReconnect("连接断开")
        } else {
            setState(.idle)
        }
    }

    private func scheduleReconnect(_ reason: String) {
        guard shouldRun, retry == nil else { return }
        setState(.connecting)
        let delay = backoff
        backoff = min(backoff * 2, 5)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retry = nil
            self.connect()
        }
        retry = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        log.debug("management 重连：\(reason, privacy: .public)，\(delay, privacy: .public)s 后重试")
    }

    private func closeSocket() {
        if let source {
            source.cancel()          // cancel handler 负责关 fd
            self.source = nil
        } else if fd >= 0 {
            close(fd)
            fd = -1
        }
        pending.removeAll()
        subscribed = false
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        let gen = generation
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(new, gen) }
    }
}
