import Foundation

/// VPN 引擎授权状态（纯逻辑，可单元测试）
public enum EngineAuth: Equatable, Sendable {
    case checking
    case authorized
    case unauthorized
    case broken
    case authorizing

    public var summary: String {
        switch self {
        case .checking: return L10nCore.tr("engine.checking")
        case .authorized: return L10nCore.tr("engine.authorized")
        case .unauthorized: return L10nCore.tr("engine.unauthorized")
        case .broken: return L10nCore.tr("engine.broken")
        case .authorizing: return L10nCore.tr("engine.authorizing")
        }
    }
}
