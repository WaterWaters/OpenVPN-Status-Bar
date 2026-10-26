import SwiftUI
import AppKit
import VPNStatusBarCore

// MARK: - 面板新布局（固定高度 / 卡片统一容器 / 信息浓缩）
//
// 三条设计约束（来自使用反馈）：
// 1. **面板高度固定**（`PanelMetrics.height`）：窗口尺寸在打开期间不再变化 —— 从根上消除
//    "切换标签错位/闪烁"和下方那块吞点击的透明区域，也不再需要按高度手动对齐窗口；
// 2. **每个区块共用一个卡片容器**（`PanelCard`）：标题行 + 内容 + 操作行，一套内外边距与描边；
// 3. **浓缩信息、按钮成行**：路径/版本这类排障信息收进悬停提示，操作按钮一行放 2–3 个。

// MARK: - 卡片容器

/// 统一卡片：标题行（图标 + 标题 + 右侧可选内容）+ 内容 + 操作行
struct PanelCard<Content: View, Trailing: View>: View {
    let title: String
    let icon: String
    var tint: Color = Design.ink2
    @ViewBuilder var content: () -> Content
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: Design.Font.hint))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: Design.Font.caption, weight: .semibold))
                    .foregroundStyle(Design.ink2)
                Spacer(minLength: 4)
                trailing()
            }
            content()
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Design.Corner.large, style: .continuous)
                .fill(Design.paper2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Corner.large, style: .continuous)
                .strokeBorder(Design.rule, lineWidth: 1)
        )
    }
}

extension PanelCard where Trailing == EmptyView {
    init(title: String, icon: String, tint: Color = Design.ink2, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, icon: icon, tint: tint, content: content, trailing: { EmptyView() })
    }
}

/// 一行放多个等宽按钮（原来一行一个太占高度）
struct PanelActionRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 6) { content() }
    }
}

/// 一行多按钮时用的尺寸（高 24、次要按钮样式）
extension PanelButtonStyle {
    static func compact(_ palette: PanelPalette, font: CGFloat = Design.Font.caption, weight: Font.Weight = .medium) -> PanelButtonStyle {
        PanelButtonStyle(palette: palette, height: 24, corner: Design.Corner.small,
                         fontSize: font, fontWeight: weight)
    }
}

// MARK: - 状态块（浓缩：去掉冗余前缀，流量独立一行）

struct StatusBlock: View {
    @EnvironmentObject private var vpn: VPNManager

    private var isBusy: Bool { vpn.status.isBusy }

    private var tileColor: (bg: Color, fg: Color) {
        switch vpn.status {
        case .connected: return (Design.okSoft, Design.okInk)
        case .connecting, .reconnecting: return (Design.busySoft, Design.busyInk)
        case .disconnected, .unconfigured: return (Design.paper2, Design.ink3)
        }
    }

    private var dotColor: Color {
        switch vpn.status {
        case .connected: return Design.ok
        case .connecting, .reconnecting: return Design.busy
        case .disconnected, .unconfigured: return Design.ink3
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: Design.Corner.small, style: .continuous)
                        .fill(tileColor.bg)
                        .frame(width: 26, height: 26)
                    Image(systemName: vpn.status.symbolName)
                        .font(.system(size: Design.Font.icon, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(tileColor.fg)
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: vpn.status)

                HStack(spacing: 6) {
                    PulsingDot(color: dotColor, isBusy: isBusy)
                    Text(vpn.status.title)
                        .font(.system(size: Design.Font.body, weight: .semibold))
                        .foregroundStyle(Design.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    DurationText(status: vpn.status, connectedAt: vpn.connectedAt, color: dotColor)
                }
            }

            detailRow

        }
    }

    /// 第二行：只放最有用的一两个要素（档案名 · 隧道地址 / 重连倒计时 / 引导语）。
    /// 倒计时单独拆成子视图订阅 1 秒时钟 —— 否则数字只在别的状态变化时才刷新（表现为"倒计时卡住"）。
    @ViewBuilder
    private var detailRow: some View {
        Group {
            if case .reconnecting = vpn.status {
                RetryCountdown(deadline: vpn.retryDeadline)
            } else {
                Text(statusDetail)
            }
        }
        .font(.system(size: Design.Font.caption))
        .foregroundStyle(Design.ink2)
        .lineLimit(1)
        .truncationMode(.middle)
    }

    /// 第二行：只放最有用的一两个要素（档案名 · 隧道地址 / 重连倒计时 / 引导语）
    private var statusDetail: String {
        switch vpn.status {
        case .unconfigured:
            return L10n.tr("notConfigured")
        case .connected:
            var parts = [vpn.profileName]
            if let ip = vpn.tunnelLocalAddress, !ip.isEmpty { parts.append(ip) }
            if vpn.reconnectCount > 0 { parts.append(L10n.tr("status.reconnected.short", vpn.reconnectCount)) }
            return parts.joined(separator: " · ")
        case .reconnecting:
            return L10n.tr("status.retry", 0)   // 正常走 RetryCountdown；这里只是兜底
        case .connecting:
            return L10n.tr("status.connecting.hint")
        case .disconnected:
            return vpn.profileName
        }
    }
}

/// 重连倒计时：只让这一小块订阅 1 秒时钟（`TickProvider` 已按面板可见性开关）。
/// 以前这段数字算在 StatusBlock 里，而 StatusBlock 不订阅时钟 —— 重连等待期间数字不会自己走。
struct RetryCountdown: View {
    let deadline: Date?
    @ObservedObject private var tick = TickProvider.shared

    var body: some View {
        let _ = tick.now     // 订阅时钟，仅此子视图刷新
        let remaining = max(0, Int((deadline ?? Date()).timeIntervalSinceNow.rounded(.up)))
        Text(L10n.tr("status.retry", remaining))
    }
}

// MARK: - 日志卡（概览与诊断共用）

struct LogCard: View {
    @EnvironmentObject private var vpn: VPNManager
    /// nil = 填满可用高度；否则只显示最后 N 行
    var maxLines: Int?

    @State private var lines: [String] = []
    @State private var copied = false

    /// 只做"取末尾 N 行"，**不截断字符**：截断交给 SwiftUI 的 lineLimit，
    /// 否则 `.textSelection` 复制到的是被截过的假日志，排障时最要命。
    private func makeLines(from tail: String) -> [String] {
        let all = tail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return maxLines.map { Array(all.suffix($0)) } ?? Array(all.suffix(40))
    }

    var body: some View {
        PanelCard(title: L10n.tr("log.title"), icon: "doc.text") {
            Group {
                if lines.isEmpty {
                    Text(L10n.tr("log.empty"))
                        .font(.system(size: Design.Font.caption, design: .monospaced))
                        .foregroundStyle(Design.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                    Text(line)
                                        .font(.system(size: Design.Font.caption, design: .monospaced))
                                        .foregroundStyle(Design.ink2)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                        .help(line)          // 截断时悬停可读全文
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(index)
                                }
                            }
                        }
                        // 内容按"最后 N 行"组织、可视区只够几行 —— 不跟随就永远停在最旧的一屏
                        .onAppear { scrollToBottom(proxy) }
                        .onChange(of: lines) { _ in scrollToBottom(proxy) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: maxLines == nil ? .infinity : nil, alignment: .topLeading)
        } trailing: {
            HStack(spacing: 4) {
                if copied {
                    Text(L10n.tr("log.copied"))
                        .font(.system(size: Design.Font.hint))
                        .foregroundStyle(Design.okInk)
                }
                Button { copyLog() } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: Design.Font.hint))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Design.ink3)
                .help(L10n.tr("log.copy"))
                .accessibilityLabel(L10n.tr("log.copy"))

                Button { NSWorkspace.shared.open(URL(fileURLWithPath: vpn.logFile)) } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: Design.Font.hint))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Design.ink3)
                .help(L10n.tr("log.open"))
                .accessibilityLabel(L10n.tr("log.open"))
            }
        }
        .onAppear { lines = makeLines(from: vpn.logTail) }
        .onChange(of: vpn.logTail) { tail in lines = makeLines(from: tail) }
    }

    /// 滚到末尾（无动画：滚动不做动效，避免与固定高度窗口叠加出意外）
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = lines.indices.last else { return }
        DispatchQueue.main.async { proxy.scrollTo(last, anchor: .bottom) }
    }

    private func copyLog() {
        // 主线程只取路径与兜底文本，整文件读取（最多 512 KB）放后台
        let path = vpn.logFile
        let fallback = vpn.logTail
        DispatchQueue.global(qos: .utility).async {
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? fallback
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            }
        }
    }
}

// MARK: - 引擎警示行（未授权 / 异常 / 旧授权规则）

struct EngineWarnRow: View {
    @EnvironmentObject private var vpn: VPNManager
    let onOpenSettings: () -> Void

    private var warning: String? {
        switch vpn.engineAuth {
        case .unauthorized: return L10n.tr("engine.warn.unauthorized")
        case .broken: return L10n.tr("engine.warn.broken")
        default: return nil
        }
    }

    var body: some View {
        if let warning {
            Button(action: onOpenSettings) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: Design.Font.hint))
                    Text(warning).font(.system(size: Design.Font.hint)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(L10n.tr("engine.warn.settings")).font(.system(size: Design.Font.hint, weight: .semibold))
                }
            }
            .buttonStyle(PanelButtonStyle(palette: .warn, height: 24, corner: Design.Corner.small,
                                          fontSize: Design.Font.hint, hoverEnabled: true, horizontalPadding: 6))
        }
    }
}

// MARK: - 授权卡

struct AuthCard: View {
    @EnvironmentObject private var vpn: VPNManager
    let onAuthorize: () -> Void

    private var status: (icon: String, tint: Color, text: String) {
        switch vpn.engineAuth {
        case .authorized:
            let version = vpn.engineVersion.map { "openvpn \($0)" } ?? "—"
            let arch = vpn.engineArch.map { " (\($0))" } ?? ""
            return ("checkmark.circle.fill", Design.ok, L10n.tr("auth.status.authorized") + " · " + version + arch)
        case .authorizing:
            return ("clock", Design.busy, L10n.tr("auth.engine.authorizing"))
        case .checking:
            return ("clock", Design.ink3, L10n.tr("auth.engine.checking"))
        case .unauthorized:
            return ("lock", Design.ink3, L10n.tr("auth.status.unauthorized"))
        case .broken:
            return ("exclamationmark.triangle.fill", Design.danger, L10n.tr("auth.status.broken"))
        }
    }

    var body: some View {
        PanelCard(title: L10n.tr("auth.engine"), icon: "shield.lefthalf.filled") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: status.icon)
                        .font(.system(size: Design.Font.caption))
                        .foregroundStyle(status.tint)
                    Text(status.text)
                        .font(.system(size: Design.Font.caption))
                        .foregroundStyle(Design.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                // 路径这类排障信息收进悬停提示（原来占 4 行）
                .help(L10n.tr("auth.paths.help", "/usr/local/vpnstatusbar/vpn-run.sh", "/usr/local/vpnstatusbar/openvpn"))

                switch vpn.engineAuth {
                case .unauthorized:
                    PanelActionRow { Button(L10n.tr("auth.authorize")) { onAuthorize() }
                        .buttonStyle(PanelButtonStyle.compact(.ok)) }
                case .broken:
                    PanelActionRow { Button(L10n.tr("auth.repair")) { onAuthorize() }
                        .buttonStyle(PanelButtonStyle.compact(.danger)) }
                case .authorized:
                    PanelActionRow { Button(L10n.tr("auth.reauthorize")) { onAuthorize() }
                        .buttonStyle(PanelButtonStyle.compact(.neutral)) }
                case .authorizing, .checking:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("auth.checking")).font(.system(size: Design.Font.caption)).foregroundStyle(Design.ink3)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 24)
                }

                if vpn.needsReauthorization {
                    Text(L10n.tr("auth.upgrade.hint"))
                        .font(.system(size: Design.Font.hint))
                        .foregroundStyle(Design.dangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - 配置列表卡（顶部加号 + 每个配置一张卡：ovpn 文件名 + 登录用户名 + 修改/删除）

struct ProfilesCard: View {
    @EnvironmentObject private var vpn: VPNManager
    let onAdd: () -> Void
    let onEdit: (String) -> Void

    /// 待确认删除的档案 id
    @State private var pendingDeleteId: String?

    var body: some View {
        PanelCard(title: L10n.tr("connection.config"), icon: "doc.text") {
            VStack(alignment: .leading, spacing: 6) {
                // 新增按钮在列表顶部
                PanelActionRow {
                    Button(L10n.tr("config.addProfile")) { onAdd() }
                        .buttonStyle(PanelButtonStyle.compact(.ok))
                }

                if vpn.profiles.isEmpty {
                    Text(L10n.tr("connection.notConfigured"))
                        .font(.system(size: Design.Font.caption))
                        .foregroundStyle(Design.ink2)
                        .padding(.top, 2)
                } else {
                    ForEach(vpn.profiles, id: \.id) { profile in
                        profileItem(profile)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func profileItem(_ profile: VPNProfile) -> some View {
        let isActive = vpn.activeProfile?.id == profile.id
        if pendingDeleteId == profile.id {
            confirmRow(L10n.tr("connection.confirm.delete", profile.fileName)) {
                pendingDeleteId = nil
                vpn.deleteProfile(id: profile.id)
            } onCancel: {
                pendingDeleteId = nil
            }
        } else {
            HStack(spacing: 6) {
                // 点这一行 = 切换到这个配置（当前使用的带勾）
                Button(action: { vpn.switchProfile(id: profile.id) }) {
                    HStack(spacing: 5) {
                        Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: Design.Font.hint))
                            .foregroundStyle(isActive ? Design.ok : Design.ink3.opacity(0.5))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.fileName)
                                .font(.system(size: Design.Font.caption, weight: isActive ? .semibold : .regular))
                                .foregroundStyle(Design.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(profile.username)
                                .font(.system(size: Design.Font.hint))
                                .foregroundStyle(Design.ink3)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("connection.switchTo", profile.fileName))

                PanelActionRow {
                    Button(L10n.tr("config.edit")) { onEdit(profile.id) }
                        .buttonStyle(PanelButtonStyle.compact(.neutral, font: Design.Font.hint))
                    Button(L10n.tr("config.remove")) { pendingDeleteId = profile.id }
                        .buttonStyle(PanelButtonStyle.compact(PanelPalette(bg: Design.dangerSoft, bgHover: Design.dangerSoft2,
                                                                           border: Design.dangerRule, fg: Design.dangerInk),
                                                               font: Design.Font.hint))
                }
                .fixedSize()
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: Design.Corner.small, style: .continuous)
                    .fill(isActive ? Design.okSoft.opacity(0.5) : Design.paper3)
            )
        }
    }

    private func confirmRow(_ question: String, onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(question)
                .font(.system(size: Design.Font.hint))
                .foregroundStyle(Design.dangerInk)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            PanelActionRow {
                Button(L10n.tr("common.delete")) { onConfirm() }
                    .buttonStyle(PanelButtonStyle.compact(PanelPalette(bg: Design.dangerSoft2, bgHover: Design.dangerSoft2,
                                                                       border: Design.dangerRule, fg: Design.dangerInk),
                                                           font: Design.Font.hint))
                Button(L10n.tr("common.cancel")) { onCancel() }
                    .buttonStyle(PanelButtonStyle.compact(.neutral, font: Design.Font.hint))
            }
            .fixedSize()
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Design.Corner.small, style: .continuous)
                .fill(Design.dangerSoft.opacity(0.6))
        )
    }
}

// MARK: - 偏好卡（两个开关一行）

struct PrefsCard: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var notifications = UserDefaults.standard.bool(forKey: "notifyEnabled")

    var body: some View {
        PanelCard(title: L10n.tr("prefs.title"), icon: "gearshape") {
            HStack(spacing: 10) {
                toggleRow(icon: "power", label: L10n.tr("launchAtLogin"), isOn: $launchAtLogin) {
                    LaunchAtLogin.setEnabled($0)
                }
                toggleRow(icon: "bell", label: L10n.tr("notifications"), isOn: $notifications) {
                    UserDefaults.standard.set($0, forKey: "notifyEnabled")
                    if $0 { NotificationService.requestAuthorizationIfNeeded() }
                }
            }
        }
    }

    private func toggleRow(icon: String, label: String, isOn: Binding<Bool>, onChange: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: Design.Font.hint)).foregroundStyle(Design.ink3)
            Text(label).font(.system(size: Design.Font.caption)).foregroundStyle(Design.ink2).lineLimit(1)
            Spacer(minLength: 2)
            Toggle("", isOn: Binding(get: { isOn.wrappedValue }, set: { isOn.wrappedValue = $0; onChange($0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 底部一行（自动重连 · 速率 · 退出）

struct PanelFooter: View {
    @EnvironmentObject private var vpn: VPNManager
    @State private var quitHover = false

    var body: some View {
        HStack(spacing: 6) {
            Text(L10n.tr("autoreconnect.short"))
                .font(.system(size: Design.Font.hint))
                .foregroundStyle(Design.ink2)
                .fixedSize()
            Toggle("", isOn: $vpn.autoReconnect)
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .tint(vpn.isConfigured ? Design.switchTrack : Design.ink3)
                .disabled(!vpn.isConfigured)
                .help(L10n.tr("autoreconnect.short"))

            Spacer(minLength: 4)

            // 速率：框架常驻（未连接显示 --），位置在自动重连右侧、退出左侧；
            // 传 store 而不是值：1 Hz 推送只刷新这一小块
            TrafficInline(store: vpn.trafficStore)

            Spacer(minLength: 4)

            Button {
                vpn.shutdown()
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "power").font(.system(size: Design.Font.hint))
                    Text(L10n.tr("quit.short")).font(.system(size: Design.Font.hint))
                }
                .foregroundStyle(Design.ink2)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: Design.Corner.small, style: .continuous)
                        .fill(quitHover ? Design.paper2 : .clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { quitHover = $0 }
            .help(L10n.tr("quit"))
            .focusable()
            .fixedSize()
        }
        .frame(height: 20)
    }
}

// MARK: - 事件行

struct EventRow: View {
    @EnvironmentObject private var vpn: VPNManager

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "info.circle")
                .font(.system(size: Design.Font.hint))
                .foregroundStyle(Design.ink3)
            Text(vpn.lastEvent)
                .font(.system(size: Design.Font.hint))
                .foregroundStyle(Design.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}
