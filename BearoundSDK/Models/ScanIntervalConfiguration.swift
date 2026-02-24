//
//  ScanIntervalConfiguration.swift
//  BearoundSDK
//
//  Created by Bearound on 12/01/26.
//

import Foundation

/// Scan precision mode
/// Controls the duty cycle for both BLE and CoreLocation scanning
public enum ScanPrecision: String, CaseIterable {
    case high
    case medium
    case low
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
