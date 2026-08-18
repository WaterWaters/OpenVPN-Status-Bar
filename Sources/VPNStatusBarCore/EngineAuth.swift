import Foundation

/// VPN 引擎授权状态（纯逻辑，可单元测试）
public enum EngineAuth: Equatable {
    case checking
    case authorized
    case unauthorized
    case broken
    case authorizing

    public var summary: String {
        switch self {
        case .checking: return "VPN 引擎检测中…"
        case .authorized: return "VPN 引擎已授权"
        case .unauthorized: return "VPN 引擎未授权（需要授权 VPN）"
        case .broken: return "VPN 引擎异常（需要修复）"
        case .authorizing: return "VPN 引擎授权中…"
        }
    }
}
