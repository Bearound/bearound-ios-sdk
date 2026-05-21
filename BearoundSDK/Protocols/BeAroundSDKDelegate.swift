//
//  BeAroundSDKDelegate.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import CoreLocation
import Foundation

/// Outcome of a beacon-triggered location capture window.
public struct BeAroundLocationCapture {
    /// Why the capture window was opened (e.g. "region_entry_foreground", "beacon_rising_edge").
    public let reason: String
    /// The acquired location, if any. Nil if the window closed due to timeout/no fix.
    public let location: CLLocation?
    /// Outcome label (e.g. "fix_acquired_acc=18m", "timeout", "beacons_lost").
    public let outcome: String
    /// When the capture window closed.
    public let timestamp: Date

    public init(reason: String, location: CLLocation?, outcome: String, timestamp: Date = Date()) {
        self.reason = reason
        self.location = location
        self.outcome = outcome
        self.timestamp = timestamp
    }

    public var hasFix: Bool { location != nil }
}

/// Delegate protocol for receiving SDK events
/// v2.2: Removed didUpdateSyncStatus to reduce battery consumption
/// (the countdown timer was firing every second which was wasteful)
/// v2.3: Added sync lifecycle and background detection callbacks
/// v2.4: Added region transition + location capture callbacks for the beacon-gated GPS model
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

    // MARK: - Beacon Region + Location Capture (v2.4)

    /// Called when iOS reports the device has entered the beacon region (BLE proximity).
    /// This is the canonical "the user is in a beacon zone" signal.
    func didEnterBeaconRegion()

    /// Called when iOS reports the device has exited the beacon region.
    func didExitBeaconRegion()

    /// Called when the SDK opens a location capture window because a beacon was detected.
    /// - Parameter reason: A short tag describing why the window opened.
    func didStartLocationCapture(reason: String)

    /// Called when the location capture window closes — either with a fix or by timeout.
    /// Inspect `result.hasFix` to know whether a coordinate was acquired.
    func didCompleteLocationCapture(_ result: BeAroundLocationCapture)

    /// Called when active scanning state changes. Active = ranging + BLE central scan running.
    /// Active scanning runs ONLY while inside a beacon region — outside the region only the
    /// kernel-level region monitoring is on, which has effectively zero battery cost.
    /// - Parameter isActive: True when ranging + BLE scan are running; false when paused.
    func didChangeActiveScanState(isActive: Bool)
}

// Default implementations (all optional except didUpdateBeacons)
extension BeAroundSDKDelegate {
    public func didFailWithError(_: Error) {}
    public func didChangeScanning(isScanning _: Bool) {}
    public func willStartSync(beaconCount _: Int) {}
    public func didCompleteSync(beaconCount _: Int, success _: Bool, error _: Error?) {}
    public func didDetectBeaconInBackground(beacons _: [Beacon]) {}
    public func didEnterBeaconRegion() {}
    public func didExitBeaconRegion() {}
    public func didStartLocationCapture(reason _: String) {}
    public func didCompleteLocationCapture(_: BeAroundLocationCapture) {}
    public func didChangeActiveScanState(isActive _: Bool) {}
}
