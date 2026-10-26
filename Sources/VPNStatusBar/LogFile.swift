import Foundation

/// 日志文件读取助手（I/O 在 app 层；纯字符串判读在 Core 的 `OpenVPNLog`）。
///
/// 为什么只读尾部窗口：日志是追加模式、最大 512 KB，而面板展示只要末尾几行、
/// 凭据错误判定只要本次会话 —— 以前每次状态变化都在主线程整读整切
/// （重连循环里每轮还会读两遍），属于白花的磁盘 I/O 与主线程停顿。
enum LogFile {
    struct Tail {
        /// 窗口内容；`isWholeFile == false` 时首行可能被截断，已丢弃
        let text: String
        /// 窗口是否覆盖了整个文件（文件本身比窗口短）
        let isWholeFile: Bool
    }

    /// 读文件末尾 `maxBytes` 字节。文件不存在 / 读失败按"空且是整文件"处理。
    static func tail(atPath path: String, maxBytes: Int) -> Tail {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return Tail(text: "", isWholeFile: true)
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window = UInt64(max(1, maxBytes))
        let start = size > window ? size - window : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: maxBytes),
              !data.isEmpty else {
            return Tail(text: "", isWholeFile: start == 0)
        }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let firstBreak = text.firstIndex(where: \.isNewline) {
            // 从字节中间切进来，首行是半行（还可能切在多字节字符中间）：丢掉
            text = String(text[text.index(after: firstBreak)...])
        }
        return Tail(text: text, isWholeFile: start == 0)
    }

    /// 整文件读取：只在"尾部窗口里找不到会话分隔行"时才用（罕见路径）
    static func whole(atPath path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }
}
