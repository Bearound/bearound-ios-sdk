//
//  ScanIntervalConfiguration.swift
//  BearoundSDK
//
//  Created by Bearound on 12/01/26.
//

import Foundation

/// Foreground scan interval configuration
/// Controls how frequently the SDK scans for beacons when the app is in foreground
public enum ForegroundScanInterval: Double, CaseIterable {
    case seconds5 = 5
    case seconds10 = 10
    case seconds15 = 15
    case seconds20 = 20
    case seconds25 = 25
    case seconds30 = 30
    case seconds35 = 35
    case seconds40 = 40
    case seconds45 = 45
    case seconds50 = 50
    case seconds55 = 55
    case seconds60 = 60
    
    /// Returns the time interval in seconds
    public var timeInterval: TimeInterval {
        rawValue
    }
}

/// Background scan interval configuration
/// Controls how frequently the SDK scans for beacons when the app is in background
public enum BackgroundScanInterval: Double, CaseIterable {
    case seconds15 = 15
    case seconds30 = 30
    case seconds60 = 60
    case seconds90 = 90
    case seconds120 = 120
    
    /// Returns the time interval in seconds
    public var timeInterval: TimeInterval {
        rawValue
    }
}

/// Maximum queued payloads configuration
/// Controls how many failed API request batches are stored for retry
/// Each batch contains all beacons from a single sync operation
public enum MaxQueuedPayloads: Int, CaseIterable {
    case small = 50
    case medium = 100
    case large = 200
    case xlarge = 500
    
    /// Returns the maximum number of failed batches that can be queued
    public var value: Int {
        rawValue
    }
}
