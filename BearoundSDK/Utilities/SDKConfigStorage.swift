//
//  SDKConfigStorage.swift
//  BearoundSDK
//  Persists SDK configuration to survive app restarts
//  Created by Bearound on 17/01/26.
//

import Foundation

/// Persists SDK configuration to UserDefaults
/// This is critical for background execution when iOS relaunches the app
public class SDKConfigStorage {

    private static let suiteName = "com.bearound.sdk.config"

    private static let keyBusinessToken = "business_token"
    private static let keyScanPrecision = "scan_precision"
    private static let keyMaxQueuedPayloads = "max_queued_payloads"
    private static let keyTechnology = "technology"
    private static let keyIsConfigured = "is_configured"
    private static let keyIsScanning = "is_scanning"
    private static let keyInternalId = "internal_id"
    private static let keyPeriodicEnabled = "periodic_reconciliation_enabled"
    private static let keyPeriodicInterval = "periodic_reconciliation_interval"
    private static let keyPeriodicScanDuration = "periodic_scan_duration"
    private static let keyRequestTrackingOnStart = "request_tracking_on_start"
    private static let keyCollectAdvertisingId = "collect_advertising_id"
    private static let keyCollectLocation = "collect_location"
    private static let keyCollectWifi = "collect_wifi"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    /// Saves the SDK configuration to persistent storage
    static func save(_ config: SDKConfiguration) {
        guard let defaults = defaults else {
            NSLog("[BeAroundSDK] Failed to access UserDefaults for config storage")
            return
        }

        defaults.set(config.businessToken, forKey: keyBusinessToken)
        defaults.set(config.scanPrecision.rawValue, forKey: keyScanPrecision)
        defaults.set(config.maxQueuedPayloads.rawValue, forKey: keyMaxQueuedPayloads)
        defaults.set(config.technology, forKey: keyTechnology)
        defaults.set(config.periodicReconciliationEnabled, forKey: keyPeriodicEnabled)
        defaults.set(config.periodicReconciliationInterval, forKey: keyPeriodicInterval)
        defaults.set(config.periodicScanDuration, forKey: keyPeriodicScanDuration)
        defaults.set(config.requestTrackingOnStart, forKey: keyRequestTrackingOnStart)
        defaults.set(config.collectAdvertisingId, forKey: keyCollectAdvertisingId)
        defaults.set(config.collectLocation, forKey: keyCollectLocation)
        defaults.set(config.collectWifi, forKey: keyCollectWifi)
        defaults.set(true, forKey: keyIsConfigured)

        defaults.synchronize()
        NSLog("[BeAroundSDK] Configuration saved to persistent storage (precision: %@)", config.scanPrecision.rawValue)
    }

    /// Loads the SDK configuration from persistent storage
    /// Called when app is relaunched in background by iOS
    static func load() -> SDKConfiguration? {
        guard let defaults = defaults else {
            NSLog("[BeAroundSDK] Failed to access UserDefaults")
            return nil
        }

        guard defaults.bool(forKey: keyIsConfigured) else {
            NSLog("[BeAroundSDK] No saved configuration found")
            return nil
        }

        guard let businessToken = defaults.string(forKey: keyBusinessToken),
              !businessToken.isEmpty else {
            NSLog("[BeAroundSDK] Saved configuration missing business token")
            return nil
        }

        let precisionRaw = defaults.string(forKey: keyScanPrecision) ?? "high"
        let maxQueuedRaw = defaults.integer(forKey: keyMaxQueuedPayloads)
        // Backward-compatible: configs persisted before technology existed restore the default.
        let technology = defaults.string(forKey: keyTechnology) ?? "ios-native"

        let scanPrecision = ScanPrecision(rawValue: precisionRaw) ?? .high
        let maxQueuedPayloads = MaxQueuedPayloads(rawValue: maxQueuedRaw) ?? .medium

        // Backward-compatible: configs persisted before the periodic-reconciliation
        // fields existed restore the SDK defaults (feature ON, 20 min, 12s window).
        let periodicEnabled = defaults.object(forKey: keyPeriodicEnabled) as? Bool ?? true
        let periodicInterval = defaults.object(forKey: keyPeriodicInterval) as? TimeInterval
            ?? PeriodicReconciliationDefaults.interval
        let periodicScanDuration = defaults.object(forKey: keyPeriodicScanDuration) as? TimeInterval
            ?? PeriodicReconciliationDefaults.scanDuration

        // Backward-compatible: configs persisted before the flag existed restore the
        // default (ON). An app that opted out keeps its choice across background
        // relaunches — otherwise the prompt would reappear the next time iOS revives us.
        let requestTrackingOnStart = defaults.object(forKey: keyRequestTrackingOnStart) as? Bool ?? true

        // Same backward-compatible shape: a config persisted before these switches existed
        // restores everything ON, which is what that install was already doing. An app that
        // opted out keeps the opt-out across every background relaunch — the alternative is a
        // relaunched process quietly uploading the signal the host disabled.
        let collectAdvertisingId = defaults.object(forKey: keyCollectAdvertisingId) as? Bool ?? true
        let collectLocation = defaults.object(forKey: keyCollectLocation) as? Bool ?? true
        let collectWifi = defaults.object(forKey: keyCollectWifi) as? Bool ?? true

        NSLog("[BeAroundSDK] Loaded configuration from storage (precision: %@)", precisionRaw)

        return SDKConfiguration(
            businessToken: businessToken,
            scanPrecision: scanPrecision,
            maxQueuedPayloads: maxQueuedPayloads,
            technology: technology,
            periodicReconciliationEnabled: periodicEnabled,
            periodicReconciliationInterval: periodicInterval,
            periodicScanDuration: periodicScanDuration,
            requestTrackingOnStart: requestTrackingOnStart,
            collectAdvertisingId: collectAdvertisingId,
            collectLocation: collectLocation,
            collectWifi: collectWifi
        )
    }

    /// Clears the saved configuration
    static func clear() {
        guard let defaults = defaults else { return }
        defaults.removeObject(forKey: keyBusinessToken)
        defaults.removeObject(forKey: keyScanPrecision)
        defaults.removeObject(forKey: keyMaxQueuedPayloads)
        defaults.removeObject(forKey: keyTechnology)
        defaults.removeObject(forKey: keyRequestTrackingOnStart)
        defaults.removeObject(forKey: keyCollectAdvertisingId)
        defaults.removeObject(forKey: keyCollectLocation)
        defaults.removeObject(forKey: keyCollectWifi)
        defaults.removeObject(forKey: keyIsConfigured)
        defaults.removeObject(forKey: keyIsScanning)
        defaults.removeObject(forKey: keyInternalId)
        defaults.synchronize()
        NSLog("[BeAroundSDK] Configuration cleared")
    }

    // MARK: - Scanning State Persistence

    static func saveIsScanning(_ value: Bool) {
        guard let defaults = defaults else { return }
        defaults.set(value, forKey: keyIsScanning)
        defaults.synchronize()
        NSLog("[BeAroundSDK] Scanning state saved: %d", value ? 1 : 0)
    }

    /// Loads the saved scanning state
    /// Returns true if scanning was active when app was closed
    static func loadIsScanning() -> Bool {
        return defaults?.bool(forKey: keyIsScanning) ?? false
    }

    // MARK: - User Identity Persistence

    /// Persists (or clears, when nil) the client-provided user id so it survives background relaunch.
    static func saveInternalId(_ internalId: String?) {
        guard let defaults = defaults else { return }
        if let internalId {
            defaults.set(internalId, forKey: keyInternalId)
        } else {
            defaults.removeObject(forKey: keyInternalId)
        }
        defaults.synchronize()
    }

    static func loadInternalId() -> String? {
        defaults?.string(forKey: keyInternalId)
    }
}
