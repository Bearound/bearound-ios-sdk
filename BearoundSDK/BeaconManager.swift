//
//  BeaconManager.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import CoreLocation
import Foundation

#if canImport(UIKit)
    import UIKit
#endif

class BeaconManager: NSObject {
    private let beaconUUID = UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!

    private let locationManager = CLLocationManager()

    private var beaconRegion: CLBeaconRegion?

    private var isInForeground = true

    private var isRanging = false

    var enablePeriodicScanning = false

    var onBeaconsUpdated: (([Beacon]) -> Void)?

    var onError: ((Error) -> Void)?

    var onScanningStateChanged: ((Bool) -> Void)?

    var onBackgroundRangingComplete: (() -> Void)?
    
    /// Called when first beacon is detected in background (for immediate sync)
    var onFirstBackgroundBeaconDetected: (() -> Void)?
    
    /// Called when significant location change is detected (can be used to trigger sync)
    var onSignificantLocationChange: (() -> Void)?
    
    private var hasNotifiedFirstBackgroundBeacon = false
    
    private var isMonitoringSignificantLocationChanges = false

    private var detectedBeacons: [String: Beacon] = [:]
    private var beaconLastSeen: [String: Date] = [:]
    private let beaconLock = NSLock()

    private var backgroundRangingTimer: DispatchSourceTimer?
    private var isBackgroundTemporaryRanging = false

    private let beaconTimeoutForeground: TimeInterval = 5.0
    private let beaconTimeoutBackground: TimeInterval = 10.0

    private var beaconTimeout: TimeInterval {
        isInForeground ? beaconTimeoutForeground : beaconTimeoutBackground
    }

    private(set) var isScanning = false

    private var rangingWatchdog: DispatchSourceTimer?

    private var lastBeaconUpdate: Date?

    private var isInBeaconRegion = false
    
    /// Flag to prevent duplicate processing when didDetermineState calls didEnterRegion
    private var isProcessingRegionEntry = false

    private var rangingRefreshTimer: DispatchSourceTimer?

    private var emptyBeaconCount = 0

    private var rangingRestartCount = 0
    private var lastRangingRestartTime: Date?
    private let maxRestartsPerMinute = 3

    private(set) var lastLocation: CLLocation?

    private var hasBackgroundModes: Bool {
        guard let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        else {
            return false
        }
        return modes.contains("location")
    }

    override init() {
        super.init()
        setupLocationManager()
        setupAppStateObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stopWatchdog()
        stopRangingRefreshTimer()
        stopBackgroundRangingTimer()
    }

    private func setupLocationManager() {
        locationManager.delegate = self

        locationManager.pausesLocationUpdatesAutomatically = false

        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters

        locationManager.distanceFilter = kCLDistanceFilterNone

        if #available(iOS 14.0, *) {
            locationManager.showsBackgroundLocationIndicator = false
        }
    }

    private func configureBackgroundUpdates(enabled: Bool) {
        if enabled {
            guard hasBackgroundModes else {
                let error = NSError(
                    domain: "BeAroundSDK",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Background location updates require 'location' in UIBackgroundModes (Info.plist). Continuous mode will be limited to foreground only."
                    ]
                )
                onError?(error)
                return
            }

            locationManager.allowsBackgroundLocationUpdates = true
        } else {
            locationManager.allowsBackgroundLocationUpdates = false
        }
    }

    private func setupAppStateObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    @objc private func appDidEnterForeground() {
        isInForeground = true
        hasNotifiedFirstBackgroundBeacon = false  // Reset for next background session

        stopRangingRefreshTimer()

        if !isRanging {
            configureBackgroundUpdates(enabled: false)
        }

        if isScanning, let region = beaconRegion, !isRanging {
            locationManager.startRangingBeacons(satisfying: region.beaconIdentityConstraint)
            isRanging = true
            startWatchdog()
        }
    }

    @objc private func appDidEnterBackground() {
        isInForeground = false

        if isScanning {
            configureBackgroundUpdates(enabled: true)

            if !isRanging, let region = beaconRegion {
                locationManager.startRangingBeacons(satisfying: region.beaconIdentityConstraint)
                isRanging = true
                startWatchdog()
            }

            startRangingRefreshTimer()
        }
    }

    func startScanning() {
        guard !isScanning else {
            return
        }

        let status: CLAuthorizationStatus =
            if #available(iOS 14.0, *) {
                locationManager.authorizationStatus
            } else {
                CLLocationManager.authorizationStatus()
            }

        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            let error = NSError(
                domain: "BeAroundSDK",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Location authorization required. The app must request location permissions before starting beacon scanning."
                ]
            )
            onError?(error)
            return
        }

        startMonitoring()
    }

    func stopScanning() {
        guard isScanning else {
            return
        }
        stopWatchdog()
        stopRangingRefreshTimer()
        stopBackgroundRangingTimer()

        if let region = beaconRegion {
            locationManager.stopMonitoring(for: region)
            if isRanging {
                locationManager.stopRangingBeacons(satisfying: region.beaconIdentityConstraint)
                isRanging = false
            }
        }

        locationManager.stopUpdatingLocation()

        beaconLock.lock()
        detectedBeacons.removeAll()
        beaconLastSeen.removeAll()
        lastLocation = nil
        beaconLock.unlock()

        beaconRegion = nil
        isInBeaconRegion = false
        emptyBeaconCount = 0
        isScanning = false
        onScanningStateChanged?(false)
        onBeaconsUpdated?([])
    }

    func startRanging() {
        guard isScanning else {
            return
        }

        guard let region = beaconRegion, !isRanging else {
            return
        }
        locationManager.startRangingBeacons(satisfying: region.beaconIdentityConstraint)
        isRanging = true
        startWatchdog()

        if !isInForeground {
            configureBackgroundUpdates(enabled: true)
            startRangingRefreshTimer()
        }
    }

    func stopRanging() {
        guard let region = beaconRegion, isRanging else {
            return
        }

        if !isInForeground {
            return
        }
        locationManager.stopRangingBeacons(satisfying: region.beaconIdentityConstraint)
        isRanging = false
        stopWatchdog()
        stopRangingRefreshTimer()
        configureBackgroundUpdates(enabled: false)

        beaconLock.lock()
        detectedBeacons.removeAll()
        beaconLastSeen.removeAll()
        beaconLock.unlock()

        onBeaconsUpdated?([])
    }
    
    // MARK: - Significant Location Changes
    
    /// Starts monitoring significant location changes
    /// This can wake up the app even when terminated and trigger a sync opportunity
    func startSignificantLocationMonitoring() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else {
            NSLog("[BeAroundSDK] Significant location changes not available on this device")
            return
        }
        
        guard !isMonitoringSignificantLocationChanges else {
            NSLog("[BeAroundSDK] Already monitoring significant location changes")
            return
        }
        
        locationManager.startMonitoringSignificantLocationChanges()
        isMonitoringSignificantLocationChanges = true
        NSLog("[BeAroundSDK] Started significant location change monitoring")
    }
    
    /// Stops monitoring significant location changes
    func stopSignificantLocationMonitoring() {
        guard isMonitoringSignificantLocationChanges else { return }
        
        locationManager.stopMonitoringSignificantLocationChanges()
        isMonitoringSignificantLocationChanges = false
        NSLog("[BeAroundSDK] Stopped significant location change monitoring")
    }

    private func startMonitoring() {
        // Avoid duplicate region monitoring when relaunched in background
        if beaconRegion != nil && isScanning {
            NSLog("[BeAroundSDK] Region already being monitored, skipping duplicate setup")
            return
        }
        
        let constraint = CLBeaconIdentityConstraint(uuid: beaconUUID)
        let region = CLBeaconRegion(
            beaconIdentityConstraint: constraint, identifier: "BeAroundRegion")

        region.notifyOnEntry = true
        region.notifyOnExit = true
        region.notifyEntryStateOnDisplay = true

        beaconRegion = region

        locationManager.startMonitoring(for: region)
        locationManager.requestState(for: region)

        locationManager.startUpdatingLocation()

        if !enablePeriodicScanning {
            if !isInForeground {
                configureBackgroundUpdates(enabled: true)
            }

            locationManager.startRangingBeacons(satisfying: constraint)
            isRanging = true
            startWatchdog()

            if !isInForeground {
                startRangingRefreshTimer()
            }
        }

        isScanning = true
        onScanningStateChanged?(true)
    }

    private func processBeacons(_ beacons: [CLBeacon]) {
        lastBeaconUpdate = Date()

        if beacons.isEmpty {
            emptyBeaconCount += 1

            if emptyBeaconCount > 5, isInBeaconRegion {
                emptyBeaconCount = 0
                restartRanging()
                return
            }

            startWatchdog()
            return
        }

        emptyBeaconCount = 0

        beaconLock.lock()
        defer { beaconLock.unlock() }

        var updatedBeacons: [Beacon] = []
        let now = Date()

        for clBeacon in beacons {
            let major = clBeacon.major.intValue
            let minor = clBeacon.minor.intValue
            let identifier = "\(major).\(minor)"

            let isValidRSSI = clBeacon.rssi != 0 && clBeacon.rssi != 127

            if isValidRSSI {
                let beacon = Beacon(
                    uuid: beaconUUID,
                    major: major,
                    minor: minor,
                    rssi: clBeacon.rssi,
                    proximity: clBeacon.proximity,
                    accuracy: clBeacon.accuracy
                )

                detectedBeacons[identifier] = beacon
                beaconLastSeen[identifier] = now
                updatedBeacons.append(beacon)
            } else {
                if let lastSeen = beaconLastSeen[identifier],
                    let cachedBeacon = detectedBeacons[identifier]
                {
                    let timeSinceLastSeen = now.timeIntervalSince(lastSeen)

                    let currentTimeout = beaconTimeout
                    if timeSinceLastSeen < currentTimeout {
                        updatedBeacons.append(cachedBeacon)
                    } else {
                        detectedBeacons.removeValue(forKey: identifier)
                        beaconLastSeen.removeValue(forKey: identifier)
                    }
                }
            }
        }

        let currentBeaconIds = Set(beacons.map { "\($0.major.intValue).\($0.minor.intValue)" })
        for identifier in Array(beaconLastSeen.keys) {
            if !currentBeaconIds.contains(identifier) {
                detectedBeacons.removeValue(forKey: identifier)
                beaconLastSeen.removeValue(forKey: identifier)
            }
        }

        if !updatedBeacons.isEmpty {
            onBeaconsUpdated?(updatedBeacons)
            
            // Notify first beacon detection in background for immediate sync
            if !isInForeground && !hasNotifiedFirstBackgroundBeacon {
                hasNotifiedFirstBackgroundBeacon = true
                onFirstBackgroundBeaconDetected?()
            }
        }

        startWatchdog()
    }

    private func startWatchdog() {
        stopWatchdog()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 30.0)
        timer.setEventHandler { [weak self] in
            self?.checkRangingHealth()
        }
        rangingWatchdog = timer
        timer.resume()
    }

    private func stopWatchdog() {
        rangingWatchdog?.cancel()
        rangingWatchdog = nil
    }

    private func startRangingRefreshTimer() {
        stopRangingRefreshTimer()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 120.0, repeating: 120.0)
        timer.setEventHandler { [weak self] in
            self?.refreshRanging()
        }
        rangingRefreshTimer = timer
        timer.resume()
    }

    private func stopRangingRefreshTimer() {
        rangingRefreshTimer?.cancel()
        rangingRefreshTimer = nil
    }

    private func startBackgroundRangingTimer(duration: TimeInterval) {
        stopBackgroundRangingTimer()

        isBackgroundTemporaryRanging = true

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + duration)
        timer.setEventHandler { [weak self] in
            self?.stopBackgroundTemporaryRanging()
        }
        backgroundRangingTimer = timer
        timer.resume()
    }

    private func stopBackgroundRangingTimer() {
        backgroundRangingTimer?.cancel()
        backgroundRangingTimer = nil
    }

    private func stopBackgroundTemporaryRanging() {
        guard isBackgroundTemporaryRanging else { return }

        isBackgroundTemporaryRanging = false
        stopBackgroundRangingTimer()

        if !isInForeground, let region = beaconRegion, isRanging {
            locationManager.stopRangingBeacons(satisfying: region.beaconIdentityConstraint)
            isRanging = false
            stopWatchdog()
            stopRangingRefreshTimer()

            onBackgroundRangingComplete?()
        }
    }

    private func refreshRanging() {
        guard isScanning, isRanging, !isInForeground else { return }
        restartRanging()
    }

    private func checkRangingHealth() {
        guard isScanning, isInBeaconRegion else { return }

        if let lastUpdate = lastBeaconUpdate {
            let timeSinceLastUpdate = Date().timeIntervalSince(lastUpdate)

            if timeSinceLastUpdate > 30 {
                restartRanging()
            }
        } else if isRanging {
            restartRanging()
        }
    }

    private func restartRanging() {
        guard isScanning, let region = beaconRegion else { return }

        let now = Date()
        if let lastRestart = lastRangingRestartTime {
            let timeSinceLastRestart = now.timeIntervalSince(lastRestart)

            if timeSinceLastRestart > 60 {
                rangingRestartCount = 0
            }

            if timeSinceLastRestart < 60, rangingRestartCount >= maxRestartsPerMinute {
                let error = NSError(
                    domain: "BeAroundSDK",
                    code: 5,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Ranging is unstable - restarted \(rangingRestartCount) times in the last minute. Applying exponential backoff."
                    ]
                )
                onError?(error)

                rangingRestartCount = 0
                lastRangingRestartTime = now
                return
            }
        }

        rangingRestartCount += 1
        lastRangingRestartTime = now

        if isRanging {
            locationManager.stopRangingBeacons(satisfying: region.beaconIdentityConstraint)
        }

        let baseDelay = 0.5
        let backoffDelay = min(baseDelay * Double(rangingRestartCount), 5.0)

        DispatchQueue.main.asyncAfter(deadline: .now() + backoffDelay) { [weak self] in
            guard let self, self.isScanning, let region = self.beaconRegion else { return }

            locationManager.startRangingBeacons(satisfying: region.beaconIdentityConstraint)
            isRanging = true
            startWatchdog()
        }
    }
}

extension BeaconManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status: CLAuthorizationStatus =
            if #available(iOS 14.0, *) {
                manager.authorizationStatus
            } else {
                CLLocationManager.authorizationStatus()
            }

        if status == .denied || status == .restricted {
            let error = NSError(
                domain: "BeAroundSDK",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Location access denied or restricted"]
            )
            onError?(error)

            if isScanning {
                stopScanning()
            }
        }
    }

    func locationManager(
        _: CLLocationManager, didRange beacons: [CLBeacon], satisfying _: CLBeaconIdentityConstraint
    ) {
        processBeacons(beacons)
    }

    func locationManager(_: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let clBeaconRegion = region as? CLBeaconRegion else { return }
        
        // Prevent duplicate processing
        guard !isProcessingRegionEntry else {
            NSLog("[BeAroundSDK] Already processing region entry, skipping duplicate")
            return
        }
        isProcessingRegionEntry = true
        defer { isProcessingRegionEntry = false }

        NSLog("[BeAroundSDK] Entered beacon region (isInForeground=%d, isScanning=%d, isRanging=%d)", isInForeground ? 1 : 0, isScanning ? 1 : 0, isRanging ? 1 : 0)
        isInBeaconRegion = true

        guard !isRanging else {
            return
        }

        guard !enablePeriodicScanning else {
            return
        }

        if !isInForeground {
            configureBackgroundUpdates(enabled: true)

            if !isScanning {
                NSLog("[BeAroundSDK] App relaunched by beacon monitoring - starting temporary ranging for 10s")
                isScanning = true  // Mark as scanning for background relaunch
                onScanningStateChanged?(true)
                
                locationManager.startRangingBeacons(
                    satisfying: clBeaconRegion.beaconIdentityConstraint)
                isRanging = true
                startWatchdog()

                startBackgroundRangingTimer(duration: 10.0)
                return
            }

            startRangingRefreshTimer()
        }

        locationManager.startRangingBeacons(satisfying: clBeaconRegion.beaconIdentityConstraint)
        isRanging = true
        startWatchdog()
    }

    func locationManager(_: CLLocationManager, didExitRegion region: CLRegion) {
        guard let beaconRegion = region as? CLBeaconRegion else { return }
        isInBeaconRegion = false
        stopWatchdog()
        stopRangingRefreshTimer()

        if isRanging {
            locationManager.stopRangingBeacons(satisfying: beaconRegion.beaconIdentityConstraint)
            isRanging = false
        }

        configureBackgroundUpdates(enabled: false)

        beaconLock.lock()
        detectedBeacons.removeAll()
        beaconLastSeen.removeAll()
        lastBeaconUpdate = nil
        beaconLock.unlock()

        onBeaconsUpdated?([])
    }

    func locationManager(
        _ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion
    ) {
        guard let beaconRegion = region as? CLBeaconRegion else {
            return
        }

        if state == .inside {
            locationManager(manager, didEnterRegion: beaconRegion)
        } else {
            isInBeaconRegion = false
        }
    }

    func locationManager(_: CLLocationManager, didFailWithError error: Error) {
        onError?(error)
    }

    func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        let age = -location.timestamp.timeIntervalSinceNow
        if age < 15 && location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 100 {
            lastLocation = location
        }
        
        // Detect if app was woken by significant location change
        // This happens when the app is in background/terminated and location changes significantly
        if !isInForeground && isMonitoringSignificantLocationChanges {
            NSLog("[BeAroundSDK] Location update in background - may be significant location change")
            onSignificantLocationChange?()
        }
    }
}

