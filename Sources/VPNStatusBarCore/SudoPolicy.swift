import Foundation

/// `sudo -n -l` 输出解析（纯字符串逻辑，可单元测试）。
///
/// 为什么不用 `sudo -n -l <path>` 直接判断免密：admin 组用户的策略里有 `(ALL) ALL`（需密码），
/// `-l` 只回答"是否有权运行"，对任何命令都返回 0 —— 见 `EngineAuthorizer.probe` 的说明。
/// 这里只做"从策略文本里认规则"，是否真的免密由调用方跑一次命令验证。
public enum SudoPolicy {
    /// 是否存在指向 `path` 的 NOPASSWD 规则。
    public static func hasNoPasswdRule(for path: String, in listing: String) -> Bool {
        split(listing).contains { line in
            line.contains("NOPASSWD") && line.hasSuffix(path)
        }
    }

    /// 第一条指向 openvpn、且不在 `excluding` 里的 NOPASSWD 路径（用于提示遗留的免密规则）。
    /// 例如 v2 时代手工加的 `/opt/homebrew/sbin/openvpn` —— Homebrew 目录用户可写，
    /// 那条 NOPASSWD 等于把 root 执行权交给任何进程都能改写的二进制。
    public static func firstForeignOpenVPNRule(in listing: String, excluding: Set<String>) -> String? {
        for line in split(listing) {
            guard line.contains("NOPASSWD"), line.contains("openvpn") else { continue }
            guard let path = line.split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces),
                  path.hasPrefix("/"),
                  !excluding.contains(path) else { continue }
            return path
        }
        return nil
    }

    private static func split(_ listing: String) -> [String] {
        listing.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }
}
