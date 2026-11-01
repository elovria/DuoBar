import Foundation

/// Wi-Fi 操作的依赖边界，让状态流程可以在不操作真实网卡的情况下验证。
struct WiFiOperations: Sendable {
    var scan: @Sendable () async throws -> WiFiScan
    var setPower: @Sendable (Bool) async throws -> Void
    var join: @Sendable (String, String?) async throws -> Void
    var password: @Sendable (String) -> String?

    static let live = WiFiOperations(
        scan: { try await WiFiControl.scan() },
        setPower: { try await WiFiControl.setPower($0) },
        join: { try await WiFiControl.join(ssid: $0, password: $1) },
        password: { WiFiPasswords.password(for: $0) }
    )
}
