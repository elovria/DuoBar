import AppKit
import CoreLocation

/// macOS 只把 Wi-Fi 名称给有定位权限的 App。DuoBar 只用它来显示网络名称，不读取位置。
@MainActor
final class LocationAccess: NSObject {
    enum State: Sendable {
        case notDetermined, granted, denied
    }

    var onChange: ((State) -> Void)?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
    }

    var state: State { Self.state(for: manager.authorizationStatus) }

    func request() {
        // 菜单面板默认不激活 App，系统授权框需要由前台 App 发起。
        NSApp.activate(ignoringOtherApps: true)
        manager.requestWhenInUseAuthorization()
    }

    private static func state(for status: CLAuthorizationStatus) -> State {
        switch status {
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        default: .granted
        }
    }
}

extension LocationAccess: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onChange?(Self.state(for: manager.authorizationStatus))
    }
}
