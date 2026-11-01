import Foundation
import Testing
@testable import DuoBar

@MainActor
private final class OperationGate<Value: Sendable> {
    private(set) var calls = 0
    private var continuation: CheckedContinuation<Value, any Error>?

    func wait() async throws -> Value {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func succeed(_ value: Value) {
        let reply = continuation
        continuation = nil
        reply?.resume(returning: value)
    }

    func fail() {
        let reply = continuation
        continuation = nil
        reply?.resume(throwing: TestFailure())
    }
}

private struct TestFailure: Error {}

@MainActor
private final class SnapshotSource {
    var snapshot: WiFiSnapshot

    init(_ snapshot: WiFiSnapshot) { self.snapshot = snapshot }

    func read() -> WiFiSnapshot { snapshot }
}

@Suite(.serialized)
@MainActor
struct WiFiStateTests {
    private let target = WiFiNetwork(
        ssid: "DuoBar regression fixture", rssi: -55, secure: false,
        needsPassword: false, enterprise: false, known: false
    )

    private var poweredNetwork: NetworkInfo {
        var info = NetworkInfo.placeholder
        info.hasWiFiHardware = true
        info.wifiPowered = true
        return info
    }

    private func model(
        scan: @escaping @Sendable () async throws -> WiFiScan = { WiFiScan(networks: [], unnamed: 0) },
        power: @escaping @Sendable (Bool) async throws -> Void = { _ in },
        join: @escaping @Sendable (String, String?) async throws -> Void = { _, _ in },
        password: @escaping @Sendable (String) -> String? = { _ in nil }
    ) -> AppModel {
        let snapshot = WiFiSnapshot(info: poweredNetwork, bssid: nil)
        let model = AppModel(
            wifiOperations: WiFiOperations(scan: scan, setPower: power, join: join, password: password),
            initialNetwork: poweredNetwork,
            networkMonitor: NetworkMonitor(snapshot: { snapshot })
        )
        return model
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(predicate(), "Wi-Fi state did not settle")
    }

    @Test("A scan finishing after the panel closes cannot repopulate the list")
    func discardScanAfterClose() async throws {
        let scan = OperationGate<WiFiScan>()
        let model = model(scan: { try await scan.wait() })
        defer { model.panelVisible = false; scan.fail() }
        model.panelVisible = true
        try await waitUntil { scan.calls == 1 }

        model.panelVisible = false
        scan.succeed(WiFiScan(networks: [target], unnamed: 3))
        try await waitUntil { !model.wifiScanning }

        #expect(model.wifiNetworks.isEmpty)
        #expect(model.wifiUnnamedCount == 0)
        #expect(model.wifiMessage == nil)
    }

    @Test("Reopening the panel rejects the previous session's scan and starts a fresh one")
    func reopenStartsFreshScan() async throws {
        let oldScan = OperationGate<WiFiScan>()
        let freshScan = OperationGate<WiFiScan>()
        let model = model(scan: {
            if await oldScan.calls == 0 { return try await oldScan.wait() }
            return try await freshScan.wait()
        })
        defer { model.panelVisible = false; oldScan.fail(); freshScan.fail() }
        model.panelVisible = true
        try await waitUntil { oldScan.calls == 1 }

        model.panelVisible = false
        model.panelVisible = true
        oldScan.succeed(WiFiScan(networks: [target], unnamed: 5))
        try await waitUntil { freshScan.calls == 1 }

        #expect(model.wifiNetworks.isEmpty)
        #expect(model.wifiUnnamedCount == 0)

        var replacement = target
        replacement.ssid = "Fresh scan fixture"
        freshScan.succeed(WiFiScan(networks: [replacement], unnamed: 0))
        try await waitUntil { !model.wifiScanning }
        #expect(model.wifiNetworks == [replacement])
    }

    @Test("An older scan cannot replace the target or accept another operation during joining")
    func joiningExcludesScansAndPower() async throws {
        let scan = OperationGate<WiFiScan>()
        let joining = OperationGate<Void>()
        let power = OperationGate<Void>()
        let model = model(
            scan: { try await scan.wait() },
            power: { _ in try await power.wait() },
            join: { _, _ in try await joining.wait() }
        )
        defer { model.panelVisible = false; scan.fail(); joining.fail(); power.fail() }
        model.panelVisible = true
        try await waitUntil { scan.calls == 1 }

        model.join(target)
        try await waitUntil { joining.calls == 1 }
        model.setWiFiPower(false)
        await model.scanWiFi()
        scan.succeed(WiFiScan(networks: [], unnamed: 0))
        try await waitUntil { !model.wifiScanning }

        #expect(scan.calls == 1)
        #expect(power.calls == 0)
        #expect(model.joiningSSID == target.ssid)
        #expect(model.wifiNetworks.contains { $0.ssid == target.ssid })

        model.panelVisible = false
        joining.succeed(())
        try await waitUntil { model.joiningSSID == nil }
    }

    @Test("Power changes exclude joining and reject an older scan")
    func powerExcludesJoinAndStaleScan() async throws {
        let scan = OperationGate<WiFiScan>()
        let power = OperationGate<Void>()
        let joining = OperationGate<Void>()
        let model = model(
            scan: { try await scan.wait() },
            power: { _ in try await power.wait() },
            join: { _, _ in try await joining.wait() }
        )
        defer { model.panelVisible = false; scan.fail(); power.fail(); joining.fail() }
        model.panelVisible = true
        try await waitUntil { scan.calls == 1 }

        model.setWiFiPower(false)
        try await waitUntil { power.calls == 1 }
        model.join(target)
        await model.scanWiFi()
        scan.succeed(WiFiScan(networks: [target], unnamed: 2))
        try await waitUntil { !model.wifiScanning }

        #expect(joining.calls == 0)
        #expect(model.joiningSSID == nil)
        #expect(model.wifiNetworks.isEmpty)
        #expect(model.wifiUnnamedCount == 0)

        model.panelVisible = false
        power.succeed(())
        try await waitUntil { !model.wifiSwitching }
    }

    @Test("Closing the panel while a saved-password attempt fails cannot create a hidden password wait")
    func failedJoinAfterCloseFinishes() async throws {
        let joining = OperationGate<Void>()
        var secured = target
        secured.secure = true
        secured.needsPassword = true
        let model = model(join: { _, _ in try await joining.wait() }, password: { _ in "fixture password" })
        defer { model.panelVisible = false; joining.fail() }
        model.panelVisible = true
        model.join(secured)
        try await waitUntil { joining.calls == 1 }

        model.panelVisible = false
        joining.fail()
        try await waitUntil { model.joiningSSID == nil }

        #expect(model.passwordPromptSSID == nil)
    }

    @Test("Closing a visible password entry releases the join and its busy state")
    func closingPasswordPromptCancelsJoin() async throws {
        var secured = target
        secured.secure = true
        secured.needsPassword = true
        let joining = OperationGate<Void>()
        let model = model(join: { _, _ in try await joining.wait() })
        defer { model.panelVisible = false; joining.fail() }
        model.panelVisible = true
        model.join(secured)
        try await waitUntil { model.passwordPromptSSID == secured.ssid }
        #expect(model.wifiNetworks.contains { $0.ssid == secured.ssid })

        model.panelVisible = false
        try await waitUntil { model.joiningSSID == nil }

        #expect(model.passwordPromptSSID == nil)
        #expect(joining.calls == 0)
    }

    @Test("Transient missing SSID is retained only for the same access point")
    func monitorRetainsSSIDForSameBSSID() async throws {
        var initial = poweredNetwork
        initial.wifiAssociated = true
        initial.ssid = target.ssid
        initial.rssi = -55
        let source = SnapshotSource(WiFiSnapshot(info: initial, bssid: "00:11:22:33:44:55"))
        let monitor = NetworkMonitor(snapshot: { await source.read() })
        monitor.refresh()
        try await waitUntil { monitor.info.ssid == target.ssid }

        source.snapshot.info.ssid = nil
        source.snapshot.info.rssi = -65
        monitor.refresh()
        try await waitUntil { monitor.info.rssi == -65 }

        #expect(monitor.info.ssid == target.ssid)

        source.snapshot.bssid = "66:77:88:99:aa:bb"
        source.snapshot.info.rssi = -70
        monitor.refresh()
        try await waitUntil { monitor.info.rssi == -70 }

        #expect(monitor.info.ssid == nil)
    }

    @Test("Clearing SSID access invalidates a snapshot already in flight")
    func monitorDiscardsPendingIdentityAfterCacheClear() async throws {
        let snapshots = OperationGate<WiFiSnapshot>()
        let monitor = NetworkMonitor(snapshot: {
            (try? await snapshots.wait()) ?? WiFiSnapshot(info: .placeholder, bssid: nil)
        })
        defer { snapshots.fail() }
        var connected = poweredNetwork
        connected.wifiAssociated = true
        connected.ssid = target.ssid
        connected.rssi = -55
        let stale = WiFiSnapshot(info: connected, bssid: "00:11:22:33:44:55")

        monitor.refresh()
        try await waitUntil { snapshots.calls == 1 }
        snapshots.succeed(stale)
        try await waitUntil { monitor.info.ssid == target.ssid }

        monitor.refresh()
        try await waitUntil { snapshots.calls == 2 }
        monitor.clearSSIDCache()
        snapshots.succeed(stale)
        try await waitUntil { snapshots.calls == 3 }

        #expect(monitor.info.ssid == nil)

        snapshots.succeed(WiFiSnapshot(info: poweredNetwork, bssid: nil))
        try await waitUntil { !monitor.info.wifiAssociated }
        #expect(monitor.info.ssid == nil)
    }
}
