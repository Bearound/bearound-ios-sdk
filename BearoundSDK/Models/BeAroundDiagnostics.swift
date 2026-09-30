//
//  BeAroundDiagnostics.swift
//  BearoundSDK
//
//  Created by Bearound on 04/06/26.
//

import Foundation

/// Read-only snapshot of the SDK's identity, state, and recent activity (push token masked).
public struct BeAroundDiagnostics {
    public let deviceId: String
    public let deviceIdType: String
    public let pushTokenMasked: String?
    public let pushTokenLastSentAt: Date?
    public let apnsEnvironment: String
    public let isScanning: Bool
    public let pendingBatches: Int
    public let lastScanAt: Date?
    public let lastScanBeaconCount: Int?
    public let lastSyncAt: Date?
    public let lastSyncSuccess: Bool?
    public let lastSyncBeaconCount: Int?
    public let lastPushReceivedAt: Date?
    public let recentErrors: [String]
    public let sdkVersion: String

    // MARK: - Runtime state (added for field triage)

    /// CoreLocation authorization status as a String
    /// (`notDetermined` / `restricted` / `denied` / `authorizedAlways` / `authorizedWhenInUse`).
    /// Defaults to `"unknown"` when not collected.
    public let authorizationStatus: String

    /// Bluetooth central-manager state as a String
    /// (`unknown` / `resetting` / `unsupported` / `unauthorized` / `poweredOff` / `poweredOn`).
    public let bluetoothState: String

    /// `UIApplication.backgroundRefreshStatus` as a String
    /// (`available` / `denied` / `restricted`). When `denied`/`restricted`, background wake-ups
    /// via BGTask are throttled or blocked by the OS.
    public let backgroundRefreshStatus: String

    /// Whether the SDK's BGTask identifiers were successfully registered with `BGTaskScheduler`.
    /// `false` means background sync/processing will never fire (missing `registerBackgroundTasks()`
    /// call or `BGTaskSchedulerPermittedIdentifiers` Info.plist entries).
    public let backgroundTasksRegistered: Bool

    /// ``BeAroundDetectionReadiness`` as a String (`full` / `backgroundBle` / `foregroundOnly`
    /// / `blind`): what this install can actually detect, given the authorization granted and
    /// the background modes the host declared.
    public let detectionReadiness: String

    /// The host app's declared `UIBackgroundModes`. Build-time, so it never changes at runtime:
    /// and it decides whether the BLE eye survives backgrounding (`bluetooth-central`) and
    /// whether background location updates are legal at all (`location`).
    public let backgroundModes: [String]

    /// Result of the last Wi-Fi visit round: `ready` / `missingEntitlement` /
    /// `locationNotAuthorized` / `notConnected`, or `notRun` before one ran. `missingEntitlement`
    /// means the host app lacks `com.apple.developer.networking.wifi-info`, so Wi-Fi visit
    /// matching stays inert.
    public let wifiStatus: String

    public func summary() -> String {
        let iso = ISO8601DateFormatter()
        func fmt(_ d: Date?) -> String { d.map { iso.string(from: $0) } ?? "—" }
        func fmt(_ i: Int?) -> String { i.map(String.init) ?? "—" }
        let sync: String = {
            guard let ok = lastSyncSuccess else { return "—" }
            return ok ? "OK" : "FAILED"
        }()
        var lines = [
            "Bearound SDK \(sdkVersion) diagnostics",
            "  device:   \(deviceId) (\(deviceIdType))",
            "  push:     \(pushTokenMasked ?? "none") [\(apnsEnvironment)] lastSent=\(fmt(pushTokenLastSentAt))",
            "  pushRecv: \(fmt(lastPushReceivedAt))",
            "  scanning: \(isScanning)  pending: \(pendingBatches)",
            "  lastScan: \(fmt(lastScanAt)) (\(fmt(lastScanBeaconCount)) beacons)",
            "  lastSync: \(fmt(lastSyncAt)) \(sync) (\(fmt(lastSyncBeaconCount)) beacons)",
            "  location: \(authorizationStatus)  bluetooth: \(bluetoothState)",
            "  bgRefresh: \(backgroundRefreshStatus)  bgTasks: \(backgroundTasksRegistered ? "registered" : "not registered")",
            "  bgModes:  \(backgroundModes.isEmpty ? "none" : backgroundModes.joined(separator: ", "))",
            "  detects:  \(detectionReadiness)",
            "  wifi:     \(wifiStatus)",
        ]
        if recentErrors.isEmpty {
            lines.append("  errors:   none")
        } else {
            lines.append("  errors (\(recentErrors.count)):")
            lines.append(contentsOf: recentErrors.map { "    - \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}
