import SwiftUI
import AppKit
import VPNStatusBarCore

/// 应用退出时确保清理 VPN 进程
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandler()
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
            StatusBarIcon(status: vpn.status)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - 菜单栏图标（随状态着色，连接中/重连中呼吸）

struct StatusBarIcon: View {
    let status: VPNStatus
    @State private var pulse = false

    private var color: Color {
        switch status {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected, .unconfigured: return .gray
        }
    }

    var body: some View {
        Image(systemName: status.symbolName)
            .foregroundStyle(color)
            .opacity(status.isBusy ? (pulse ? 0.35 : 1) : 1)
            .animation(
                status.isBusy
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onAppear { pulse = true }
    }
}