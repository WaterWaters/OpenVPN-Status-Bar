import SwiftUI
import AppKit

// MARK: - 设计 Token
// 对应 design/tokens.css · 浅色 / 深色自适应
// 注意：颜色按「真实菜单渲染」校准 —— 柔和底色必须保证在白底菜单里肉眼可见，
//       不能用接近 95% 明度的"淡色"（在真实菜单里等于透明，会被误认为旧版灰 UI）。

enum Design {
    // 表面
    static let paper  = Color(light: 0xFBFBFD, dark: 0x29292F)
    static let paper2 = Color(light: 0xEFEFF3, dark: 0x31313A)
    static let paper3 = Color(light: 0xE8E8ED, dark: 0x212127)

    // 文字
    static let ink  = Color(light: 0x232329, dark: 0xEDEDF2)
    static let ink2 = Color(light: 0x5B5B64, dark: 0xADADB8)
    static let ink3 = Color(light: 0x8A8A93, dark: 0x8B8B96)

    // 分隔线
    static let rule = Color(light: 0xE0E0E5, dark: 0x3E3E48)

    // 状态：已连接（绿）—— 高对比，菜单里一眼可见
    static let ok        = Color(light: 0x2C9E6C, dark: 0x4BCD96)
    static let okInk     = Color(light: 0x11583B, dark: 0xA5E8C6)
    static let okSoft    = Color(light: 0xD8F0E3, dark: 0x1F3A2D)
    static let okSoft2   = Color(light: 0xC6E9D6, dark: 0x26463A)
    static let okRule    = Color(light: 0xADDBBF, dark: 0x2F5744)

    // 状态：连接中 / 重连中（琥珀）
    static let busy      = Color(light: 0xDE9A2B, dark: 0xF5B14E)
    static let busyInk   = Color(light: 0x774E10, dark: 0xF8D79B)
    static let busySoft  = Color(light: 0xFAEDD3, dark: 0x3A301F)

    // 状态：断开动作（红）
    static let danger      = Color(light: 0xD64A44, dark: 0xF07164)
    static let dangerInk   = Color(light: 0x9A2E26, dark: 0xF5B3AC)
    static let dangerSoft  = Color(light: 0xFADBD9, dark: 0x3A2625)
    static let dangerSoft2 = Color(light: 0xF4CBC8, dark: 0x452D2C)
    static let dangerRule  = Color(light: 0xECC2BF, dark: 0x523635)

    // 焦点环 / 开关
    static let focusRing = Color(light: 0x3D6FE0, dark: 0x7FA8F0)
    static let switchTrack = Color(light: 0x2E84DE, dark: 0x6BA3E8)
}

// MARK: - 面板规格

enum PanelMetrics {
    static let width:   CGFloat = 300
    /// 固定面板高度：窗口尺寸在打开期间恒定 —— 平台"内容变矮时窗口不回收高度"的行为
    /// 因此完全不会发作（不会错位、不会闪烁，也不会留下吞点击的透明区域）。
    static let height:  CGFloat = 360
    static let padding: CGFloat = 12
    static let gap:     CGFloat = 8
}

// MARK: - 字号 / 圆角令牌
// 面板此前把 10 / 10.5 / 11 / 12 / 13 / 14 / 15 / 16 / 22 等字号散落在各处，
// 这里集中定义：改字号只需动一处，且新代码不再引入第 10 个数值。

extension Design {
    enum Font {
        /// 提示、辅助说明（原 10）
        static let hint: CGFloat = 10
        /// 极小字：等宽值（路径、日志）、卡片副标题（原 10.5）
        static let fine: CGFloat = 10.5
        /// 次要文字：行标签、小按钮（原 11）
        static let caption: CGFloat = 11
        /// 常规文字（原 12）
        static let label: CGFloat = 12
        /// 主要文字：按钮、状态标题（原 13）
        static let body: CGFloat = 13
        /// 图标：14 / 15 / 16 三档
        static let icon: CGFloat = 14
        static let iconMedium: CGFloat = 15
        static let iconLarge: CGFloat = 16
        /// 完成态大图标（原 22）
        static let iconHero: CGFloat = 22
    }

    enum Corner {
        /// 原 5：返回箭头等紧凑控件
        static let compact: CGFloat = 5
        /// 原 6：行、小卡片
        static let small: CGFloat = 6
        /// 原 7：按钮
        static let medium: CGFloat = 7
        /// 原 8：卡片
        static let large: CGFloat = 8
    }
}

// MARK: - 浅色/深色自适应色
// 用动态 NSColor 解析当前外观；外观解析失败时回退到 NSApp.effectiveAppearance，
// 避免在菜单渲染上下文里拿不到外观导致颜色失效（表现为一片灰）。

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: .adaptive(light: light, dark: dark))
    }
}

// MARK: - 动态 NSColor（浅色/深色自适应）
// 供 AppKit 侧（菜单栏图标等）直接使用，与 Color(light:dark:) 同一套取值。

extension NSColor {
    static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
                ?? NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            let isDark = match == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed:   CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue:  CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}
