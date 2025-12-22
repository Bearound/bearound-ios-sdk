//
//  BeaconListeners.swift
//  BearoundSDK
//
//  Created by Felipe Costa Araujo on 22/12/25.
//

import Foundation

// MARK: - Beacon Listener

/// Protocol for receiving beacon detection callbacks
public protocol BeaconListener: AnyObject {
    /// Called when beacons are detected or when their state changes
    /// - Parameters:
    ///   - beacons: Array of detected beacons
    ///   - eventType: Type of event ("enter", "exit", or "failed")
    func onBeaconsDetected(_ beacons: [Beacon], eventType: String)
}

// MARK: - Sync Listener

/// Protocol for monitoring API synchronization status
public protocol SyncListener: AnyObject {
    /// Called when beacon data is successfully synced with the API
    /// - Parameters:
    ///   - eventType: Type of event that was synced
    ///   - beaconCount: Number of beacons synced
    ///   - message: Success message from the server
    func onSyncSuccess(eventType: String, beaconCount: Int, message: String)
    
    /// Called when beacon sync fails
    /// - Parameters:
    ///   - eventType: Type of event that failed
    ///   - beaconCount: Number of beacons that failed to sync
    ///   - errorCode: HTTP error code, if available
    ///   - errorMessage: Error description
    func onSyncError(eventType: String, beaconCount: Int, errorCode: Int?, errorMessage: String)
}

// MARK: - Region Listener

/// Protocol for tracking beacon region entry/exit
public protocol RegionListener: AnyObject {
    /// Called when entering a beacon region
    /// - Parameter regionName: Name of the region entered
    func onRegionEnter(regionName: String)
    
    /// Called when exiting a beacon region
    /// - Parameter regionName: Name of the region exited
    func onRegionExit(regionName: String)
}
