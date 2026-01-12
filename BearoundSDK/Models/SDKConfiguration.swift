//
//  SDKConfiguration.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import Foundation

// MARK: - Scan interval enums are defined in ScanIntervalConfiguration.swift

/// SDK configuration for beacon scanning and API communication
public struct SDKConfiguration {
    public let appId: String

    public let businessToken: String

    public let foregroundScanInterval: ForegroundScanInterval

    public let backgroundScanInterval: BackgroundScanInterval

    public let maxQueuedPayloads: MaxQueuedPayloads

    public var enableBluetoothScanning: Bool

    public var enablePeriodicScanning: Bool

    let apiBaseURL: String

    public init(
        businessToken: String,
        foregroundScanInterval: ForegroundScanInterval = .seconds15,
        backgroundScanInterval: BackgroundScanInterval = .seconds60,
        maxQueuedPayloads: MaxQueuedPayloads = .medium,
        enableBluetoothScanning: Bool = false,
        enablePeriodicScanning: Bool = true
    ) {
        self.businessToken = businessToken
        self.foregroundScanInterval = foregroundScanInterval
        self.backgroundScanInterval = backgroundScanInterval
        self.maxQueuedPayloads = maxQueuedPayloads
        self.enableBluetoothScanning = enableBluetoothScanning
        self.enablePeriodicScanning = enablePeriodicScanning

        apiBaseURL = "https://ingest.bearound.io"

        self.appId = Bundle.main.bundleIdentifier ?? "unknown"
    }

    func scanDuration(for interval: TimeInterval) -> TimeInterval {
        let calculatedDuration = interval / 3
        return max(5, min(calculatedDuration, 10))
    }
    
    func syncInterval(isInBackground: Bool) -> TimeInterval {
        isInBackground ? backgroundScanInterval.timeInterval : foregroundScanInterval.timeInterval
    }
}

