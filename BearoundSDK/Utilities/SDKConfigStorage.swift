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
    private static let keyForegroundInterval = "foreground_interval"
    private static let keyBackgroundInterval = "background_interval"
    private static let keyMaxQueuedPayloads = "max_queued_payloads"
    private static let keyIsConfigured = "is_configured"
    private static let keyIsScanning = "is_scanning"

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
        defaults.set(config.foregroundScanInterval.timeInterval, forKey: keyForegroundInterval)
        defaults.set(config.backgroundScanInterval.timeInterval, forKey: keyBackgroundInterval)
        defaults.set(config.maxQueuedPayloads.rawValue, forKey: keyMaxQueuedPayloads)
        defaults.set(true, forKey: keyIsConfigured)

        defaults.synchronize()
        NSLog("[BeAroundSDK] Configuration saved to persistent storage")
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

        let foregroundRaw = defaults.double(forKey: keyForegroundInterval)
        let backgroundRaw = defaults.double(forKey: keyBackgroundInterval)
        let maxQueuedRaw = defaults.integer(forKey: keyMaxQueuedPayloads)

        let foregroundInterval = ForegroundScanInterval(
            seconds: foregroundRaw > 0 ? foregroundRaw : ForegroundScanInterval.default
        )
        let backgroundInterval = BackgroundScanInterval(
            seconds: backgroundRaw > 0 ? backgroundRaw : BackgroundScanInterval.default
        )
        let maxQueuedPayloads = MaxQueuedPayloads(rawValue: maxQueuedRaw > 0 ? maxQueuedRaw : 100) ?? .medium

        NSLog("[BeAroundSDK] Loaded configuration from storage (foreground: %.0fs, background: %.0fs)",
              foregroundInterval.timeInterval, backgroundInterval.timeInterval)

        return SDKConfiguration(
            businessToken: businessToken,
            foregroundScanInterval: foregroundInterval,
            backgroundScanInterval: backgroundInterval,
            maxQueuedPayloads: maxQueuedPayloads
        )
    }

    /// Checks if a configuration is saved
    static func isConfigured() -> Bool {
        defaults?.bool(forKey: keyIsConfigured) ?? false
    }

    /// Clears the saved configuration
    static func clear() {
        guard let defaults = defaults else { return }
        defaults.removeObject(forKey: keyBusinessToken)
        defaults.removeObject(forKey: keyForegroundInterval)
        defaults.removeObject(forKey: keyBackgroundInterval)
        defaults.removeObject(forKey: keyMaxQueuedPayloads)
        defaults.removeObject(forKey: keyIsConfigured)
        defaults.removeObject(forKey: keyIsScanning)
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
}
