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
    public let foregroundScanInterval: ForegroundScanInterval
    public let backgroundScanInterval: BackgroundScanInterval
    public let maxQueuedPayloads: MaxQueuedPayloads

    let apiBaseURL: String

    public init(
        businessToken: String,
        foregroundScanInterval: ForegroundScanInterval = .seconds15,
        backgroundScanInterval: BackgroundScanInterval = .seconds60,
        maxQueuedPayloads: MaxQueuedPayloads = .medium
    ) {
        self.businessToken = businessToken
        self.foregroundScanInterval = foregroundScanInterval
        self.backgroundScanInterval = backgroundScanInterval
        self.maxQueuedPayloads = maxQueuedPayloads
        self.apiBaseURL = "https://ingest.bearound.io"
        self.appId = Bundle.main.bundleIdentifier ?? "unknown"
    }

    /// Calculates scan duration for a given interval
    /// Max: 20s, Min: 5s, Calculated as interval / 3
    func scanDuration(for interval: TimeInterval) -> TimeInterval {
        let calculatedDuration = interval / 3
        return max(5, min(calculatedDuration, 20))
    }

    func syncInterval(isInBackground: Bool) -> TimeInterval {
        isInBackground ? backgroundScanInterval.timeInterval : foregroundScanInterval.timeInterval
    }
}
