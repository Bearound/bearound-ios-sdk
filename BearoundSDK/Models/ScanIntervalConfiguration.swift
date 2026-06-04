//
//  ScanIntervalConfiguration.swift
//  BearoundSDK
//
//  Created by Bearound on 12/01/26.
//

import Foundation

/// Scan precision mode.
///
/// - Important: On **iOS** the BLE radio scans **continuously in all precisions**. iOS performs
///   its own power duty-cycling for background BLE scanning, so the SDK does not (and cannot
///   safely) stop the radio to save battery — doing so would unregister the kernel scan filter
///   and break terminated-app wake-up. Therefore `ScanPrecision` on iOS does **not** change the
///   radio duty cycle. It only affects:
///   - **sync cadence** (`SDKConfiguration.syncInterval`): `.high` = 15s, `.medium`/`.low` = 60s
///   - **location accuracy** (`SDKConfiguration.precisionLocationAccuracy`): `.high`/`.medium` = 10m, `.low` = 100m
///
///   The enum is kept because the duty-cycle distinction is real on **Android**, where the radio
///   scan window/interval does change per precision.
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
