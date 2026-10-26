import Foundation

/// openvpn `--version` 输出解析（纯字符串逻辑，可单元测试）。
///
/// 典型输出：
///     OpenVPN 2.6.14 aarch64-apple-darwin25.5.0 [SSL (OpenSSL)] [LZO] [LZ4] [MH/RECVDA] [AEAD]
public enum OpenVPNSignature {
    /// - Returns: 版本号与归一化后的架构名（`arm64` / `x86_64` / 目标三元组首段）
    public static func parse(_ output: String) -> (version: String?, arch: String?) {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, parts[0] == "OpenVPN" else { continue }
            let target = String(parts[2])
            let arch: String
            if target.hasPrefix("aarch64") { arch = "arm64" }
            else if target.hasPrefix("x86_64") { arch = "x86_64" }
            else { arch = target.split(separator: "-").first.map(String.init) ?? target }
            return (String(parts[1]), arch)
        }
        return (nil, nil)
    }
}
