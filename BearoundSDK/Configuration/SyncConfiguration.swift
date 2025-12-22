//
//  SyncConfiguration.swift
//  BearoundSDK
//
//  Created by Felipe Costa Araujo on 22/12/25.
//

import Foundation

// MARK: - Sync Interval

/// Predefined synchronization intervals for sending beacons to the API
public enum SyncInterval: TimeInterval, CaseIterable {
    case time5 = 5.0
    case time10 = 10.0
    case time15 = 15.0
    case time20 = 20.0
    case time25 = 25.0
    case time30 = 30.0
    case time35 = 35.0
    case time40 = 40.0
    case time45 = 45.0
    case time50 = 50.0
    case time55 = 55.0
    case time60 = 60.0
    
    /// Interval value in seconds
    public var seconds: TimeInterval {
        return self.rawValue
    }
    
    /// Human-readable description of the interval
    public var description: String {
        return "\(Int(rawValue))s"
    }
}

// MARK: - Backup Size

/// Maximum size for the lost beacons backup
public enum BackupSize: Int, CaseIterable {
    case size5 = 5
    case size10 = 10
    case size15 = 15
    case size20 = 20
    case size25 = 25
    case size30 = 30
    case size35 = 35
    case size40 = 40
    case size45 = 45
    case size50 = 50
    
    /// Maximum number of beacons in backup
    public var count: Int {
        return self.rawValue
    }
    
    /// Human-readable description of the size
    public var description: String {
        return "\(rawValue) beacons"
    }
}
