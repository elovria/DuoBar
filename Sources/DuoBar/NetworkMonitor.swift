import AppKit
import CoreWLAN
import Foundation
import Network

/// 汇总网络状态：连接方式来自 NWPathMonitor，Wi-Fi 细节在后台读取。
@MainActor
final class NetworkMonitor: NSObject {
    private(set) var info = NetworkInfo.placeholder
    var onChange: ((NetworkInfo) -> Void)?

    /// 面板打开时加快刷新，让信号强度看起来是“活的”。
    var fastPolling = false {
        didSet { if started, fastPolling != oldValue { restartPolling() } }
    }

    private let pathMonitor = NWPathMonitor()
    // 事件客户端独立于执行扫描和切网的客户端，避免改写其他调用方的 delegate。
    private let eventClient = CWWiFiClient()
    private let snapshotProvider: @Sendable () async -> WiFiSnapshot
    private var path = PathSummary(satisfied: false, primary: nil, expensive: false)
    private var started = false
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var retrySSID = true
    private var identityGeneration = 0
    private var lastBSSID: String?
    private var lastSSID: String?

    init(snapshot: @escaping @Sendable () async -> WiFiSnapshot = { await WiFiControl.snapshot() }) {
        snapshotProvider = snapshot
        super.init()
    }

    private struct PathSummary: Sendable {
        var satisfied: Bool
        var primary: NWInterface.InterfaceType?
        var expensive: Bool

        init(satisfied: Bool, primary: NWInterface.InterfaceType?, expensive: Bool) {
            self.satisfied = satisfied
            self.primary = primary
            self.expensive = expensive
        }

        init(_ path: NWPath) {
            satisfied = path.status == .satisfied
            // availableInterfaces 包含可用网卡；usesInterfaceType 才表示这条路径实际使用的类型。
            primary = if path.usesInterfaceType(.wiredEthernet) { .wiredEthernet }
                else if path.usesInterfaceType(.wifi) { .wifi }
                else if path.availableInterfaces.isEmpty { nil }
                else { .other }
            expensive = path.isExpensive
        }
    }

    func start() {
        guard !started else { return }
        started = true
        pathMonitor.pathUpdateHandler = { [weak self] newPath in
            let summary = PathSummary(newPath)
            Task { @MainActor [weak self] in
                self?.path = summary
                self?.refresh()
            }
        }
        pathMonitor.start(queue: .main)
        eventClient.delegate = self
        // 某些系统/签名不允许订阅事件，仍由定时刷新保持可用。
        for event in [CWEventType.powerDidChange, .ssidDidChange, .linkDidChange, .bssidDidChange] {
            try? eventClient.startMonitoringEvent(with: event)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil
        )
        restartPolling()
    }

    private func restartPolling() {
        pollTask?.cancel()
        let interval: Duration = fastPolling ? .seconds(2) : .seconds(8)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: interval, tolerance: interval / 4)
            }
        }
    }

    /// 授权、连接身份或电源变化时，旧名称和正在读取的旧快照都不能再使用。
    func clearSSIDCache() {
        identityGeneration += 1
        lastBSSID = nil
        lastSSID = nil
        retrySSID = true
        if info.ssid != nil {
            info.ssid = nil
            onChange?(info)
        }
    }

    func refresh() {
        guard refreshTask == nil else {
            refreshAgain = true
            return
        }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                refreshAgain = false
                let generation = identityGeneration
                let shouldRetry = retrySSID
                retrySSID = false
                var snapshot = await snapshotProvider()
                // 刚切网/授权后 CoreWLAN 可能短暂没有名称，最多再读两次。
                if shouldRetry || info.ssid != nil {
                    for _ in 0..<2 {
                        guard generation == identityGeneration,
                              snapshot.info.wifiAssociated, snapshot.info.ssid == nil else { break }
                        try? await Task.sleep(for: .milliseconds(200))
                        guard generation == identityGeneration else { break }
                        snapshot = await snapshotProvider()
                    }
                }
                if generation == identityGeneration {
                    apply(snapshot)
                } else {
                    refreshAgain = true
                }
            } while refreshAgain
            refreshTask = nil
        }
    }

    private func apply(_ snapshot: WiFiSnapshot) {
        var new = snapshot.info
        if new.wifiAssociated, let bssid = snapshot.bssid, !bssid.isEmpty {
            if new.ssid == nil, bssid == lastBSSID { new.ssid = lastSSID }
            lastBSSID = bssid
            lastSSID = new.ssid
        } else {
            lastBSSID = nil
            lastSSID = nil
        }

        new.link = if !path.satisfied {
            .none
        } else {
            switch path.primary {
            case .wiredEthernet: .ethernet
            case .wifi: path.expensive ? .hotspot : .wifi
            case nil: .none
            default: .other
            }
        }

        guard new != info else { return }
        info = new
        onChange?(new)
    }

    private func connectionChanged() {
        clearSSIDCache()
        refresh()
    }

    @objc private func didWake(_ notification: Notification) {
        connectionChanged()
    }
}

extension NetworkMonitor: CWEventDelegate {
    nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in self?.connectionChanged() }
    }

    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in self?.connectionChanged() }
    }

    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in self?.connectionChanged() }
    }

    nonisolated func bssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in self?.connectionChanged() }
    }

    nonisolated func clientConnectionInterrupted() {
        Task { @MainActor [weak self] in self?.connectionChanged() }
    }
}
