import Foundation

/// 敏感文件/目录的安全落点（认证文件、management 密码、应用数据目录）。
///
/// 为什么不用"先 write 再 chmod"：`Data.write(atomically:)` 会先写一个临时文件再改名，
/// 中间那一瞬间按 umask 落盘（常见 0644）—— 同机其他用户能读到 VPN 用户名/密码。
/// 这里改成"以 0600 创建"，从第一个字节起就是私有权限。
enum PrivateFile {
    /// 以指定权限写入文本（默认 0600）。先删旧文件，避免"旧文件权限更宽 + 覆盖"。
    @discardableResult
    static func write(_ text: String, to path: String, permissions: Int = 0o600) -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        guard fm.createFile(atPath: path,
                            contents: Data(text.utf8),
                            attributes: [.posixPermissions: permissions]) else { return false }
        // 某些文件系统会忽略创建时的属性：补一次（此时文件已存在，只会更严不会更松）
        try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        return true
    }

    /// 目录存在则收紧权限，不存在则以指定权限创建（默认 0700）。
    /// 只对最后一级生效 —— 上层目录（~/Library/Application Support）保持系统默认。
    static func ensureDirectory(_ path: String, permissions: Int = 0o700) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        } else {
            try? fm.createDirectory(atPath: path,
                                    withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: permissions])
            try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        }
    }
}
