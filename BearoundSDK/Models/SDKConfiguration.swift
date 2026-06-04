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

    let apiBaseURL: String

    public init(
        businessToken: String,
        scanPrecision: ScanPrecision = .high,
        maxQueuedPayloads: MaxQueuedPayloads = .medium
    ) {
        self.businessToken = businessToken
        self.scanPrecision = scanPrecision
        self.maxQueuedPayloads = maxQueuedPayloads
        self.apiBaseURL = "https://ingest.bearound.io"
        self.appId = Bundle.main.bundleIdentifier ?? "unknown"
    }

    // MARK: - Per-precision duty-cycle values
    //
    // NOTE (iOS): these scan/pause/cycle values describe a duty cycle that is **NOT applied to
    // the BLE radio on iOS** — the radio scans continuously in every precision (iOS handles its
    // own power duty-cycling). They are kept for cross-platform parity (the values are honored on
    // Android). The only precision-derived values iOS actually uses are `precisionLocationAccuracy`
    // and `syncInterval`.

    /// Duration of each scan window (seconds). Not applied to the radio on iOS (radio is continuous).
    var precisionScanDuration: TimeInterval { 10 }

    /// Pause duration between scan windows (seconds). Not applied to the radio on iOS (radio is continuous).
    var precisionPauseDuration: TimeInterval {
        switch scanPrecision {
        case .high: return 0
        case .medium: return 10
        case .low: return 50
        }
    }

    /// Number of scan cycles per interval (0 = continuous). Not applied to the radio on iOS (radio is continuous).
    var precisionCycleCount: Int {
        switch scanPrecision {
        case .high: return 0
        case .medium: return 3
        case .low: return 1
        }
    }

    /// Full cycle interval (seconds)
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
