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
/// v2.3: Added sync lifecycle and background detection callbacks
public protocol BeAroundSDKDelegate: AnyObject {
    /// Called when beacons are detected or updated, array of detected beacons with their current data
    func didUpdateBeacons(_ beacons: [Beacon])

    /// Called when an error occurs, permission issues, API failures, etc.
    func didFailWithError(_ error: Error)

    /// Called when scanning state changes
    func didChangeScanning(isScanning: Bool)

    // MARK: - Sync Lifecycle (v2.3)

    /// Called before starting a sync operation
    /// - Parameter beaconCount: Number of beacons to be synced
    func willStartSync(beaconCount: Int)

    /// Called after a sync operation completes
    /// - Parameters:
    ///   - beaconCount: Number of beacons that were synced
    ///   - success: Whether the sync was successful
    ///   - error: The error if sync failed, nil otherwise
    func didCompleteSync(beaconCount: Int, success: Bool, error: Error?)

    // MARK: - Background Events (v2.3)

    /// Called when beacons are detected while app is in background
    /// - Parameter beacons: Array of detected beacons with discovery source info
    func didDetectBeaconInBackground(beacons: [Beacon])
}

// Default implementations (all optional except didUpdateBeacons)
extension BeAroundSDKDelegate {
    public func didFailWithError(_: Error) {}
    public func didChangeScanning(isScanning _: Bool) {}
    public func willStartSync(beaconCount _: Int) {}
    public func didCompleteSync(beaconCount _: Int, success _: Bool, error _: Error?) {}
    public func didDetectBeaconInBackground(beacons _: [Beacon]) {}
}
