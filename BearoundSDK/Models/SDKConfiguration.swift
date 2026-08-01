//
//  SDKConfiguration.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import Foundation

/// Defaults and safety bounds for the periodic background reconciliation
/// (`BGAppRefreshTask`). Public so hosts can reference the same constants.
public enum PeriodicReconciliationDefaults {
    /// Default minimum interval requested between eligible executions.
    public static let interval: TimeInterval = 20 * 60
    /// Default ceiling for the temporary BLE collection window inside the task.
    public static let scanDuration: TimeInterval = 12
    /// Internal floor — protects against accidental sub-minute reschedule loops.
    public static let minimumAcceptedInterval: TimeInterval = 60
    public static let minimumScanDuration: TimeInterval = 3
    public static let maximumScanDuration: TimeInterval = 30

    /// Sanitizes a host-provided interval: non-finite / NaN / zero / negative values
    /// fall back to the default; anything below the floor is clamped up. Long
    /// intervals are accepted as-is — the value is only the FLOOR iOS honors.
    static func sanitizedInterval(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else {
            NSLog("[BeAroundSDK] Invalid periodicReconciliationInterval (%f) — using default %.0fs", value, interval)
            return interval
        }
        if value < minimumAcceptedInterval {
            NSLog("[BeAroundSDK] periodicReconciliationInterval %.0fs below the %.0fs floor — clamped", value, minimumAcceptedInterval)
            return minimumAcceptedInterval
        }
        return value
    }

    /// Sanitizes the scan-window duration into `[minimumScanDuration, maximumScanDuration]`.
    static func sanitizedScanDuration(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else {
            NSLog("[BeAroundSDK] Invalid periodicScanDuration (%f) — using default %.0fs", value, scanDuration)
            return scanDuration
        }
        return min(max(value, minimumScanDuration), maximumScanDuration)
    }
}

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

    /// Enables the periodic background reconciliation (`BGAppRefreshTask` layer).
    ///
    /// Complementary to CoreBluetooth/CoreLocation — it never replaces them. Best
    /// effort by design: the value below is only the EARLIEST the task may run;
    /// iOS decides when (and whether) it actually executes.
    public let periodicReconciliationEnabled: Bool

    /// Minimum interval requested before the next eligible execution. iOS may run
    /// the task much later than this — it is a floor, never a guaranteed cadence.
    /// Invalid values (NaN/∞/≤0) fall back to the 20-min default; values under 60s
    /// are clamped to 60s. Larger-than-default intervals are accepted as-is.
    public let periodicReconciliationInterval: TimeInterval

    /// Ceiling for the temporary BLE collection window inside the periodic task,
    /// clamped to [3s, 30s]. Only used when the task needs to (re)arm the scan.
    public let periodicScanDuration: TimeInterval

    public init(
        businessToken: String,
        scanPrecision: ScanPrecision = .high,
        maxQueuedPayloads: MaxQueuedPayloads = .medium,
        technology: String = "ios-native",
        periodicReconciliationEnabled: Bool = true,
        periodicReconciliationInterval: TimeInterval = PeriodicReconciliationDefaults.interval,
        periodicScanDuration: TimeInterval = PeriodicReconciliationDefaults.scanDuration
    ) {
        self.businessToken = businessToken
        self.scanPrecision = scanPrecision
        self.maxQueuedPayloads = maxQueuedPayloads
        self.technology = technology
        self.apiBaseURL = "https://ingest.bearound.io"
        self.appId = Bundle.main.bundleIdentifier ?? "unknown"
        self.periodicReconciliationEnabled = periodicReconciliationEnabled
        self.periodicReconciliationInterval =
            PeriodicReconciliationDefaults.sanitizedInterval(periodicReconciliationInterval)
        self.periodicScanDuration =
            PeriodicReconciliationDefaults.sanitizedScanDuration(periodicScanDuration)
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
