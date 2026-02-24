//
//  SDKConfiguration.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import Foundation

/// SDK configuration for beacon scanning and API communication
public struct SDKConfiguration {
    public let appId: String
    public let businessToken: String
    public let scanPrecision: ScanPrecision
    public let maxQueuedPayloads: MaxQueuedPayloads

    let apiBaseURL: String

    public init(
        businessToken: String,
        scanPrecision: ScanPrecision = .high,
        maxQueuedPayloads: MaxQueuedPayloads = .medium
    ) {
        self.businessToken = businessToken
        self.scanPrecision = scanPrecision
        self.maxQueuedPayloads = maxQueuedPayloads
        self.apiBaseURL = "https://ingest.bearound.io"
        self.appId = Bundle.main.bundleIdentifier ?? "unknown"
    }

    /// Duration of each scan window (seconds)
    var precisionScanDuration: TimeInterval { 10 }

    /// Pause duration between scan windows (seconds)
    var precisionPauseDuration: TimeInterval {
        switch scanPrecision {
        case .high: return 0
        case .medium: return 10
        case .low: return 50
        }
    }

    /// Number of scan cycles per interval (0 = continuous)
    var precisionCycleCount: Int {
        switch scanPrecision {
        case .high: return 0
        case .medium: return 3
        case .low: return 1
        }
    }

    /// Full cycle interval (seconds)
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
