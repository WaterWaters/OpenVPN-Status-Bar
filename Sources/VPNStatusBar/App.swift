import SwiftUI
import AppKit
import VPNStatusBarCore

/// 应用退出时确保清理 VPN 进程
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 以「菜单栏应用」形态运行：正常打包时由 Info.plist 的 LSUIElement 决定，
        // 但 `swift run`（没有 .app 包与 Info.plist）启动时没有这个键，会多出一个 Dock 图标
        NSApp.setActivationPolicy(.accessory)
        installSignalHandler()
        // 通知授权（用户可在设置关闭）
        if UserDefaults.standard.object(forKey: "notifyEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "notifyEnabled")
        }
        // 挪到下一拍：授权要走系统通知 daemon，不该挡在启动路径上 ——
        // 状态栏图标必须最先出现（非 .app 启动时这里曾直接抛异常导致进程 abort）
        DispatchQueue.main.async { NotificationService.requestAuthorizationIfNeeded() }
        // 系统睡眠/唤醒：唤醒后交给 NetworkMonitor 收敛（它还会覆盖换 Wi-Fi / 插拔网线的情况）。
        // 睡眠时不做动作 —— 隧道由 openvpn 自己的 --ping-restart 处理。
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func didWake() {
        // 给系统几秒恢复网络，再由 NetworkMonitor 统一收敛（它也会处理换网的情况）
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            NetworkMonitor.shared.handleWake()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        VPNManager.shared.shutdown()
    }

    /// 安装 SIGTERM 处理：app 被 kill 时也执行清理
    /// （AppKit 不保证 SIGTERM 会触发 applicationWillTerminate；
    ///   注意不能用 SIG_IGN + DispatchSource 组合，忽略后的信号源收不到事件）
    private func installSignalHandler() {
        signal(SIGTERM) { _ in
            DispatchQueue.main.async {
                VPNManager.shared.shutdown()
                exit(0)
            }
        }
    }
}

@main
struct VPNStatusBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var vpn = VPNManager.shared

    init() {
        // 命令行参数支持（自动化 / 快捷指令 / Alfred 控制）：
        //   VPNStatusBar --connect     启动后自动连接
        //   VPNStatusBar --disconnect  启动后立即断开
        let args = CommandLine.arguments
        if args.contains("--connect") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                VPNManager.shared.connect()
            }
        } else if args.contains("--disconnect") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                VPNManager.shared.disconnect()
            }
        }
    }

    var body: some Scene {
        // .window 弹窗样式：内容以浮动面板渲染，
        // 自定义颜色/背景/控件全部真实生效（对应 design/mockup.html 面板设计）
        MenuBarExtra {
            ContentView()
                .environmentObject(vpn)
        } label: {
            // VoiceOver 只会按 SF Symbol 名念「shield fill」；悬停也看不到状态文案，这里都补上
            StatusBarIcon(status: vpn.status)
                .accessibilityLabel("VPNStatusBar · \(vpn.status.title)")
                .help("VPNStatusBar · \(vpn.status.title)")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - 菜单栏图标（随状态着色）
// 不再做「呼吸」动画：菜单栏 label 里的 SwiftUI 动画无法用 CoreAnimation 承载（label 不支持
// NSViewRepresentable 的可靠动画），而任何 SwiftUI 无限动画都会逐帧重绘、面板不可见也照跑
// （实测 busy 态空转 9% CPU）。忙碌状态由颜色表达（橙）+ 无障碍文案表达。
// 面板内的圆点仍保留呼吸，走 CA（见 Pulse.swift）。

struct StatusBarIcon: View {
    let status: VPNStatus

    private var color: Color {
        switch status {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected, .unconfigured: return .gray
        }
    }

    var body: some View {
        // 统一加粗：menu bar 图标需与 WiFi/电池等系统图标线宽一致
        Image(systemName: status.symbolName)
            .font(.system(size: Design.Font.body, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
    }
}