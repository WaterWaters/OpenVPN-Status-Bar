import Foundation
import Combine
import VPNStatusBarCore

/// 实时流量发布（management `bytecount` 推送，面板可见时 1 Hz）。
///
/// 单独成一个 ObservableObject，是为了把高频失效关进"真正显示它的那一小块"：
/// 挂在 `VPNManager` 上时每一次流量推送都会让所有 `@EnvironmentObject` 视图
/// （整块面板 + 菜单栏 label + 配置列表 + 日志卡）跟着重算一遍。
///
/// 并发约定：只在主线程访问（与 `VPNManager` 一致）。
final class TrafficStore: ObservableObject {
    @Published private(set) var rate: TrafficRate?

    func update(rate: TrafficRate?) {
        self.rate = rate
    }
}
