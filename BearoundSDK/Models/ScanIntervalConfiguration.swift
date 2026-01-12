//
//  ScanIntervalConfiguration.swift
//  BearoundSDK
//
//  Created by Bearound on 12/01/26.
//

import Foundation

/// Foreground scan interval configuration
/// Controls how frequently the SDK scans for beacons when the app is in foreground
public enum ForegroundScanInterval {
    case seconds5
    case seconds10
    case seconds15
    case seconds20
    case seconds25
    case seconds30
    case seconds35
    case seconds40
    case seconds45
    case seconds50
    case seconds55
    case seconds60
    
    /// Returns the time interval in seconds
    public var timeInterval: TimeInterval {
        switch self {
        case .seconds5: return 5
        case .seconds10: return 10
        case .seconds15: return 15
        case .seconds20: return 20
        case .seconds25: return 25
        case .seconds30: return 30
        case .seconds35: return 35
        case .seconds40: return 40
        case .seconds45: return 45
        case .seconds50: return 50
        case .seconds55: return 55
        case .seconds60: return 60
        }
    }
}

/// Background scan interval configuration
/// Controls how frequently the SDK scans for beacons when the app is in background
public enum BackgroundScanInterval {
    case seconds15
    case seconds30
    case seconds60
    case seconds90
    case seconds120
    
    /// Returns the time interval in seconds
    public var timeInterval: TimeInterval {
        switch self {
        case .seconds15: return 15
        case .seconds30: return 30
        case .seconds60: return 60
        case .seconds90: return 90
        case .seconds120: return 120
        }
    }
}

/// Maximum queued payloads configuration
/// Controls how many failed API request batches are stored for retry
/// Each batch contains all beacons from a single sync operation
public enum MaxQueuedPayloads {
    case small
    case medium
    case large
    case xlarge
    
    /// Returns the maximum number of failed batches that can be queued
    public var value: Int {
        switch self {
        case .small: return 50
        case .medium: return 100
        case .large: return 200
        case .xlarge: return 500
        }
    }
}
