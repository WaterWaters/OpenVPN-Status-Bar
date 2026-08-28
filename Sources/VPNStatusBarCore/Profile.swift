import Foundation

/// 通用 VPN 配置档案（可单元测试的纯值类型）
public struct VPNProfile: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String        // 显示名，默认取文件名
    public var fileName: String    // 原始 .ovpn 文件名
    public var username: String
    public var serverAddress: String // 解析出的 remote
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, name: String, fileName: String, username: String, serverAddress: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.username = username
        self.serverAddress = serverAddress
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 从 ovpn 内容解析 server
    public static func parseServerAddress(from ovpn: String) -> String {
        for line in ovpn.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("remote ") {
                return t.dropFirst(7).trimmingCharacters(in: .whitespaces)
            }
        }
        return "—"
    }
}
