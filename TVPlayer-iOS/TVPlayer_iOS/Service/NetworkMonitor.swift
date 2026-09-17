import Foundation
import Network

/// 网络状态监听 — 跟踪网络可用性及类型（WiFi/蜂窝）
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "tvplayer.network.monitor")

    /// 当前网络是否可用
    private(set) var isSatisfied = false

    /// 当前网络类型
    private(set) var connectionType: ConnectionType = .unknown

    /// 是否使用蜂窝网络（可能需要节省流量）
    var isCellular: Bool { connectionType == .cellular }

    enum ConnectionType {
        case wifi
        case cellular
        case wired
        case unknown
    }

    /// 网络从无到有时回调（仅真实「无 → 有」边沿；首次路径更新只建立基线）
    var onSatisfied: (() -> Void)?

    /// 网络类型变化时回调
    var onConnectionTypeChanged: ((ConnectionType) -> Void)?

    /// 是否已收到首次路径更新：之前「无网络」只是初始值，不算恢复边沿
    private var didReceiveFirstPath = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(path: path)
        }
        monitor.start(queue: queue)

        // 初始状态
        update(path: monitor.currentPath)
    }

    private func update(path: NWPath) {
        let satisfied = path.status == .satisfied
        let type: ConnectionType
        if path.usesInterfaceType(.wifi) {
            type = .wifi
        } else if path.usesInterfaceType(.cellular) {
            type = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            type = .wired
        } else {
            type = .unknown
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let wasSatisfied = self.isSatisfied
            let previousType = self.connectionType
            self.isSatisfied = satisfied

            // 推断网络类型
            self.connectionType = type

            // 网络恢复通知（无 → 有）。首次路径更新只建立基线不触发：
            // 否则 App 每次启动都会多发一次假「网络恢复」，多拉一轮全量源
            if self.didReceiveFirstPath, satisfied && !wasSatisfied {
                self.onSatisfied?()
            }
            self.didReceiveFirstPath = true

            // 网络类型变化通知（含首次判定到 wifi/蜂窝，便于授权后重载画面）
            if self.connectionType != previousType {
                self.onConnectionTypeChanged?(self.connectionType)
            }
        }
    }
}
