//
//  SDKConfiguration.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import Foundation

public struct SDKConfiguration {
    public let appId: String

    public let businessToken: String

    public let syncInterval: TimeInterval

    public var enableBluetoothScanning: Bool

    public var enablePeriodicScanning: Bool

    let apiBaseURL: String

    public init(
        businessToken: String,
        syncInterval: TimeInterval,
        enableBluetoothScanning: Bool = false,
        enablePeriodicScanning: Bool = true
    ) {
        self.businessToken = businessToken
        self.enableBluetoothScanning = enableBluetoothScanning
        self.enablePeriodicScanning = enablePeriodicScanning

        self.syncInterval = min(max(syncInterval, 5), 60)

        apiBaseURL = "https://ingest.bearound.io"

        self.appId = Bundle.main.bundleIdentifier ?? "unknown"
    }

    var scanDuration: TimeInterval {
        let calculatedDuration = syncInterval / 3
        return max(5, min(calculatedDuration, 10))
    }
}
