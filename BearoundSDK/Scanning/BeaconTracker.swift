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
        self.locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        self.locationManager.pausesLocationUpdatesAutomatically = true
        self.beaconRegion = CLBeaconRegion(uuid:  UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!, identifier: "BeaconRegion")
        
        super.init()
        self.locationManager.delegate = self
    }
    
    //-------------------------------
    // MARK: - Access Functions
    //-------------------------------
    func startTracking() {
        debugger.defaultPrint("Starting beacon ranging...")
        rangingStartTime = Date()
        beaconsWithZeroRSSI.removeAll()
        locationManager.startRangingBeacons(satisfying: beaconRegion.beaconIdentityConstraint)
        
        debugger.defaultPrint("Ranging STARTED for: \(beaconRegion.identifier)")
    }
    
    func stopTracking() {
        debugger.defaultPrint("Stopping beacon ranging...")
        locationManager.stopRangingBeacons(satisfying: beaconRegion.beaconIdentityConstraint)
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
            startTracking()
            debugger.defaultPrint("Location permission allowed for full time usage")
        case .authorizedWhenInUse:
            locationManager.allowsBackgroundLocationUpdates = true
            startTracking()
            debugger.defaultPrint("Location permission allowed for foreground research")
        @unknown default:
            debugger.defaultPrint("Something went wrong")
        }
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            locationManager.allowsBackgroundLocationUpdates = true
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
                bluetoothName: "TRACKER:\(beacon.major).\(beacon.minor)",
                bluetoothAddress: nil,
                distanceMeters: BeaconParser().getDistanceInMeters(rssi: Float(beacon.rssi))
            )
            Task { @MainActor in
                self.delegate.updateBeaconList(beaconObj)
            }
        }
    }
}
