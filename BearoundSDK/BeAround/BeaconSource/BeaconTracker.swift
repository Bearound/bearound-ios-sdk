//
//  BeaconTracker.swift
//  beaconDetector
//
//  Created by Arthur Sousa on 19/06/25.
//

import Foundation
import CoreLocation

class BeaconTracker: NSObject, CLLocationManagerDelegate {
    
    //-------------------------------
    // MARK: - Initial config
    //-------------------------------
    
    //Internal variables
    private var beaconRegion: CLBeaconRegion
    private var delegate: BeaconActionsDelegate
    private var locationManager: CLLocationManager
    private var debugger: DebuggerHelper
    private var beaconsWithZeroRSSI: Set<String> = []  // Track beacons stuck at RSSI = 0
    private var rangingStartTime: Date?
    
    init(delegate: BeaconActionsDelegate, debugger: DebuggerHelper) {
        self.delegate = delegate
        self.debugger = debugger
        self.locationManager = CLLocationManager()
        self.beaconRegion = CLBeaconRegion(uuid:  UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!, identifier: "BeaconRegion")
        
        super.init()
        self.locationManager.delegate = self
        self.beaconRegion.notifyEntryStateOnDisplay = true
        self.beaconRegion.notifyOnEntry = true
        self.beaconRegion.notifyOnExit = true
    }
    
    //-------------------------------
    // MARK: - Access Functions
    //-------------------------------
    func startTracking() {
        debugger.defaultPrint("Starting beacon ranging...")
        rangingStartTime = Date()
        beaconsWithZeroRSSI.removeAll()  // Reset tracking on restart
        locationManager.startMonitoring(for: beaconRegion)
        locationManager.startRangingBeacons(satisfying: beaconRegion.beaconIdentityConstraint)
    }
    
    func stopTracking() {
        debugger.defaultPrint("Stopping beacon ranging...")
        locationManager.stopRangingBeacons(satisfying: beaconRegion.beaconIdentityConstraint)
        locationManager.stopMonitoring(for: beaconRegion)
        rangingStartTime = nil
    }
    
    
    //-------------------------------
    // MARK: - Core Location Manager
    //-------------------------------
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined:
            debugger.defaultPrint("Location permission not determied, app is missing location request")
        case .restricted:
            debugger.defaultPrint("Location permission restricted")
        case .denied:
            debugger.defaultPrint("Location permission denied")
        case .authorizedAlways:
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.startUpdatingLocation()
            startTracking()
            debugger.defaultPrint("Location permission allowed for full time usage")
        case .authorizedWhenInUse:
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.startUpdatingLocation()
            startTracking()
            debugger.defaultPrint("Location permission allowed for foreground research")
        @unknown default:
            debugger.defaultPrint("Something went wrong")
        }
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.startUpdatingLocation()
            startTracking()
            debugger.defaultPrint("Location permission allowed")
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didRangeBeacons beacons: [CLBeacon], in region: CLBeaconRegion) {
        let secondsSinceStart = rangingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let isWarmupPhase = secondsSinceStart < 3.0
        
        for beacon in beacons {
            let beaconKey = "\(beacon.major):\(beacon.minor)"
            
            // Handle RSSI = 0
            if beacon.rssi == 0 {
                if isWarmupPhase {
                    beaconsWithZeroRSSI.insert(beaconKey)
                } else if beaconsWithZeroRSSI.contains(beaconKey) {
                    continue
                } else {
                    beaconsWithZeroRSSI.insert(beaconKey)
                }
            } else {
                beaconsWithZeroRSSI.remove(beaconKey)
            }
            
            let beaconObj = Beacon(
                major: String(describing: beacon.major),
                minor: String(describing: beacon.minor),
                rssi: beacon.rssi,
                bluetoothName: nil,
                bluetoothAddress: nil,
                distanceMeters: BeaconParser().getDistanceInMeters(rssi: Float(beacon.rssi)),
                lastSeen: Date()
            )
            Task { @MainActor in
                self.delegate.updateBeaconList(beaconObj)
            }
        }
    }
}
