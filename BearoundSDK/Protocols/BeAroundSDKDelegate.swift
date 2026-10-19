//
//  BeAroundSDKDelegate.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import CoreLocation
import Foundation

/// Delegate protocol for receiving SDK events.
///
/// - Important: **All callbacks are delivered on the main thread.** The SDK dispatches every
///   delegate invocation onto `DispatchQueue.main`, so it is safe to touch UIKit / update UI
///   directly inside any of these methods without hopping threads yourself.
///
/// v2.2: Removed didUpdateSyncStatus to reduce battery consumption
/// (the countdown timer was firing every second which was wasteful)
/// v2.3: Added sync lifecycle and background detection callbacks
/// v2.4: Added region transition callbacks
/// v2.5: Decoupled "two eyes" model — BLE-only zone detection runs independently of CoreLocation region monitoring
/// v2.6: Removed beacon-gated GPS coordinate capture — SDK no longer collects lat/lon. Beacon presence
///       (region monitoring + ranging) and BLE eye remain fully functional.
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

    // MARK: - Beacon Region (v2.4)

    /// Called when iOS reports the device has entered the beacon region (BLE proximity).
    /// This is the canonical "the user is in a beacon zone" signal.
    func didEnterBeaconRegion()

    /// Called when iOS reports the device has exited the beacon region.
    func didExitBeaconRegion()

    /// Called when active scanning state changes. Active = ranging + BLE central scan running.
    /// Active scanning runs ONLY while inside a beacon region — outside the region only the
    /// kernel-level region monitoring is on, which has effectively zero battery cost.
    /// - Parameter isActive: True when ranging + BLE scan are running; false when paused.
    func didChangeActiveScanState(isActive: Bool)

    // MARK: - Two Eyes — Bluetooth Zone (v2.5)
    //
    // The SDK now exposes TWO independent presence signals:
    //
    //   👁 LEFT eye  — Location:  didEnterBeaconRegion / didExitBeaconRegion (v2.4)
    //                  Backed by CLLocationManager iBeacon region monitoring. Works even
    //                  if the app has no BT permission (iOS manages BLE at the system level).
    //
    //   👁 RIGHT eye — Bluetooth: didEnterBluetoothZone / didExitBluetoothZone (v2.5)
    //                  Backed by CBCentralManager BLE scan. Derives "in zone" purely from
    //                  recent BLE detections, independent of CoreLocation. Works even if
    //                  the user has Location off (region monitoring inactive).
    //
    // The two eyes fire independently. UIs can mirror each one in its own debug card.

    /// Called when the BLE scanner detects at least one beacon within a recent rolling window.
    /// This is the canonical "Bluetooth eye sees us in a zone" signal, independent of CoreLocation.
    func didEnterBluetoothZone()

    /// Called when the BLE scanner has seen zero beacons for the configured empty-tick threshold.
    /// Fires even when the Location eye still reports we are inside its monitored region.
    func didExitBluetoothZone()

    /// Called whenever the Bluetooth eye's duty-cycle mode changes. The two modes are:
    ///   .idle   — scanner OFF most of the time; peeks for 10s every 5 min
    ///   .active — scanner ON continuously; UI gets a tick every 10s
    /// - Parameters:
    ///   - mode: the new mode the BT eye just entered
    ///   - nextIdleScanAt: absolute time of the next idle peek; non-nil only when mode is .idle
    func didChangeBluetoothScanMode(_ mode: BluetoothScanMode, nextIdleScanAt: Date?)

    /// Called after the SDK automatically handled a Bearound silent push (woke, scanned, maybe
    /// ingested) — so the host app can surface it (e.g. a local notification) if it wants.
    func didCompletePushScan(beaconsFound: Int, ingestStarted: Bool, pendingBatches: Int)
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
    public func didChangeActiveScanState(isActive _: Bool) {}
    public func didEnterBluetoothZone() {}
    public func didExitBluetoothZone() {}
    public func didChangeBluetoothScanMode(_: BluetoothScanMode, nextIdleScanAt _: Date?) {}
    public func didCompletePushScan(beaconsFound _: Int, ingestStarted _: Bool, pendingBatches _: Int) {}
}
