import CoreWLAN
import Foundation

/// 附近的一个 Wi-Fi 网络（同名的多个接入点只保留信号最强的一个）。
struct WiFiNetwork: Identifiable, Sendable, Equatable {
    var ssid: String
    var rssi: Int
    /// 有密码或其他加密方式，显示小锁。
    var secure: Bool
    /// 加入时需要输入密码（不是开放网络或 OWE 增强开放网络）。
    var needsPassword: Bool
    /// 企业网络（802.1X），要在系统设置里用账号加入。
    var enterprise: Bool
    /// 系统里保存过的网络。
    var known: Bool

    var id: String { ssid }
    var level: Int { NetworkInfo.level(forRSSI: rssi) }
}

enum WiFiControlError: LocalizedError {
    case noInterface
    case poweredOff
    case notFound

    var errorDescription: String? {
        switch self {
        case .noInterface: "这台 Mac 没有 Wi-Fi"
        case .poweredOff: "Wi-Fi 已关闭，请先打开 Wi-Fi"
        case .notFound: "附近找不到这个网络"
        }
    }
}

struct WiFiScan: Sendable {
    var networks: [WiFiNetwork]
    /// 扫描到了但读不到名称的网络数量（没有定位权限时 macOS 会隐藏名称）。
    var unnamed: Int
}

struct WiFiSnapshot: Sendable {
    var info: NetworkInfo
    var bssid: String?
}

/// CoreWLAN 会阻塞；串行执行，避免扫描、切网和开关同时操作无线网卡。
enum WiFiControl {
    private static let queue = DispatchQueue(label: "com.mujh.DuoBar.wifi", qos: .userInitiated)

    private static func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func snapshot() async -> WiFiSnapshot {
        // 读取不会抛错；没有网卡时返回占位状态。
        (try? await perform {
            var info = NetworkInfo.placeholder
            guard let iface = CWWiFiClient.shared().interface() else {
                return WiFiSnapshot(info: info, bssid: nil)
            }
            info.hasWiFiHardware = true
            info.wifiPowered = iface.powerOn()
            guard info.wifiPowered else { return WiFiSnapshot(info: info, bssid: nil) }
            let ssid = iface.ssid().flatMap { $0.isEmpty ? nil : $0 }
            let bssid = iface.bssid().flatMap { $0.isEmpty ? nil : $0 }
            let rssi = iface.rssiValue()
            info.wifiAssociated = ssid != nil || bssid != nil || rssi != 0
            if info.wifiAssociated {
                info.ssid = ssid
                info.rssi = rssi == 0 ? nil : rssi
                info.noise = iface.noiseMeasurement()
                info.txRate = iface.transmitRate()
                if let channel = iface.wlanChannel() {
                    info.channel = channel.channelNumber
                    info.band = switch channel.channelBand {
                    case .band2GHz: "2.4 GHz"
                    case .band5GHz: "5 GHz"
                    case .band6GHz: "6 GHz"
                    default: nil
                    }
                }
            }
            return WiFiSnapshot(info: info, bssid: bssid)
        }) ?? WiFiSnapshot(info: .placeholder, bssid: nil)
    }

    static func scan() async throws -> WiFiScan {
        try await perform {
            guard let iface = CWWiFiClient.shared().interface() else { throw WiFiControlError.noInterface }
            guard iface.powerOn() else { throw WiFiControlError.poweredOff }
            let profiles = iface.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
            let known = Set(profiles.compactMap(\.ssid))

            var strongest: [String: WiFiNetwork] = [:]
            var unnamed = 0
            for network in try iface.scanForNetworks(withName: nil, includeHidden: false) {
                guard let ssid = network.ssid, !ssid.isEmpty else {
                    unnamed += 1
                    continue
                }
                if let existing = strongest[ssid], existing.rssi >= network.rssiValue { continue }
                strongest[ssid] = describe(network, ssid: ssid, known: known.contains(ssid))
            }
            return WiFiScan(networks: strongest.values.sorted { $0.rssi > $1.rssi }, unnamed: unnamed)
        }
    }

    static func setPower(_ on: Bool) async throws {
        try await perform {
            guard let iface = CWWiFiClient.shared().interface() else { throw WiFiControlError.noInterface }
            try iface.setPower(on)
        }
    }

    /// 加入网络。加密网络的 password 由 DuoBar 钥匙串或用户输入提供。
    static func join(ssid: String, password: String?) async throws {
        try await perform {
            guard let iface = CWWiFiClient.shared().interface() else { throw WiFiControlError.noInterface }
            guard iface.powerOn() else { throw WiFiControlError.poweredOff }
            // 重新查找仍在附近的接入点，避免反复连接已离开的旧接入点。
            let candidates = try iface.scanForNetworks(withName: ssid, includeHidden: true)
                .filter { $0.ssid == ssid }
            guard let network = candidates.max(by: { $0.rssiValue < $1.rssiValue }) else {
                throw WiFiControlError.notFound
            }
            try iface.associate(to: network, password: password)
        }
    }

    /// 开发用：只读地检查扫描是否可用、能不能看到网络名称，不改变任何 Wi-Fi 状态。
    static func debugSummary() async -> String {
        (try? await perform {
            guard let iface = CWWiFiClient.shared().interface() else { return "no interface" }
            let profiles = iface.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
            var lines = [
                "powered: \(iface.powerOn())",
                "current ssid visible: \(iface.ssid() != nil)",
                "known profiles: \(profiles.count), with names: \(profiles.filter { $0.ssid != nil }.count)",
            ]
            do {
                let started = Date()
                let results = try iface.scanForNetworks(withName: nil, includeHidden: false)
                let named = results.filter { $0.ssid?.isEmpty == false }
                lines.append("scan: \(results.count) results, \(named.count) with names, \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            } catch {
                lines.append("scan failed: \(error.localizedDescription)")
            }
            return lines.joined(separator: "\n")
        }) ?? "Wi-Fi diagnostics unavailable"
    }

    private static func describe(_ network: CWNetwork, ssid: String, known: Bool) -> WiFiNetwork {
        let open = network.supportsSecurity(CWSecurity.none)
        let passwordless = open || network.supportsSecurity(.OWE) || network.supportsSecurity(.oweTransition)
        let personal = [CWSecurity.WEP, .wpaPersonal, .wpaPersonalMixed, .wpa2Personal, .personal, .wpa3Personal, .wpa3Transition]
            .contains { network.supportsSecurity($0) }
        let enterprise = [CWSecurity.dynamicWEP, .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .enterprise, .wpa3Enterprise]
            .contains { network.supportsSecurity($0) }
        return WiFiNetwork(
            ssid: ssid,
            rssi: network.rssiValue,
            secure: !open,
            needsPassword: !passwordless,
            enterprise: enterprise && !personal && !passwordless,
            known: known
        )
    }
}
