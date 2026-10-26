import SwiftUI

import AppKit

import UniformTypeIdentifiers

import VPNStatusBarCore

// MARK: - 面板组成见 PanelLayout.swift（卡片/状态块/日志卡/授权卡/配置卡/偏好卡/底部行）

enum PanelTab: String, CaseIterable, Identifiable {
    case overview, profiles, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return L10n.tr("tab.overview")
        case .profiles: return L10n.tr("tab.profiles")
        case .settings: return L10n.tr("tab.settings")
        }
    }
}

// MARK: - 主面板
//
// 布局约定（配合 PanelMetrics.height 的固定高度）：
//   分段标签 → 状态块 → 主操作 → [各标签内容（固定高度内自适应/滚动）] → 底部一行（自动重连 + 退出）
// 固定高度让窗口尺寸在打开期间恒定：不会错位、不会闪烁、也不会留下吞点击的透明区域。
struct ContentView: View {
    @EnvironmentObject private var vpn: VPNManager
    @State private var selectedTab: PanelTab = .overview
    @State private var showSetup = false
    @State private var setupMode: SetupMode = .import
    /// 「修改」针对的是哪一个档案（向导据此预填并原地保存）
    @State private var editingProfileId: String?

    var body: some View {
        Group {
            if showSetup {
                SetupWizard(mode: setupMode, editingProfileId: editingProfileId) {
                    showSetup = false
                }
            } else {
                mainPanel
            }
        }
        .padding(PanelMetrics.padding)
        .frame(width: PanelMetrics.width, height: PanelMetrics.height)
        .background(
            ZStack {
                VisualEffectView(material: .menu, blendingMode: .behindWindow)
                Design.paper.opacity(0.92)
            }
        )
        // 注意：面板是**固定高度**，不要引入任何会改变面板高度的东西（动画/自适应高度窗口），
        // 也不要再按内容高度去手动对齐窗口 —— 那些都会把平台的"窗口高度不回收"行为放出来。
    }

    private var mainPanel: some View {
        VStack(spacing: 8) {
            Picker("", selection: $selectedTab) {
                ForEach(PanelTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            StatusBlock()

            switch selectedTab {
            case .overview: overviewTab
            case .profiles: profilesTab
            case .settings: settingsTab
            }

            PanelFooter()
        }
    }

    // MARK: - 各标签（都在固定高度内排布）

    private var overviewTab: some View {
        VStack(spacing: 6) {
            PrimaryActionButton {
                setupMode = .import
                showSetup = true
            }
            EngineWarnRow { selectedTab = .settings }
            EventRow()
            LogCard(maxLines: nil)          // 填满剩余高度（原来在「诊断」里，概览也能顺手看到）
        }
    }

    private var profilesTab: some View {
        ScrollView(.vertical) {
            VStack(spacing: 6) {
                ProfilesCard(onAdd: {
                    editingProfileId = nil
                    setupMode = .import
                    showSetup = true
                }, onEdit: { id in
                    editingProfileId = id
                    setupMode = .edit
                    showSetup = true
                })
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var settingsTab: some View {
        ScrollView(.vertical) {
            VStack(spacing: 6) {
                AuthCard(onAuthorize: { vpn.authorizeEngine() })
                PrefsCard()
                HStack(spacing: 6) {
                    VersionLine()
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

enum SetupMode {
    case `import`
    case edit
}

struct DurationText: View {
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
            .font(.system(size: Design.Font.label, design: .monospaced).monospacedDigit())
            .foregroundStyle(color)
    }
}

private struct PrimaryActionButton: View {
    @EnvironmentObject private var vpn: VPNManager
    let onImport: () -> Void

    /// connecting 超过这个时长才允许取消：正常连接 2–5 秒完成，避免手一抖把刚连上的连接掐了
    private static let cancelDelay: TimeInterval = 8
    @State private var cancelable = false
    @FocusState private var focused: Bool

    init(onImport: @escaping () -> Void = {}) {
        self.onImport = onImport
    }

    private var isConnecting: Bool {
        if case .connecting = vpn.status { return true }
        return false
    }

    /// 连接中先禁用（防重复点击）；超过阈值后解禁，按钮变成「取消连接」
    private var isDisabled: Bool { isConnecting && !cancelable }

    private var label: String {
        switch vpn.status {
        case .unconfigured: return L10n.tr("status.import")
        case .disconnected: return L10n.tr("status.connect")
        case .connected: return L10n.tr("status.disconnect")
        case .connecting: return cancelable ? L10n.tr("status.cancelConnect") : L10n.tr("status.connecting")
        case .reconnecting: return L10n.tr("status.reconnectNow")
        }
    }

    private var icon: String? {
        switch vpn.status {
        case .unconfigured: return "tray.and.arrow.down"
        case .disconnected: return "play"
        case .connected: return "stop"
        case .connecting: return cancelable ? "xmark" : nil
        case .reconnecting: return "arrow.clockwise"
        }
    }

    /// 按钮配色（随状态反色：连接=绿 / 断开=红 / 忙碌与未配置=中性）
    private var palette: PanelPalette {
        switch vpn.status {
        case .unconfigured: return .neutral
        case .disconnected: return .ok
        case .connected: return .danger
        case .connecting, .reconnecting: return .neutral
        }
    }

    private func action() {
        switch vpn.status {
        case .unconfigured: onImport() // 打开导入向导
        case .disconnected: vpn.connect()
        case .connected: vpn.disconnect()
        case .reconnecting: vpn.reconnectNow()
        case .connecting: if cancelable { vpn.disconnect() } // 卡住时给一条退出通道
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
                        .font(.system(size: Design.Font.caption, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: Design.Font.body, weight: .medium))
            }
        }
        .buttonStyle(PanelButtonStyle(palette: palette, hoverEnabled: true))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
        .keyboardShortcut(.defaultAction)
        .focusable()
        .focused($focused)
        .modifier(FocusRing(focused: focused))
        .task(id: isConnecting) {
            // 以「本次 connecting 的起点」计算剩余时间，面板中途打开也不会算错
            guard isConnecting else {
                cancelable = false
                return
            }
            let elapsed = Date().timeIntervalSince(vpn.connectingSince ?? Date())
            let remaining = Self.cancelDelay - elapsed
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled, isConnecting else { return }
            cancelable = true
        }
    }
}

struct SetupWizard: View {
    @EnvironmentObject private var vpn: VPNManager
    let mode: SetupMode
    /// 修改模式针对的档案 id（nil = 新增）
    let editingProfileId: String?
    let onDone: () -> Void

    @State private var step = 1
    @State private var pickedURL: URL?
    @State private var pickedName = ""
    @State private var fileSummary = ""
    @State private var username = ""
    @State private var password = ""
    @State private var errorText = ""
    @State private var hover = false
    @FocusState private var backFocused: Bool

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
                        .font(.system(size: Design.Font.caption, weight: .semibold))
                        .foregroundStyle(Design.ink2)
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: Design.Corner.compact, style: .continuous)
                                .fill(hover ? Design.paper2 : .clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { h in hover = h }
                .accessibilityLabel(L10n.tr("wizard.back"))
                .focusable()
                .focused($backFocused)
                .modifier(FocusRing(focused: backFocused, corner: Design.Corner.compact))

                Text(L10n.tr("wizard.step", isEdit ? L10n.tr("wizard.editTitle") : L10n.tr("wizard.importTitle"), step))
                    .font(.system(size: Design.Font.label))
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
        .onAppear { prefillForEditIfNeeded() }
    }

    // MARK: 步骤 1：选择 ovpn 文件

    private var stepFile: some View {
        VStack(spacing: 8) {
            // 拖放区
            RoundedRectangle(cornerRadius: Design.Corner.medium, style: .continuous)
                .strokeBorder(Design.rule, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(height: 84)
                .overlay(
                    VStack(spacing: 4) {
                        Image(systemName: "doc")
                            .font(.system(size: Design.Font.iconLarge))
                            .foregroundStyle(Design.ink3)
                        Text(L10n.tr("wizard.drop"))
                            .font(.system(size: Design.Font.label))
                            .foregroundStyle(Design.ink2)
                        Button(L10n.tr("wizard.selectFile")) {
                            pickFile()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: Design.Font.label))
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
                        .font(.system(size: Design.Font.icon))
                        .foregroundStyle(Design.okInk)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pickedName)
                            .font(.system(size: Design.Font.label, weight: .semibold))
                            .foregroundStyle(Design.ink)
                            .lineLimit(1)
                        Text(fileSummary)
                            .font(.system(size: Design.Font.hint))
                            .foregroundStyle(Design.ink3)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: Design.Corner.small, style: .continuous)
                        .fill(Design.paper2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Design.Corner.small, style: .continuous)
                        .strokeBorder(Design.rule, lineWidth: 1)
                )
            }

            if !errorText.isEmpty {
                Text(errorText)
                    .font(.system(size: Design.Font.caption))
                    .foregroundStyle(Design.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            PanelActionButton(title: L10n.tr("wizard.next"), enabled: !pickedName.isEmpty) {
                step = 2
            }
            .opacity(pickedName.isEmpty ? 0.45 : 1)

            if isEdit {
                // 修改模式：保留当前配置直接下一步
                Button(L10n.tr("wizard.keepCurrent")) {
                    step = 2
                }
                .buttonStyle(.plain)
                .font(.system(size: Design.Font.caption))
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
                    .font(.system(size: Design.Font.caption))
                    .foregroundStyle(Design.ink2)
                TextField(L10n.tr("wizard.username.placeholder"), text: $username)
                    .textFieldStyle(.plain)
                    .font(.system(size: Design.Font.label))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: Design.Corner.small, style: .continuous)
                            .fill(Design.paper2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Design.Corner.small, style: .continuous)
                            .strokeBorder(Design.rule, lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("wizard.password"))
                    .font(.system(size: Design.Font.caption))
                    .foregroundStyle(Design.ink2)
                SecureField(isEdit ? L10n.tr("wizard.password.keep") : "••••••••", text: $password)
                    .textFieldStyle(.plain)
                    .font(.system(size: Design.Font.label))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: Design.Corner.small, style: .continuous)
                            .fill(Design.paper2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Design.Corner.small, style: .continuous)
                            .strokeBorder(Design.rule, lineWidth: 1)
                    )
            }

            Text(isEdit ? L10n.tr("wizard.password.hint.edit") : L10n.tr("wizard.password.hint"))
                .font(.system(size: Design.Font.hint))
                .foregroundStyle(Design.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !errorText.isEmpty {
                Text(errorText)
                    .font(.system(size: Design.Font.caption))
                    .foregroundStyle(Design.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 6) {
                PanelActionButton(title: L10n.tr("wizard.save"),
                                  palette: isValidAuth ? .ok : .muted,
                                  enabled: isValidAuth) {
                    save()
                }

                Button(L10n.tr("wizard.back")) {
                    step = 1
                }
                .buttonStyle(.plain)
                .font(.system(size: Design.Font.label))
                .foregroundStyle(Design.ink2)
            }
        }
        .onAppear {
            // 修改模式：预填当前用户名（不含密码，留空=保持原密码）
            if isEdit, username.isEmpty {
                username = editingProfileId.flatMap { id in vpn.profiles.first(where: { $0.id == id })?.username }
                    ?? vpn.username
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
                    .font(.system(size: Design.Font.iconHero))
                    .foregroundStyle(Design.ok)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isEdit ? L10n.tr("wizard.updated") : L10n.tr("wizard.saved"))
                        .font(.system(size: Design.Font.body, weight: .semibold))
                        .foregroundStyle(Design.ink)
                    Text(L10n.tr("wizard.saved.desc", pickedName, username))
                        .font(.system(size: Design.Font.caption))
                        .foregroundStyle(Design.ink2)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: Design.Corner.large, style: .continuous)
                    .fill(Design.paper2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.Corner.large, style: .continuous)
                    .strokeBorder(Design.rule, lineWidth: 1)
            )

            PanelActionButton(title: L10n.tr("wizard.done")) {
                onDone()
            }
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
            errorText = L10n.tr("wizard.error.read", url.lastPathComponent)
            return
        }
        guard content.contains("remote") || content.lowercased().contains("client") else {
            errorText = L10n.tr("wizard.error.invalid")
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
        if parts.isEmpty { parts.append(L10n.tr("wizard.summary.standard")) }
        return parts.joined(separator: " · ")
    }

    /// 修改模式：预填该档案的信息（未重选文件也能直接改用户名/密码并保存）
    private func prefillForEditIfNeeded() {
        guard isEdit, pickedName.isEmpty, let id = editingProfileId,
              let p = vpn.profiles.first(where: { $0.id == id }) else { return }
        pickedName = p.fileName
        fileSummary = vpn.profileOvpnData(id: id)
            .map { summarize(String(data: $0.data, encoding: .utf8) ?? "") } ?? ""
    }

    // MARK: - 保存

    private func save() {
        // 三种来源：新选的文件 / 编辑模式复用当前配置 / 都没有
        let payload: (data: Data, fileName: String)
        if let url = pickedURL {
            guard let data = try? Data(contentsOf: url) else {
                errorText = L10n.tr("wizard.error.readConfig")
                return
            }
            payload = (data, pickedName)
        } else if isEdit, let id = editingProfileId, let current = vpn.profileOvpnData(id: id) {
            payload = current
        } else {
            errorText = L10n.tr("wizard.error.needFile")
            return
        }
        let pass = password.isEmpty ? nil : password
        vpn.saveConfig(ovpnData: payload.data,
                       fileName: payload.fileName,
                       username: username,
                       password: pass,
                       targetProfileId: isEdit ? editingProfileId : nil)
        pickedName = payload.fileName
        step = 3
    }
}
