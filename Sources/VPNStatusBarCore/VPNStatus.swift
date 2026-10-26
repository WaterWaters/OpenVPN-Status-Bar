import Foundation

/// VPN 连接状态（纯逻辑，可单元测试）
public enum VPNStatus: Equatable, Sendable {
    case unconfigured
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)

    public var title: String {
        switch self {
        case .unconfigured: return L10nCore.tr("status.unconfigured")
        case .disconnected: return L10nCore.tr("status.disconnected")
        case .connecting: return L10nCore.tr("status.connecting")
        case .connected: return L10nCore.tr("status.connected")
        case .reconnecting(let attempt): return L10nCore.tr("status.reconnecting", attempt)
        }
    }

    public var symbolName: String {
        switch self {
        case .connected: return "shield.fill"
        case .connecting, .reconnecting: return "shield"
        case .disconnected: return "shield.slash.fill"
        case .unconfigured: return "shield.slash"
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// 进行中的忙碌状态（连接中 / 重连中）
    public var isBusy: Bool {
        if case .connecting = self { return true }
        if case .reconnecting = self { return true }
        return false
    }

    public var isReconnecting: Bool {
        if case .reconnecting = self { return true }
        return false
    }

    /// 是否需要秒级时钟：只有"已连接"（时长）与"重连中"（倒计时）需要。
    /// `connecting` 只是静态提示文案；空闲断开更不该有 1 Hz 唤醒。
    public var needsClock: Bool { isConnected || isReconnecting }
}
