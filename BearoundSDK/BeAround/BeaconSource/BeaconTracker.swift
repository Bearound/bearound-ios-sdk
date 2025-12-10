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
    
    init(delegate: BeaconActionsDelegate) {
        self.delegate = delegate
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
        locationManager.startMonitoring(for: beaconRegion)
        locationManager.startRangingBeacons(satisfying: beaconRegion.beaconIdentityConstraint)
    }
    
    func stopTracking() {
        locationManager.stopMonitoring(for: beaconRegion)
        locationManager.stopRangingBeacons(satisfying: beaconRegion.beaconIdentityConstraint)
    }
    
    
    //-------------------------------
    // MARK: - Core Location Manager
    //-------------------------------
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined:
            print("[BeAroundSDK]: Location permission not determied, app is missing location request")
        case .restricted:
            print("[BeAroundSDK]: Location permission restricted")
        case .denied:
            print("[BeAroundSDK]: Location permission denied")
        case .authorizedAlways:
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.startUpdatingLocation()
            startTracking()
            print("[BeAroundSDK]: Location permission allowed for full time usage")
        case .authorizedWhenInUse:
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.startUpdatingLocation()
            startTracking()
            print("[BeAroundSDK]: Location permission allowed for foreground research")
        @unknown default:
            print("[BeAroundSDK]: Something went wrong")
        }
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.startUpdatingLocation()
            startTracking()
            print("[BeAroundSDK]: Location permission allowed")
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didRangeBeacons beacons: [CLBeacon], in region: CLBeaconRegion) {
        for beacon in beacons {
            let beacon = Beacon(
                major: String(describing: beacon.major),
                minor: String(describing: beacon.minor),
                rssi: beacon.rssi,
                bluetoothName: nil,
                bluetoothAddress: nil,
                distanceMeters: BeaconParser().getDistanceInMeters(rssi: Float(beacon.rssi)),
                lastSeen: Date()
            )
            Task { @MainActor in
                self.delegate.updateBeaconList(beacon)
            }
        }
    }
}
