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
