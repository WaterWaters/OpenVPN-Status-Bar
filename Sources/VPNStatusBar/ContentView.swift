import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VPNStatusBarCore

// MARK: - 主面板（对应 design/mockup.html 面板设计）
// 结构：状态块 → 主操作按钮 → 自动重连开关 → 最近事件 → 可折叠日志 → 配置 → 退出
// 未配置时主操作 = 「导入配置…」→ 打开面板内向导；已配置时底部「配置…」→ 修改模式。

struct ContentView: View {
    @EnvironmentObject private var vpn: VPNManager
    @State private var showSettings = false
    @State private var showSetup = false
    @State private var setupMode: SetupMode = .import

    var body: some View {
        Group {
            if showSettings {
                SettingsView {
                    showSettings = false
                }
            } else if showSetup {
                SetupWizard(mode: setupMode) {
                    showSetup = false
                }
            } else {
                mainPanel
            }
        }
        .padding(PanelMetrics.padding)
        .frame(width: PanelMetrics.width)
        .background(Design.paper)
        .animation(.easeInOut(duration: 0.2), value: showSettings || showSetup)
    }

    private var mainPanel: some View {
        VStack(spacing: 8) {
            StatusHeader()

            PrimaryActionButton {
                setupMode = .import
                showSetup = true
            }

            EngineWarnRow {
                showSettings = true
            }

            Hairline()

            AutoReconnectRow()

            EventRow()

            DiagnosticsSection()

            Hairline()

            SettingsRow {
                showSettings = true
            }

            FooterQuit()
        }
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
    @State private var pulse = false

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

    private var titleText: String {
        switch vpn.status {
        case .unconfigured: return "未配置"
        case .disconnected: return "已断开"
        case .connecting: return "连接中…"
        case .connected: return "已连接"
        case .reconnecting: return "重连中 · 第 \(vpn.reconnectCount) 次"
        }
    }

    private var durationText: String {
        switch vpn.status {
        case .connected: return vpn.formattedDuration()
        default: return "--:--:--"
        }
    }

    private var durationColor: Color {
        switch vpn.status {
        case .connected: return Design.ok
        case .connecting, .reconnecting: return Design.busy
        case .disconnected, .unconfigured: return Design.ink3
        }
    }

    private var metaText: String {
        switch vpn.status {
        case .unconfigured:
            return "导入 VPN 配置后开始"
        case .connected:
            var s = "VPNStatusBar · \(vpn.profileName) · 隧道 10.8.0.0/16"
            if vpn.reconnectCount > 0 { s += " · 已重连 \(vpn.reconnectCount) 次" }
            return s
        case .reconnecting:
            return "\(vpn.retryRemaining) 秒后自动重试"
        case .connecting:
            return "正在建立隧道…"
        case .disconnected:
            return "VPNStatusBar · \(vpn.profileName)"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // 图标瓷砖
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tile.bg)
                    .frame(width: 28, height: 28)
                Image(systemName: vpn.status.symbolName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tile.fg)
            }

            VStack(alignment: .leading, spacing: 2) {
                // 标题行：状态点 + 标题 + 时长
                HStack(spacing: 6) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                        .opacity(isBusy ? (pulse ? 0.3 : 1) : 1)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                pulse = true
                            }
                        }
                    Text(titleText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Design.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(durationText)
                        .font(.system(size: 12, design: .monospaced).monospacedDigit())
                        .foregroundStyle(durationColor)
                }
                // 元信息行
                Text(metaText)
                    .font(.system(size: 11))
                    .foregroundStyle(Design.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
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
        case .unconfigured: return "导入配置…"
        case .disconnected: return "连接 VPN"
        case .connected: return "断开 VPN"
        case .connecting: return "连接中…"
        case .reconnecting: return "立即重连"
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
            Text("断线自动重连")
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
                             ? "VPN 引擎异常，需修复"
                             : "VPN 引擎未授权，可能无法连接")
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text("设置 ›")
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

    /// 日志按行拆分（最多 6 行，超长行中点截断，避免撑爆面板/显示不全）
    private var logLines: [String] {
        let lines = vpn.logTail.split(separator: "\n").map(String.init).prefix(6)
        return lines.map { line in
            if line.count <= 56 { return line }
            return String(line.prefix(53)) + "…"
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.25)) {
                    expanded.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundStyle(Design.ink2)
                    Text("日志")
                        .font(.system(size: 12))
                        .foregroundStyle(Design.ink2)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Design.ink3)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 6)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Design.paper2)
                )
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    if logLines.isEmpty {
                        Text("（暂无日志）")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Design.ink3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
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
            }
        }
        .onChange(of: vpn.status) { newStatus in
            // 重连 / 连接中自动展开日志
            switch newStatus {
            case .reconnecting, .connecting:
                withAnimation(.easeInOut(duration: 0.25)) { expanded = true }
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
                Text("设置…")
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
                Text("退出 VPNStatusBar")
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

                Text("设置")
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
                    "VPN 引擎 · 已授权", "openvpn 2.6.14 · arm64 · 稳定免密授权")
        case .authorizing:
            return (Design.busySoft, "clock", Design.busySoft, Design.busyInk,
                    "VPN 引擎 · 授权中…", "正在写入免密规则 / 安装引擎…")
        case .unauthorized:
            return (Design.paper2, "lock", Design.paper2, Design.ink3,
                    "VPN 引擎 · 未授权", "需一次授权以建立 VPN 隧道")
        case .broken:
            return (Design.dangerSoft, "exclamationmark.triangle.fill", Design.dangerSoft2, Design.dangerInk,
                    "VPN 引擎 · 异常", "引擎二进制缺失或被移动，需修复")
        case .checking:
            return (Design.paper2, "clock", Design.paper2, Design.ink3,
                    "VPN 引擎 · 检测中…", "请稍候")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label {
                Text("授权 · VPN 引擎")
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
                    kvRow("路径", "/usr/local/vpnstatusbar/openvpn", mono: true)
                    kvRow("架构", "arm64（Intel 机器自编译对应版本）", mono: false)
                }

                // 操作按钮
                VStack(spacing: 6) {
                    switch auth {
                    case .unauthorized:
                        authButton("授权 VPN…", Design.okSoft, Design.okSoft2, Design.okRule, Design.okInk, action: onAuthorize)
                    case .authorizing:
                        authButtonDisabled("授权中…", spinner: true)
                    case .broken:
                        authButton("修复并重新授权…", Design.dangerSoft, Design.dangerSoft2, Design.dangerRule, Design.dangerInk, action: onAuthorize)
                    case .authorized:
                        authButton("重新授权…", Design.paper2, Design.paper3, Design.rule, Design.ink2, action: onAuthorize)
                    case .checking:
                        authButtonDisabled("检测中…", spinner: false)
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

            Text("授权用于以系统管理员身份建立 VPN 隧道，仅需一次。若授权弹窗被误关，点上方按钮再次发起即可。")
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
                Text("连接配置")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Design.ink2)
            } icon: {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(Design.ink2)
            }

            VStack(spacing: 0) {
                if vpn.isConfigured {
                    cfgRow("配置", vpn.profileName)
                    cfgRow("服务器", vpn.serverAddress)
                    cfgRow("用户名", vpn.username)
                    VStack(spacing: 6) {
                        cfgButton("修改配置…", Design.paper2, Design.paper3, Design.rule, Design.ink2, action: onEdit)
                        Button(action: onClear) {
                            Text("清除配置…")
                                .font(.system(size: 11))
                                .foregroundStyle(Design.danger)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity)
                    .background(Design.paper2)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("尚未导入配置")
                            .font(.system(size: 12))
                            .foregroundStyle(Design.ink2)
                        cfgButton("导入配置…", Design.okSoft, Design.okSoft2, Design.okRule, Design.okInk, action: onImport)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(Design.paper2)
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

                Text("\(isEdit ? "修改配置" : "配置 VPN") · 第 \(step) / 3 步")
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
                        Text("把 .ovpn 文件拖到这里")
                            .font(.system(size: 12))
                            .foregroundStyle(Design.ink2)
                        Button("选择文件…") {
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
                Text("下一步")
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
                Button("保留当前配置，直接修改凭据") {
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
                Text("用户名")
                    .font(.system(size: 11))
                    .foregroundStyle(Design.ink2)
                TextField("例如 user01", text: $username)
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
                Text("密码")
                    .font(.system(size: 11))
                    .foregroundStyle(Design.ink2)
                SecureField(isEdit ? "留空保持原密码" : "••••••••", text: $password)
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

            Text(isEdit
                 ? "密码留空表示保持原密码；仅在填写时更新。"
                 : "密码仅存入 macOS 钥匙串（Keychain），连接时临时生成认证文件，断开即删除。")
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
                    Text("保存并完成")
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

                Button("上一步") {
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
                    Text(isEdit ? "配置已更新" : "配置已保存")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Design.ink)
                    Text("\(pickedName) · \(username) · 密码已存入钥匙串")
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
                Text("完成")
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
        panel.title = "选择 OpenVPN 配置文件"
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