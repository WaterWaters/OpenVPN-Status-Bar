import SwiftUI

/// VPN 连接状态（纯逻辑，可单元测试）
public enum VPNStatus: Equatable {
    case unconfigured
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)

    public var title: String {
        switch self {
        case .unconfigured: return "未配置"
        case .disconnected: return "已断开"
        case .connecting: return "连接中…"
        case .connected: return "已连接"
        case .reconnecting(let attempt): return "重连中（第 \(attempt) 次）"
        }
    }

    public var symbolName: String {
        switch self {
        case .connected: return "network.badge.shield.half.filled"
        case .connecting, .reconnecting: return "network"
        case .disconnected, .unconfigured: return "network.slash"
        }
    }

    public var color: Color {
        switch self {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected, .unconfigured: return .gray
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
}
