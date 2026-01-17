//
//  SDKConfigStorage.swift
//  BearoundSDK
//  Persists SDK configuration to survive app restarts
//  Created by Bearound on 17/01/26.
//

import Foundation

/// Persists SDK configuration to UserDefaults to survive app restarts
/// This is critical for background execution when iOS relaunches the app
public class SDKConfigStorage {
    
    private static let suiteName = "com.bearound.sdk.config"
    
    private static let keyBusinessToken = "business_token"
    private static let keyForegroundInterval = "foreground_interval"
    private static let keyBackgroundInterval = "background_interval"
    private static let keyMaxQueuedPayloads = "max_queued_payloads"
    private static let keyEnableBluetooth = "enable_bluetooth"
    private static let keyEnablePeriodic = "enable_periodic"
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
        defaults.set(config.foregroundScanInterval.rawValue, forKey: keyForegroundInterval)
        defaults.set(config.backgroundScanInterval.rawValue, forKey: keyBackgroundInterval)
        defaults.set(config.maxQueuedPayloads.rawValue, forKey: keyMaxQueuedPayloads)
        defaults.set(config.enableBluetoothScanning, forKey: keyEnableBluetooth)
        defaults.set(config.enablePeriodicScanning, forKey: keyEnablePeriodic)
        defaults.set(true, forKey: keyIsConfigured)
        
        defaults.synchronize()
        NSLog("[BeAroundSDK] Configuration saved to persistent storage")
    }
    
    /// Loads the SDK configuration from persistent storage
    static func load() -> SDKConfiguration? {
        guard let defaults = defaults else {
            NSLog("[BeAroundSDK] Failed to access UserDefaults for config storage")
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
        
        let foregroundInterval = ForegroundScanInterval(rawValue: foregroundRaw > 0 ? foregroundRaw : 15.0) ?? .seconds15
        let backgroundInterval = BackgroundScanInterval(rawValue: backgroundRaw > 0 ? backgroundRaw : 60.0) ?? .seconds60
        let maxQueuedPayloads = MaxQueuedPayloads(rawValue: maxQueuedRaw > 0 ? maxQueuedRaw : 100) ?? .medium
        
        let enableBluetooth = defaults.bool(forKey: keyEnableBluetooth)
        let enablePeriodic = defaults.bool(forKey: keyEnablePeriodic)
        
        NSLog("[BeAroundSDK] Loaded configuration from persistent storage")
        
        return SDKConfiguration(
            businessToken: businessToken,
            foregroundScanInterval: foregroundInterval,
            backgroundScanInterval: backgroundInterval,
            maxQueuedPayloads: maxQueuedPayloads,
            enableBluetoothScanning: enableBluetooth,
            enablePeriodicScanning: enablePeriodic
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
        defaults.removeObject(forKey: keyEnableBluetooth)
        defaults.removeObject(forKey: keyEnablePeriodic)
        defaults.removeObject(forKey: keyIsConfigured)
        defaults.removeObject(forKey: keyIsScanning)
        
        defaults.synchronize()
        NSLog("[BeAroundSDK] Configuration cleared from persistent storage")
    }
    
    // MARK: - Scanning State Persistence
    
    /// Saves the current scanning state
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
