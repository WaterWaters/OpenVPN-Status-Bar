import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VPNStatusBarCore

// MARK: - 主面板（对应 design/mockup.html 面板设计）
// 结构：状态块 → 主操作按钮 → 自动重连开关 → 最近事件 → 可折叠日志 → 配置 → 退出
// 未配置时主操作 = 「导入配置…」→ 打开面板内向导；已配置时底部「配置…」→ 修改模式。

enum PanelTab: String, CaseIterable, Identifiable {
    case overview, profiles, diagnostics, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return L10n.tr("tab.overview")
        case .profiles: return L10n.tr("tab.profiles")
        case .diagnostics: return L10n.tr("tab.diagnostics")
        case .settings: return L10n.tr("tab.settings")
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var vpn: VPNManager
    @State private var selectedTab: PanelTab = .overview
    @State private var showSettings = false // 保留兼容：EngineWarn 仍可跳设置 Tab
    @State private var showSetup = false
    @State private var setupMode: SetupMode = .import

    var body: some View {
        Group {
            if showSetup {
                SetupWizard(mode: setupMode) {
                    showSetup = false
                }
            } else if showSettings {
                // 兼容旧入口：直接切到 settings Tab
                mainPanel
                    .onAppear { selectedTab = .settings; showSettings = false }
            } else {
                mainPanel
            }
        }
        .padding(PanelMetrics.padding)
        .frame(width: PanelMetrics.width)
        .background(
            ZStack {
                VisualEffectView(material: .menu, blendingMode: .behindWindow)
                Design.paper.opacity(0.92)
            }
        )
        .animation(.easeInOut(duration: 0.2), value: showSetup)
        .animation(.easeInOut(duration: 0.2), value: selectedTab)
    }

    private var mainPanel: some View {
        VStack(spacing: 10) {
            Picker("", selection: $selectedTab) {
                ForEach(PanelTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            StatusHeader()

            switch selectedTab {
            case .overview:
                overviewTab
            case .profiles:
                profilesTab
            case .diagnostics:
                diagnosticsTab
            case .settings:
                settingsTab
            }

            FooterQuit()
        }
    }

    // MARK: - Tabs

    private var overviewTab: some View {
        VStack(spacing: 8) {
            PrimaryActionButton {
                setupMode = .import
                showSetup = true
            }
            EngineWarnRow { selectedTab = .settings }
            Hairline()
            AutoReconnectRow()
            EventRow()
        }
    }

    private var profilesTab: some View {
        VStack(spacing: 8) {
            ProfilesInlineSection(onEdit: { setupMode = .edit; showSetup = true }, onImport: { setupMode = .import; showSetup = true })
        }
    }

    private var diagnosticsTab: some View {
        DiagnosticsSection()
    }

    private var settingsTab: some View {
        VStack(spacing: 8) {
            SettingsAuthSection(onAuthorize: { vpn.authorizeEngine() })
            PreferencesSection()
        }
    }
}

// 轻量内联版：复用 SettingsConfigSection 的多配置列表，去标题与外框
private struct ProfilesInlineSection: View {
    @EnvironmentObject private var vpn: VPNManager
    let onEdit: () -> Void
    let onImport: () -> Void
    var body: some View {
        SettingsConfigSection(onEdit: onEdit, onImport: onImport, onClear: { vpn.clearConfig() })
    }
}

private struct PreferencesSection: View {
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label(L10n.tr("launchAtLogin"), systemImage: "power").font(.system(size: 11)).foregroundStyle(Design.ink2)
                Spacer()
                Toggle("", isOn: Binding(get: { LaunchAtLogin.isEnabled }, set: { LaunchAtLogin.setEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            HStack {
                Label(L10n.tr("notifications"), systemImage: "bell").font(.system(size: 11)).foregroundStyle(Design.ink2)
                Spacer()
                Toggle("", isOn: Binding(get: { UserDefaults.standard.bool(forKey: "notifyEnabled") }, set: { UserDefaults.standard.set($0, forKey: "notifyEnabled"); if $0 { NotificationService.requestAuthorizationIfNeeded() } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Design.paper2))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Design.rule, lineWidth: 1))
    }
}

// MARK: - 向导模式

enum SetupMode {
    case `import`
    case edit
}

// MARK: - 细分隔线

private struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Design.rule)
            .frame(height: 1)
            .padding(.horizontal, 2)
    }
}

// MARK: - 1. 状态块（图标瓷砖 + 状态点 + 标题 + 时长 + 元信息）

private struct StatusHeader: View {
    @EnvironmentObject private var vpn: VPNManager

    private var isBusy: Bool { vpn.status.isBusy }

    /// 状态瓷砖配色（图标 + 底色）
    private var tile: (bg: Color, fg: Color) {
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

    private var titleText: String { vpn.status.title }

    private var durationColor: Color {
        switch vpn.status {
        case .connected: return Design.ok
        case .connecting, .reconnecting: return Design.busy
        case .disconnected, .unconfigured: return Design.ink3
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tile.bg)
                    .frame(width: 28, height: 28)
                Image(systemName: vpn.status.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tile.fg)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: vpn.status)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    PulsingDot(color: dotColor, isBusy: isBusy)
                    Text(titleText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Design.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    DurationText(status: vpn.status, connectedAt: vpn.connectedAt, color: durationColor)
                }
                MetaTextView(
                    status: vpn.status,
                    profileName: vpn.profileName,
                    reconnectCount: vpn.reconnectCount,
                    retryDeadline: vpn.retryDeadline
                )
            }
        }
    }
}

private struct PulsingDot: View {
    let color: Color
    let isBusy: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(isBusy ? (pulse ? 0.3 : 1) : 1)
            .animation(isBusy ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { if isBusy { pulse = true } }
            .onChange(of: isBusy) { busy in
                if busy { pulse = true } else { pulse = false }
            }
    }
}

private struct DurationText: View {
    let status: VPNStatus
    let connectedAt: Date?
    let color: Color
    @ObservedObject private var tick = TickProvider.shared

    var body: some View {
        let _ = tick.now // 订阅 tick，仅此子视图刷新
        let text: String = {
            guard case .connected = status, let start = connectedAt else { return "--:--:--" }
            let elapsed = Int(tick.now.timeIntervalSince(start))
            let h = elapsed / 3600
            let m = (elapsed % 3600) / 60
            let s = elapsed % 60
            return String(format: "%02d:%02d:%02d", h, m, s)
        }()
        Text(text)
            .font(.system(size: 12, design: .monospaced).monospacedDigit())
            .foregroundStyle(color)
    }
}

private struct MetaTextView: View {
    let status: VPNStatus
    let profileName: String
    let reconnectCount: Int
    let retryDeadline: Date?
    @ObservedObject private var tick = TickProvider.shared

    var body: some View {
        let _ = tick.now
        let text: String = {
            switch status {
            case .unconfigured: return L10n.tr("notConfigured")
            case .connected:
                var s = "VPNStatusBar · \(profileName) · 10.8.0.0/16"
                if reconnectCount > 0 { s += L10n.tr("status.reconnected.suffix", reconnectCount) }
                return s
            case .reconnecting:
                let remaining: Int = {
                    guard let d = retryDeadline else { return 0 }
                    return max(0, Int(d.timeIntervalSince(tick.now).rounded(.up)))
                }()
                return L10n.tr("status.retry", remaining)
            case .connecting: return L10n.tr("status.connecting.hint")
            case .disconnected: return "VPNStatusBar · \(profileName)"
            }
        }()
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Design.ink2)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

// MARK: - 2. 主操作按钮（随状态反色：连接=绿 / 断开=红 / 忙=禁用+加载 / 未配置=导入）

private struct PrimaryActionButton: View {
    @EnvironmentObject private var vpn: VPNManager
    let onImport: () -> Void
    @State private var hover = false

    init(onImport: @escaping () -> Void = {}) {
        self.onImport = onImport
    }

    private var isDisabled: Bool {
        if case .connecting = vpn.status { return true }
        return false
    }

    private var label: String {
        switch vpn.status {
        case .unconfigured: return L10n.tr("status.import")
        case .disconnected: return L10n.tr("status.connect")
        case .connected: return L10n.tr("status.disconnect")
        case .connecting: return L10n.tr("status.connecting")
        case .reconnecting: return L10n.tr("status.reconnectNow")
        }
    }

    private var icon: String? {
        switch vpn.status {
        case .unconfigured: return "tray.and.arrow.down"
        case .disconnected: return "play"
        case .connected: return "stop"
        case .connecting: return nil
        case .reconnecting: return "arrow.clockwise"
        }
    }

    /// 按钮配色（底色 / 加深底色 / 描边 / 文字）
    private var palette: (bg: Color, bgHover: Color, border: Color, fg: Color) {
        switch vpn.status {
        case .unconfigured: return (Design.paper2, Design.paper3, Design.rule, Design.ink2)
        case .disconnected: return (Design.okSoft, Design.okSoft2, Design.okRule, Design.okInk)
        case .connected: return (Design.dangerSoft, Design.dangerSoft2, Design.dangerRule, Design.dangerInk)
        case .connecting, .reconnecting: return (Design.paper2, Design.paper3, Design.rule, Design.ink2)
        }
    }

    private func action() {
        switch vpn.status {
        case .unconfigured: onImport() // 打开导入向导
        case .disconnected: vpn.connect()
        case .connected: vpn.disconnect()
        case .reconnecting: vpn.reconnectNow()
        case .connecting: break
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isDisabled {
                    ProgressView()
                        .controlSize(.small)
                        .tint(palette.fg)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(palette.fg)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill((hover && !isDisabled) ? palette.bgHover : palette.bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
        .onHover { hovering in hover = hovering }
    }
}

// MARK: - 3. 断线自动重连开关

private struct AutoReconnectRow: View {
    @EnvironmentObject private var vpn: VPNManager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12))
                .foregroundStyle(Design.ink2)
                .frame(width: 16)
            Text(L10n.tr("autoreconnect.title"))
                .font(.system(size: 13))
                .foregroundStyle(Design.ink)
            Spacer()
            Toggle("", isOn: $vpn.autoReconnect)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(vpn.isConfigured ? Design.switchTrack : Design.ink3)
                .disabled(!vpn.isConfigured)
                .controlSize(.small)
        }
    }
}

// MARK: - 4. 最近事件

private struct EventRow: View {
    @EnvironmentObject private var vpn: VPNManager

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(Design.ink3)
            Text(vpn.lastEvent)
                .font(.system(size: 11))
                .foregroundStyle(Design.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 4.5 VPN 引擎警示行（未授权 / 异常时显示，点击进设置）

private struct EngineWarnRow: View {
    @EnvironmentObject private var vpn: VPNManager
    let onOpenSettings: () -> Void
    @State private var hover = false

    private var needsAttention: Bool {
        switch vpn.engineAuth {
        case .unauthorized, .broken: return true
        default: return false
        }
    }

    var body: some View {
        Group {
            if needsAttention {
                Button(action: onOpenSettings) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                        Text(vpn.engineAuth == .broken
                             ? L10n.tr("engine.warn.broken")
                             : L10n.tr("engine.warn.unauthorized"))
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(L10n.tr("engine.warn.settings"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Design.dangerInk)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 6)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(hover ? Design.dangerSoft2 : Design.dangerSoft)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Design.dangerRule, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in hover = hovering }
                .transition(.opacity)
            }
        }
    }
}

// MARK: - 5. 可折叠日志（断连/重连时自动展开）

private struct DiagnosticsSection: View {
    @EnvironmentObject private var vpn: VPNManager
    @State private var expanded = true
    @State private var cachedLines: [String] = []

    private func makeLines(from tail: String) -> [String] {
        let lines = tail.split(separator: "\n").map(String.init).prefix(6)
        return lines.map { line in
            if line.count <= 56 { return line }
            return String(line.prefix(53)) + "…"
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 2) {
                if cachedLines.isEmpty {
                    Text(L10n.tr("log.empty"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Design.ink3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(cachedLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Design.ink2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Design.paper3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Design.rule, lineWidth: 1)
            )
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(Design.ink2)
                Text(L10n.tr("log.title"))
                    .font(.system(size: 12))
                    .foregroundStyle(Design.ink2)
                Spacer()
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .frame(height: 26)
        }
        .tint(Design.ink3)
        .onAppear { cachedLines = makeLines(from: vpn.logTail) }
        .onChange(of: vpn.logTail) { tail in
            cachedLines = makeLines(from: tail)
        }
        .onChange(of: vpn.status) { newStatus in
            switch newStatus {
            case .reconnecting, .connecting:
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { expanded = true }
            default:
                break
            }
        }
    }
}

// MARK: - 6. 设置入口（打开独立设置页：授权 + 配置管理）

private struct SettingsRow: View {
    let onTap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
                    .foregroundStyle(Design.ink2)
                Text(L10n.tr("settings.title") + "…")
                    .font(.system(size: 12))
                    .foregroundStyle(Design.ink2)
                Spacer()
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hover ? Design.paper2 : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in hover = hovering }
    }
}

// MARK: - 7. 退出

private struct FooterQuit: View {
    @EnvironmentObject private var vpn: VPNManager
    @State private var hover = false

    var body: some View {
        Button(action: {
            vpn.shutdown()
            NSApp.terminate(nil)
        }) {
            HStack(spacing: 6) {
                Image(systemName: "power")
                    .font(.system(size: 11))
                    .foregroundStyle(Design.ink2)
                Text(L10n.tr("quit"))
                    .font(.system(size: 12))
                    .foregroundStyle(Design.ink2)
                Spacer()
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hover ? Design.paper2 : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in hover = hovering }
    }
}

// MARK: - 8. 设置页（授权 · VPN 引擎 + 连接配置）

struct SettingsView: View {
    @EnvironmentObject private var vpn: VPNManager
    let onBack: () -> Void
    @State private var showSetup = false
    @State private var setupMode: SetupMode = .import
    @State private var hover = false

    var body: some View {
        Group {
            if showSetup {
                SetupWizard(mode: setupMode) {
                    showSetup = false
                }
            } else {
                settingsBody
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showSetup)
    }

    private var settingsBody: some View {
        VStack(spacing: 8) {
            // 头部：返回 + 标题
            HStack(spacing: 6) {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Design.ink2)
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(hover ? Design.paper2 : .clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { h in hover = h }

                Text(L10n.tr("settings.title"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Design.ink2)
                Spacer()
            }
            .frame(height: 22)

            SettingsAuthSection(
                onAuthorize: { vpn.authorizeEngine() }
            )

            SettingsConfigSection(
                onEdit: { setupMode = .edit; showSetup = true },
                onImport: { setupMode = .import; showSetup = true },
                onClear: { vpn.clearConfig() }
            )

            Spacer(minLength: 0)
        }
    }
}

// MARK: - 8.1 授权 · VPN 引擎

private struct SettingsAuthSection: View {
    @EnvironmentObject private var vpn: VPNManager
    let onAuthorize: () -> Void

    private var auth: EngineAuth { vpn.engineAuth }

    private var head: (bg: Color, icon: String, iconBg: Color, iconFg: Color, title: String, sub: String) {
        switch auth {
        case .authorized:
            return (Design.okSoft, "checkmark", Design.okSoft2, Design.okInk,
                    L10n.tr("auth.engine.authorized"), L10n.tr("auth.engine.authorized.desc"))
        case .authorizing:
            return (Design.busySoft, "clock", Design.busySoft, Design.busyInk,
                    L10n.tr("auth.engine.authorizing"), L10n.tr("auth.engine.authorizing.desc"))
        case .unauthorized:
            return (Design.paper2, "lock", Design.paper2, Design.ink3,
                    L10n.tr("auth.engine.unauthorized"), L10n.tr("auth.engine.unauthorized.desc"))
        case .broken:
            return (Design.dangerSoft, "exclamationmark.triangle.fill", Design.dangerSoft2, Design.dangerInk,
                    L10n.tr("auth.engine.broken"), L10n.tr("auth.engine.broken.desc"))
        case .checking:
            return (Design.paper2, "clock", Design.paper2, Design.ink3,
                    L10n.tr("auth.engine.checking"), L10n.tr("auth.engine.checking.desc"))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label {
                Text(L10n.tr("auth.engine"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Design.ink2)
            } icon: {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 11))
                    .foregroundStyle(Design.ink2)
            }

            VStack(spacing: 0) {
                // 状态卡头部
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(head.iconBg)
                            .frame(width: 26, height: 26)
                        Image(systemName: head.icon)
                            .font(.system(size: 13))
                            .foregroundStyle(head.iconFg)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(head.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Design.ink)
                        Text(head.sub)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Design.ink3)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(head.bg)
                )

                if auth == .authorized {
                    kvRow(L10n.tr("auth.path"), "/usr/local/vpnstatusbar/openvpn", mono: true)
                    kvRow(L10n.tr("auth.arch"), "arm64", mono: false)
                }

                // 操作按钮
                VStack(spacing: 6) {
                    switch auth {
                    case .unauthorized:
                        authButton(L10n.tr("auth.authorize"), Design.okSoft, Design.okSoft2, Design.okRule, Design.okInk, action: onAuthorize)
                    case .authorizing:
                        authButtonDisabled(L10n.tr("auth.authorizing"), spinner: true)
                    case .broken:
                        authButton(L10n.tr("auth.repair"), Design.dangerSoft, Design.dangerSoft2, Design.dangerRule, Design.dangerInk, action: onAuthorize)
                    case .authorized:
                        authButton(L10n.tr("auth.reauthorize"), Design.paper2, Design.paper3, Design.rule, Design.ink2, action: onAuthorize)
                    case .checking:
                        authButtonDisabled(L10n.tr("auth.checking"), spinner: false)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Design.paper2)
                )
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Design.rule, lineWidth: 1)
            )

            Text(L10n.tr("auth.engine.hint"))
                .font(.system(size: 10))
                .foregroundStyle(Design.ink3)
                .lineSpacing(2)
        }
    }

    private func kvRow(_ k: String, _ v: String, mono: Bool) -> some View {
        HStack(spacing: 6) {
            Text(k)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Design.ink3)
                .frame(width: 48, alignment: .leading)
            Text(v)
                .font(.system(size: mono ? 10.5 : 11, design: mono ? .monospaced : .default))
                .foregroundStyle(Design.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Design.paper2)
    }

    private func authButton(_ t: String, _ bg: Color, _ bgH: Color, _ bd: Color, _ fg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(fg)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(bg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(bd, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func authButtonDisabled(_ t: String, spinner: Bool) -> some View {
        HStack(spacing: 6) {
            if spinner {
                ProgressView()
                    .controlSize(.small)
            }
            Text(t)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Design.ink3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Design.paper2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Design.rule, lineWidth: 1)
        )
    }
}

// MARK: - 8.2 连接配置

private struct SettingsConfigSection: View {
    @EnvironmentObject private var vpn: VPNManager
    let onEdit: () -> Void
    let onImport: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label {
                Text(L10n.tr("connection.config"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Design.ink2)
            } icon: {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(Design.ink2)
            }

            VStack(spacing: 0) {
                if vpn.profiles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("connection.notConfigured"))
                            .font(.system(size: 12))
                            .foregroundStyle(Design.ink2)
                        cfgButton(L10n.tr("connection.import"), Design.okSoft, Design.okSoft2, Design.okRule, Design.okInk, action: onImport)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(Design.paper2)
                } else {
                    // 多配置列表（最多显示全部，active 高亮）
                    ForEach(vpn.profiles, id: \.id) { p in
                        let isActive = vpn.activeProfile?.id == p.id
                        Button(action: { vpn.switchProfile(id: p.id) }) {
                            HStack(spacing: 6) {
                                Image(systemName: isActive ? "checkmark.circle.fill" : "doc")
                                    .font(.system(size: 11))
                                    .foregroundStyle(isActive ? Design.ok : Design.ink3)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Design.ink).lineLimit(1)
                                    Text(p.serverAddress).font(.system(size: 10)).foregroundStyle(Design.ink3).lineLimit(1)
                                }
                                Spacer()
                                if vpn.profiles.count > 1 {
                                    Button(action: { vpn.deleteProfile(id: p.id) }) {
                                        Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(Design.danger)
                                    }.buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(isActive ? Design.okSoft.opacity(0.6) : Design.paper2)
                        }.buttonStyle(.plain)
                        Divider().overlay(Design.rule)
                    }
                    cfgRow(L10n.tr("connection.current"), vpn.profileName)
                    cfgRow(L10n.tr("connection.server"), vpn.serverAddress)
                    cfgRow(L10n.tr("connection.username"), vpn.username)
                    VStack(spacing: 6) {
                        cfgButton(L10n.tr("connection.edit"), Design.paper2, Design.paper3, Design.rule, Design.ink2, action: onEdit)
                        cfgButton(L10n.tr("connection.add"), Design.okSoft, Design.okSoft2, Design.okRule, Design.okInk, action: onImport)
                        Button(action: onClear) {
                            Text(L10n.tr("connection.deleteCurrent")).font(.system(size: 11)).foregroundStyle(Design.danger)
                        }.buttonStyle(.plain)
                    }
                    .padding(.top, 8).padding(.horizontal, 10).padding(.bottom, 10)
                    .frame(maxWidth: .infinity).background(Design.paper2)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Design.rule, lineWidth: 1)
            )
        }
    }

    private func cfgRow(_ k: String, _ v: String) -> some View {
        HStack(spacing: 6) {
            Text(k)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Design.ink3)
                .frame(width: 48, alignment: .leading)
            Text(v)
                .font(.system(size: 11))
                .foregroundStyle(Design.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Design.paper2)
    }

    private func cfgButton(_ t: String, _ bg: Color, _ bgH: Color, _ bd: Color, _ fg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(fg)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(bg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(bd, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 初始化向导（面板内三步：选文件 → 鉴权 → 保存完成）

struct SetupWizard: View {
    @EnvironmentObject private var vpn: VPNManager
    let mode: SetupMode
    let onDone: () -> Void

    @State private var step = 1
    @State private var pickedURL: URL?
    @State private var pickedName = ""
    @State private var fileSummary = ""
    @State private var username = ""
    @State private var password = ""
    @State private var errorText = ""

    private var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 10) {
            // 头部：返回 + 标题 + 步骤
            HStack(spacing: 6) {
                Button {
                    onDone()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Design.ink2)
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(hover ? Design.paper2 : .clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { h in hover = h }

                Text(L10n.tr("wizard.step", isEdit ? L10n.tr("wizard.editTitle") : L10n.tr("wizard.importTitle"), step))
                    .font(.system(size: 12))
                    .foregroundStyle(Design.ink2)
                Spacer()
            }
            .frame(height: 22)

            switch step {
            case 1: stepFile
            case 2: stepAuth
            default: stepDone
            }
        }
    }

    @State private var hover = false

    // MARK: 步骤 1：选择 ovpn 文件

    private var stepFile: some View {
        VStack(spacing: 8) {
            // 拖放区
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Design.rule, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(height: 84)
                .overlay(
                    VStack(spacing: 4) {
                        Image(systemName: "doc")
                            .font(.system(size: 16))
                            .foregroundStyle(Design.ink3)
                        Text(L10n.tr("wizard.drop"))
                            .font(.system(size: 12))
                            .foregroundStyle(Design.ink2)
                        Button(L10n.tr("wizard.selectFile")) {
                            pickFile()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Design.focusRing)
                        .underline()
                    }
                )
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers)
                }

            if !pickedName.isEmpty {
                // 文件摘要卡片
                HStack(spacing: 8) {
                    Image(systemName: "doc")
                        .font(.system(size: 14))
                        .foregroundStyle(Design.okInk)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pickedName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Design.ink)
                            .lineLimit(1)
                        Text(fileSummary)
                            .font(.system(size: 10))
                            .foregroundStyle(Design.ink3)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Design.paper2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Design.rule, lineWidth: 1)
                )
            }

            if !errorText.isEmpty {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(Design.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                step = 2
            } label: {
                Text(L10n.tr("wizard.next"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Design.okInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Design.okSoft)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Design.okRule, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(pickedName.isEmpty ? true : false)
            .opacity(pickedName.isEmpty ? 0.45 : 1)

            if isEdit {
                // 修改模式：保留当前配置直接下一步
                Button(L10n.tr("wizard.keepCurrent")) {
                    step = 2
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Design.ink3)
                .underline()
            }
        }
    }

    // MARK: 步骤 2：鉴权信息

    private var stepAuth: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("wizard.username"))
                    .font(.system(size: 11))
                    .foregroundStyle(Design.ink2)
                TextField(L10n.tr("wizard.username.placeholder"), text: $username)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Design.paper2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Design.rule, lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("wizard.password"))
                    .font(.system(size: 11))
                    .foregroundStyle(Design.ink2)
                SecureField(isEdit ? L10n.tr("wizard.password.keep") : "••••••••", text: $password)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Design.paper2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Design.rule, lineWidth: 1)
                    )
            }

            Text(isEdit ? L10n.tr("wizard.password.hint.edit") : L10n.tr("wizard.password.hint"))
                .font(.system(size: 10))
                .foregroundStyle(Design.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !errorText.isEmpty {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(Design.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 6) {
                Button {
                    save()
                } label: {
                    Text(L10n.tr("wizard.save"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isValidAuth ? Design.okInk : Design.ink3)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isValidAuth ? Design.okSoft : Design.paper2)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(isValidAuth ? Design.okRule : Design.rule, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!isValidAuth)

                Button(L10n.tr("wizard.back")) {
                    step = 1
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Design.ink2)
            }
        }
        .onAppear {
            // 修改模式：预填当前用户名（不含密码，留空=保持原密码）
            if isEdit && username.isEmpty {
                username = vpn.username
            }
        }
    }

    private var isValidAuth: Bool {
        !username.isEmpty && (!password.isEmpty || isEdit)
    }

    // MARK: 步骤 3：保存完成

    private var stepDone: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Design.ok)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isEdit ? L10n.tr("wizard.updated") : L10n.tr("wizard.saved"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Design.ink)
                    Text(L10n.tr("wizard.saved.desc", pickedName, username))
                        .font(.system(size: 11))
                        .foregroundStyle(Design.ink2)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Design.paper2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Design.rule, lineWidth: 1)
            )

            Button {
                onDone()
            } label: {
                Text(L10n.tr("wizard.done"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Design.okInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Design.okSoft)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Design.okRule, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 文件选择

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("wizard.pick.title")
        panel.allowedContentTypes = [UTType(filenameExtension: "ovpn") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            loadFile(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                DispatchQueue.main.async {
                    self.loadFile(url)
                }
            }
        }
        return true
    }

    private func loadFile(_ url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            errorText = "无法读取文件：\(url.lastPathComponent)"
            return
        }
        guard content.contains("remote") || content.lowercased().contains("client") else {
            errorText = "该文件不是有效的 OpenVPN 配置（缺少 remote/client 指令）"
            return
        }
        pickedURL = url
        pickedName = url.lastPathComponent
        fileSummary = summarize(content)
        username = isEdit ? vpn.username : username
        errorText = ""
    }

    /// 从 ovpn 内容提取摘要信息
    private func summarize(_ content: String) -> String {
        var parts: [String] = []
        for line in content.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("remote ") {
                parts.append("remote \(t.dropFirst(7).trimmingCharacters(in: .whitespaces))")
            } else if t.hasPrefix("proto ") {
                parts.append("proto \(t.dropFirst(6).trimmingCharacters(in: .whitespaces))")
            } else if t.hasPrefix("ifconfig ") || t.hasPrefix("route ") {
                parts.append("\(t)")
            }
            if parts.count >= 3 { break }
        }
        if parts.isEmpty { parts.append("标准 OpenVPN 配置") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 保存

    private func save() {
        guard let url = pickedURL else {
            errorText = "请先选择 ovpn 文件"
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            errorText = "读取配置文件失败"
            return
        }
        let pass = password.isEmpty ? nil : password
        vpn.saveConfig(ovpnData: data,
                       fileName: pickedName,
                       username: username,
                       password: pass)
        step = 3
    }
}