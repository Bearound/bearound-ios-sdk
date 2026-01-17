//
//  BeAroundSDKDelegate.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import Foundation

/// Delegate protocol for receiving SDK events
/// v2.2: Removed didUpdateSyncStatus to reduce battery consumption
/// (the countdown timer was firing every second which was wasteful)
public protocol BeAroundSDKDelegate: AnyObject {
    /// Called when beacons are detected or updated, array of detected beacons with their current data
    func didUpdateBeacons(_ beacons: [Beacon])

    /// Called when an error occurs, permission issues, API failures, etc.
    func didFailWithError(_ error: Error)

    /// Called when scanning state changes
    func didChangeScanning(isScanning: Bool)
}

extension BeAroundSDKDelegate {
    public func didFailWithError(_: Error) {}
    public func didChangeScanning(isScanning _: Bool) {}
}
