//
//  SDKConfiguration.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import Foundation
import os.log

/// Dedicated log handle for configuration validation — `.error` level renders
/// highlighted (yellow) in the Xcode console and is filterable in Console.app
/// under subsystem `io.bearound.sdk`, so a clamped value is hard to miss.
private let configLog = OSLog(subsystem: "io.bearound.sdk", category: "configuration")

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
    /// `[minimumAcceptedInterval, maximumAcceptedInterval]`. Every adjustment is
    /// surfaced as an `.error`-level os_log — highlighted in the Xcode console.
    static func sanitizedInterval(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else {
            os_log("⚠️ BeAroundSDK: periodicReconciliationInterval (%{public}f) is invalid — using the %{public}.0fs default. Accepted range: %{public}.0fs–%{public}.0fs.",
                   log: configLog, type: .error, value, interval, minimumAcceptedInterval, maximumAcceptedInterval)
            return interval
        }
        if value < minimumAcceptedInterval {
            os_log("⚠️ BeAroundSDK: periodicReconciliationInterval %{public}.0fs is below the %{public}.0fs (10 min) floor — CLAMPED. Sub-10-min BGTask cadence drains the end user's battery without adding product value (region wake-ups and push already cover the real-time path).",
                   log: configLog, type: .error, value, minimumAcceptedInterval)
            return minimumAcceptedInterval
        }
        if value > maximumAcceptedInterval {
            os_log("⚠️ BeAroundSDK: periodicReconciliationInterval %{public}.0fs is above the %{public}.0fs (24 h) ceiling — CLAMPED. If you want the layer off, set periodicReconciliationEnabled: false instead.",
                   log: configLog, type: .error, value, maximumAcceptedInterval)
            return maximumAcceptedInterval
        }
        return value
    }

    /// Sanitizes the scan-window duration into `[minimumScanDuration, maximumScanDuration]`.
    /// Every adjustment is surfaced as an `.error`-level os_log.
    static func sanitizedScanDuration(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else {
            os_log("⚠️ BeAroundSDK: periodicScanDuration (%{public}f) is invalid — using the %{public}.0fs default. Accepted range: %{public}.0fs–%{public}.0fs.",
                   log: configLog, type: .error, value, scanDuration, minimumScanDuration, maximumScanDuration)
            return scanDuration
        }
        if value > maximumScanDuration {
            os_log("⚠️ BeAroundSDK: periodicScanDuration %{public}.0fs is above the %{public}.0fs ceiling — CLAMPED. The BGAppRefreshTask gets ~30s of TOTAL runtime: an oversized scan window leaves no time for the sync, every run expires, and iOS stops granting executions.",
                   log: configLog, type: .error, value, maximumScanDuration)
        }
        if value < minimumScanDuration {
            os_log("⚠️ BeAroundSDK: periodicScanDuration %{public}.1fs is below the %{public}.0fs floor — CLAMPED (a shorter window cannot catch an advertising packet on a cold background wake).",
                   log: configLog, type: .error, value, minimumScanDuration)
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
    /// A best-effort safety net that periodically checks scan health, collects for a
    /// short window when needed, and syncs pending data. Complementary to
    /// CoreBluetooth/CoreLocation — it never replaces them.
    ///
    /// - Note: Best effort by design: iOS decides when (and whether) the task
    ///   actually executes. It never runs after the user force-quits the app.
    public let periodicReconciliationEnabled: Bool

    /// Minimum interval requested before the next eligible reconciliation.
    ///
    /// This is only the **earliest** the system may run the task — a floor, never a
    /// guaranteed cadence. iOS may execute much later, or skip cycles entirely.
    ///
    /// **Accepted range: 10 minutes … 24 hours.** Out-of-range values are clamped
    /// (with an ⚠️ `os_log` you'll see highlighted in the Xcode console); invalid
    /// values (NaN, ∞, ≤ 0) fall back to the default.
    ///
    /// - Important: Values below 10 minutes are **not honored**: iOS doesn't grant
    ///   sub-10-min background cadence, and on devices with a generous budget an
    ///   aggressive floor becomes scan+radio+upload many times per hour — the end
    ///   user's battery pays for it. To turn the layer off, use
    ///   ``periodicReconciliationEnabled`` instead of a huge interval.
    ///
    /// Default: ``PeriodicReconciliationDefaults/interval`` (20 minutes).
    public let periodicReconciliationInterval: TimeInterval

    /// Ceiling for the temporary BLE collection window inside the periodic task.
    /// Only used when the task needs to (re)arm the scan.
    ///
    /// **Accepted range: 3 … 15 seconds.** Out-of-range values are clamped (with an
    /// ⚠️ `os_log` highlighted in the Xcode console).
    ///
    /// - Important: The `BGAppRefreshTask` gets **~30 seconds of total runtime**. A
    ///   window longer than 15s leaves no time for the sync — every run would expire,
    ///   and chronic expiration teaches iOS to stop granting executions at all.
    ///
    /// Default: ``PeriodicReconciliationDefaults/scanDuration`` (12 seconds).
    public let periodicScanDuration: TimeInterval

    /// Lets the SDK raise the App Tracking Transparency prompt by itself, shortly after
    /// `configure()`, so the IDFA is collected without the host wiring up a call.
    ///
    /// Nothing is shown unless the host app declares `NSUserTrackingUsageDescription` —
    /// that key is the real opt-in, and without it this flag has no effect.
    ///
    /// Set to `false` to own the moment (to show your own explainer first, or to prompt
    /// deeper into onboarding) and call
    /// ``BeAroundSDK/requestTrackingAuthorization(completion:)`` when you are ready.
    ///
    /// Default: `true`.
    public let requestTrackingOnStart: Bool

    public init(
        businessToken: String,
        scanPrecision: ScanPrecision = .high,
        maxQueuedPayloads: MaxQueuedPayloads = .medium,
        technology: String = "ios-native",
        periodicReconciliationEnabled: Bool = true,
        periodicReconciliationInterval: TimeInterval = PeriodicReconciliationDefaults.interval,
        periodicScanDuration: TimeInterval = PeriodicReconciliationDefaults.scanDuration,
        requestTrackingOnStart: Bool = true
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
        self.requestTrackingOnStart = requestTrackingOnStart
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
