//
//  SDKConfiguration.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import Foundation

public struct SDKConfiguration {
    public let appId: String

    public let syncInterval: TimeInterval

    public var enableBluetoothScanning: Bool

    public var enablePeriodicScanning: Bool

    let apiBaseURL: String

    public init(
        appId: String,
        syncInterval: TimeInterval,
        enableBluetoothScanning: Bool = false,
        enablePeriodicScanning: Bool = true
    ) {
        self.appId = appId
        self.enableBluetoothScanning = enableBluetoothScanning
        self.enablePeriodicScanning = enablePeriodicScanning

        self.syncInterval = min(max(syncInterval, 5), 60)

        apiBaseURL = "https://ingest.bearound.io"
    }

    var scanDuration: TimeInterval {
        let calculatedDuration = syncInterval / 3
        return max(5, min(calculatedDuration, 10))
    }
}
