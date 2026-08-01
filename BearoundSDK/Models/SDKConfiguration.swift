//
//  SDKConfiguration.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import Foundation

/// SDK configuration for beacon scanning and API communication
public struct SDKConfiguration {
    public let appId: String
    public let businessToken: String

    /// Scan precision mode.
    ///
    /// - Important: On **iOS** the BLE radio scans **continuously in all precisions** — iOS does
    ///   its own power duty-cycling for background BLE, and the SDK never stops the radio in
    ///   steady state (stopping it would unregister the kernel scan filter and break
    ///   terminated-app wake-up). So on iOS `scanPrecision` does **not** change the radio duty
    ///   cycle; it only affects the **sync cadence** (``syncInterval``) and the **location
    ///   accuracy** (``precisionLocationAccuracy``). The per-precision duty-cycle numbers below
    ///   (scan/pause durations, cycle counts) are retained for cross-platform parity but are
    ///   **not applied to the radio on iOS**.
    public let scanPrecision: ScanPrecision
    public let maxQueuedPayloads: MaxQueuedPayloads

    /// Origin technology reported in the `/ingest` payload as `sdk.technology`.
    /// Defaults to `ios-native`; the React Native / Flutter bridges pass their own value
    /// (`react-native` / `flutter`) so the backend can attribute traffic per integration.
    public let technology: String

    let apiBaseURL: String

    public init(
        businessToken: String,
        scanPrecision: ScanPrecision = .high,
        maxQueuedPayloads: MaxQueuedPayloads = .medium,
        technology: String = "ios-native"
    ) {
        self.businessToken = businessToken
        self.scanPrecision = scanPrecision
        self.maxQueuedPayloads = maxQueuedPayloads
        self.technology = technology
        self.apiBaseURL = "https://ingest.bearound.io"
        self.appId = Bundle.main.bundleIdentifier ?? "unknown"
    }

    // MARK: - Per-precision duty-cycle values
    //
    // NOTE (iOS): the radio scans continuously in every precision (iOS handles its own power
    // duty-cycling). The only precision-derived values iOS uses are `precisionLocationAccuracy`,
    // `precisionCycleInterval` (sync cadence for medium/low) and `syncInterval`. Android honors
    // a fuller duty-cycle model on its side of the cross-platform contract.

    /// Sync cadence for medium/low precision (seconds).
    var precisionCycleInterval: TimeInterval { 60 }

    /// Location accuracy for CoreLocation (meters)
    var precisionLocationAccuracy: Double {
        switch scanPrecision {
        case .high, .medium: return 10
        case .low: return 100
        }
    }

    /// Sync interval: high uses 15s, medium/low uses 60s (after cycles)
    var syncInterval: TimeInterval {
        switch scanPrecision {
        case .high: return 15
        case .medium, .low: return 60
        }
    }
}
