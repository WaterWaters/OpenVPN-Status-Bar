import SwiftUI
import AppKit
import VPNStatusBarCore

// MARK: - 面板通用组件
//
// 抽取自 ContentView 里重复的实现：12 处「圆角按钮」（其中 authButton 与 cfgButton 函数体完全相同）、
// 2 处「图标 + 文案 + hover 行」（SettingsRow / FooterQuit 完全相同）、2 处键值行（kvRow / cfgRow）。
// 视觉参数逐项照搬原实现（圆角 / 高度 / 字号 / 颜色），外观零变化是这次抽取的硬要求。

// MARK: - 按钮配色

/// 按钮配色（底色 / hover 底色 / 描边 / 文字色）
struct PanelPalette {
    let bg: Color
    let bgHover: Color
    let border: Color
    let fg: Color

    /// 主操作（连接）
    static let ok = PanelPalette(bg: Design.okSoft, bgHover: Design.okSoft2, border: Design.okRule, fg: Design.okInk)
    /// 主操作（断开）
    static let danger = PanelPalette(bg: Design.dangerSoft, bgHover: Design.dangerSoft2, border: Design.dangerRule, fg: Design.dangerInk)
    /// 警示行（未授权 / 引擎异常）
    static let warn = PanelPalette(bg: Design.dangerSoft, bgHover: Design.dangerSoft2, border: Design.dangerRule, fg: Design.dangerInk)
    /// 次要操作（忙碌状态、编辑等）；设置页按钮历史上没有 hover 反馈，用 hoverEnabled:false 保持原样
    static let neutral = PanelPalette(bg: Design.paper2, bgHover: Design.paper3, border: Design.rule, fg: Design.ink2)
    /// 不可用 / 未生效（灰字）
    static let muted = PanelPalette(bg: Design.paper2, bgHover: Design.paper2, border: Design.rule, fg: Design.ink3)
}

// MARK: - 按钮外观（ButtonStyle 与禁用态共用）

struct PanelButtonSurface: ViewModifier {
    let palette: PanelPalette
    var height: CGFloat = 30
    var corner: CGFloat = Design.Corner.medium
    /// 是否撑满可用宽度（确认行里的紧凑按钮为 false）
    var expand: Bool = true
    var horizontalPadding: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: expand ? .infinity : nil)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(palette.bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}

/// 面板统一按钮样式
struct PanelButtonStyle: ButtonStyle {
    let palette: PanelPalette
    var height: CGFloat = 30
    var corner: CGFloat = Design.Corner.medium
    var fontSize: CGFloat = Design.Font.body
    var fontWeight: Font.Weight = .medium
    /// 是否绘制 hover 底色（设置页按钮历史上没有 hover，默认关闭以保持外观不变）
    var hoverEnabled: Bool = false
    var expand: Bool = true
    var horizontalPadding: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        PanelButtonLabel(
            label: configuration.label,
            palette: palette,
            height: height,
            corner: corner,
            fontSize: fontSize,
            fontWeight: fontWeight,
            hoverEnabled: hoverEnabled,
            expand: expand,
            horizontalPadding: horizontalPadding
        )
    }
}

private struct PanelButtonLabel: View {
    let label: ButtonStyleConfiguration.Label
    let palette: PanelPalette
    let height: CGFloat
    let corner: CGFloat
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let hoverEnabled: Bool
    let expand: Bool
    let horizontalPadding: CGFloat

    @State private var hover = false

    var body: some View {
        label
            .font(.system(size: fontSize, weight: fontWeight))
            .foregroundStyle(palette.fg)
            .modifier(PanelButtonSurface(
                palette: hoveredPalette,
                height: height,
                corner: corner,
                expand: expand,
                horizontalPadding: horizontalPadding
            ))
            .onHover { hovering in
                guard hoverEnabled else { return }
                hover = hovering
            }
    }

    private var hoveredPalette: PanelPalette {
        guard hoverEnabled, hover else { return palette }
        return PanelPalette(bg: palette.bgHover, bgHover: palette.bgHover, border: palette.border, fg: palette.fg)
    }
}

// MARK: - 动作按钮（焦点环 + Enter 触发）

/// 向导等处的实心动作按钮：统一焦点环与键盘默认动作（Enter = 下一步 / 保存 / 完成）
struct PanelActionButton: View {
    let title: String
    var palette: PanelPalette = .ok
    var fontWeight: Font.Weight = .medium
    var enabled: Bool = true
    /// 是否响应 Enter（同一时刻只能有一个默认动作按钮）
    var isDefaultAction: Bool = true
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(PanelButtonStyle(palette: palette, fontWeight: fontWeight))
        .disabled(!enabled)
        .focusable()
        .focused($focused)
        .modifier(FocusRing(focused: focused))
        .keyboardShortcut(isDefaultAction ? .defaultAction : nil)
    }
}

// MARK: - 键盘焦点环

/// 键盘焦点环：规格取自设计稿（2px outline + 2px offset），仅在键盘聚焦时出现。
/// 面板里自定义 `.buttonStyle(.plain)` 的元素默认没有任何焦点反馈，键盘用户“看不见自己在哪”。
struct FocusRing: ViewModifier {
    var focused: Bool
    var corner: CGFloat = Design.Corner.medium

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Design.focusRing, lineWidth: 2)
                .padding(-2)
                .opacity(focused ? 1 : 0)
        )
    }
}

// MARK: - 流量（footer 内联，常驻占位）

/// 内联速率：`↓ 1.2 MB/s  ↑ 340 KB/s`。
/// 位置在面板底部（自动重连右侧、退出左侧），**框架常驻**：未连接时显示 `--` 占位，
/// 不会"连上才出现"导致布局跳动；数值等宽右对齐 + 固定列宽，数字变化时其它元素不动。
///
/// 直接订阅 `TrafficStore`（而不是从 `VPNManager` 上取 @Published 值）：1 Hz 的流量推送
/// 只重绘这一小块，不再牵动整块面板与菜单栏 label。
struct TrafficInline: View {
    @ObservedObject var store: TrafficStore

    private let valueWidth: CGFloat = 50

    var body: some View {
        let traffic = store.rate
        HStack(spacing: 5) {
            column(icon: "arrow.down", tint: Design.ok, value: rate(traffic?.bytesInPerSecond))
            column(icon: "arrow.up", tint: Design.busy, value: rate(traffic?.bytesOutPerSecond))
        }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private func column(icon: String, tint: Color, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: Design.Font.hint, weight: .semibold))
                .foregroundStyle(store.rate == nil ? Design.ink3 : tint)
            Text(value)
                .font(.system(size: Design.Font.hint, design: .monospaced).monospacedDigit())
                .foregroundStyle(store.rate == nil ? Design.ink3 : Design.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: valueWidth, alignment: .trailing)
        }
    }

    private func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "--" }
        return ByteFormat.perSecond(bytesPerSecond)
    }

    private var helpText: String {
        guard let traffic = store.rate else { return L10n.tr("traffic.placeholder") }
        return L10n.tr("traffic.help", ByteFormat.size(Double(traffic.totalIn)), ByteFormat.size(Double(traffic.totalOut)))
    }

    private var accessibilityText: String {
        guard let traffic = store.rate else { return L10n.tr("traffic.placeholder") }
        return L10n.tr("traffic.help", ByteFormat.size(Double(traffic.totalIn)), ByteFormat.size(Double(traffic.totalOut)))
    }
}

// MARK: - 版本信息行

/// app 版本 · 引擎版本 · 引擎架构（报障时一眼可见，不必再翻 Info.plist）
struct VersionLine: View {
    @EnvironmentObject private var vpn: VPNManager

    var body: some View {
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        var parts = ["\(L10n.tr("app.name")) \(app)"]
        if let engine = vpn.engineVersion {
            parts.append("openvpn \(engine)" + (vpn.engineArch.map { " (\($0))" } ?? ""))
        }
        return Text(parts.joined(separator: " · "))
            .font(.system(size: Design.Font.hint))
            .foregroundStyle(Design.ink3)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}
