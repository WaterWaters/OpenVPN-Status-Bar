import SwiftUI
import AppKit
import QuartzCore

// MARK: - busy 态呼吸圆点（CoreAnimation 实现）
//
// 为什么不用 SwiftUI 动画：真机 + 探针实测（面板内容渲染过一次后、窗口不可见的情况下，
// 25 秒 CPU 增量）——
//   · `.animation(.easeInOut(0.8).repeatForever)`（原来的实现）      ≈ 8.6%
//   · 「低频阶跃」：每秒改 5 次 @State（0.2 秒一级）                 ≈ 9.8%
//   · 两处呼吸都换成静态（无动画）                                   ≈ 0.9%
// 结论：只要在 busy 态里让 SwiftUI 反复改状态，整块面板的视图树就要跟着重算，
// 降频无用；而且 `MenuBarExtra` 的面板窗口**不可见时也照跑**。
//
// 所以呼吸交给 CoreAnimation：动画在 renderer 侧插值，app 每帧都不参与，
// 实测与"完全不动"的对照组同量级。

/// busy 态呼吸圆点：外观与静态态一致（7×7 实心圆），只是把不透明度动画交给 CA。
///
/// 只在面板可见且处于连接/重连中时呼吸（面板不可见时静态 —— 面板关着也跑正是之前空转的来源）。
struct PulsingDot: View {
    let color: Color
    let isBusy: Bool
    @ObservedObject private var motion = MotionSettings.shared
    @ObservedObject private var panel = PanelVisibility.shared

    /// 系统开启「减少动态效果」后停掉呼吸（设计稿把 prefers-reduced-motion 列为验收项）
    private var animating: Bool { isBusy && !motion.reduceMotion && panel.isVisible }

    var body: some View {
        PulsingDotLayer(color: color, animating: animating)
            .frame(width: Self.diameter, height: Self.diameter)
    }

    static let diameter: CGFloat = 7
    /// 呼吸到的最低不透明度（沿用原实现的取值）
    static let minOpacity: Double = 0.3
}

/// 圆点本体（AppKit）：一层底色 + CoreAnimation 的不透明度呼吸。
private struct PulsingDotLayer: NSViewRepresentable {
    let color: Color
    let animating: Bool

    func makeNSView(context: Context) -> DotView { DotView() }

    func updateNSView(_ view: DotView, context: Context) {
        view.apply(color: color, animating: animating)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DotView, context: Context) -> CGSize? {
        CGSize(width: PulsingDot.diameter, height: PulsingDot.diameter)
    }

    static func dismantleNSView(_ view: DotView, coordinator: ()) {
        view.stopPulse()
    }

    final class DotView: NSView {
        private static let animationKey = "io.vpnstatusbar.pulse"

        private var dotColor: NSColor = .clear

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = PulsingDot.diameter / 2
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        func apply(color: Color, animating: Bool) {
            dotColor = NSColor(color)
            updateBackground()
            if animating {
                guard layer?.animation(forKey: Self.animationKey) == nil else { return }
                layer?.add(Self.pulseAnimation(), forKey: Self.animationKey)
            } else {
                stopPulse()
            }
        }

        func stopPulse() {
            layer?.removeAnimation(forKey: Self.animationKey)
            layer?.opacity = 1
        }

        /// 取色按当前外观解析（Design 里的颜色是浅/深色自适应的，直接取 cgColor 会锁死在某一档）：
        /// AppKit 的动态颜色要在「当前绘制外观」上下文里取，`performAsCurrentDrawingAppearance` 就是干这个的。
        private func updateBackground() {
            effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
                layer?.backgroundColor = dotColor.cgColor
            }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateBackground()
        }

        private static func pulseAnimation() -> CABasicAnimation {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = PulsingDot.minOpacity
            pulse.toValue = 1.0
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return pulse
        }
    }
}
