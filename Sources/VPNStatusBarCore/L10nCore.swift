import Foundation
import os

/// Core 层文案（单语言：简体中文，代码内表）。与 app 层同样不再走 .lproj 资源。
enum L10nCore {
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        guard let format = table[key] else {
            missingKeyLog.error("缺少文案 key: \(key, privacy: .public)")
            return key
        }
        if args.isEmpty { return format }
        return String(format: format, locale: Locale(identifier: "zh_Hans"), arguments: args)
    }

    private static let missingKeyLog = Logger(subsystem: "io.vpnstatusbar", category: "l10n")

    private static let table: [String: String] = [
        "engine.authorized": "VPN 引擎已授权",
        "engine.authorizing": "VPN 引擎授权中…",
        "engine.broken": "VPN 引擎异常（需要修复）",
        "engine.checking": "VPN 引擎检测中…",
        "engine.unauthorized": "VPN 引擎未授权（需要授权 VPN）",
        "status.connected": "已连接",
        "status.connecting": "连接中…",
        "status.disconnected": "已断开",
        "status.reconnecting": "重连中（第 %d 次）",
        "status.unconfigured": "未配置",
    ]
}
