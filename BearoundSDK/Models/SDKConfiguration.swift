//
//  SDKConfiguration.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import Foundation

/// Defaults and safety bounds for the periodic background reconciliation
/// (`BGAppRefreshTask`). Public so hosts can reference the same constants.
///
/// The bounds are PRODUCT guard rails, not just input validation — they protect the
/// host app (and its users' batteries) from configurations that look reasonable but
/// degrade the feature or the device:
///
/// - **Interval floor (10 min)**: below this iOS won't grant executions anyway, and on
///   devices with a generous budget (charging, heavily-used app) an aggressive floor
///   turns into scan+radio+upload many times per hour — battery drain the END USER
///   feels and the client gets blamed for. Sub-10-min "reconciliation" adds no product
///   value: region wake-ups and push already cover the real-time path.
/// - **Interval ceiling (24 h)**: past this the layer is effectively off — better to
///   disable it explicitly than to believe it still runs.
/// - **Scan ceiling (15 s)**: a BGAppRefreshTask gets ~30 s of TOTAL runtime. A scan
///   window that eats the whole budget leaves nothing for the sync — the task then
///   expires on EVERY run, and the system responds to chronic expiration by granting
///   fewer and fewer executions. Half the budget is the safe maximum.
public enum PeriodicReconciliationDefaults {
    /// Default minimum interval requested between eligible executions.
    public static let interval: TimeInterval = 20 * 60
    /// Default ceiling for the temporary BLE collection window inside the task.
    public static let scanDuration: TimeInterval = 12
    /// Interval floor. See the type doc for why 10 minutes.
    public static let minimumAcceptedInterval: TimeInterval = 10 * 60
    /// Interval ceiling. See the type doc for why 24 hours.
    public static let maximumAcceptedInterval: TimeInterval = 24 * 60 * 60
    public static let minimumScanDuration: TimeInterval = 3
    /// Scan-window ceiling. See the type doc for why 15 seconds.
    public static let maximumScanDuration: TimeInterval = 15

    /// Sanitizes a host-provided interval: non-finite / NaN / zero / negative values
    /// fall back to the default; out-of-range values are clamped into
    /// `[minimumAcceptedInterval, maximumAcceptedInterval]` with a diagnostic log.
    static func sanitizedInterval(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else {
            NSLog("[BeAroundSDK] Invalid periodicReconciliationInterval (%f) — using default %.0fs", value, interval)
            return interval
        }
        if value < minimumAcceptedInterval {
            NSLog("[BeAroundSDK] periodicReconciliationInterval %.0fs below the %.0fs floor — clamped (sub-10-min BGTask cadence drains batteries without adding product value)", value, minimumAcceptedInterval)
            return minimumAcceptedInterval
        }
        if value > maximumAcceptedInterval {
            NSLog("[BeAroundSDK] periodicReconciliationInterval %.0fs above the %.0fs ceiling — clamped (disable the feature explicitly instead of an effectively-never interval)", value, maximumAcceptedInterval)
            return maximumAcceptedInterval
        }
        return value
    }

    /// Sanitizes the scan-window duration into `[minimumScanDuration, maximumScanDuration]`.
    static func sanitizedScanDuration(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else {
            NSLog("[BeAroundSDK] Invalid periodicScanDuration (%f) — using default %.0fs", value, scanDuration)
            return scanDuration
        }
        if value > maximumScanDuration {
            NSLog("[BeAroundSDK] periodicScanDuration %.0fs above the %.0fs ceiling — clamped (the ~30s BGTask budget must also fit the sync; an oversized window makes every run expire and iOS stops granting executions)", value, maximumScanDuration)
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
    /// Invalid values (NaN/∞/≤0) fall back to the 20-min default; the accepted
    /// range is [10 min, 24 h] (out-of-range values are clamped with a log — see
    /// `PeriodicReconciliationDefaults` for the product rationale).
    public let periodicReconciliationInterval: TimeInterval

    /// Ceiling for the temporary BLE collection window inside the periodic task,
    /// clamped to [3s, 15s] — the ~30s BGTask budget must also fit the sync.
    /// Only used when the task needs to (re)arm the scan.
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
