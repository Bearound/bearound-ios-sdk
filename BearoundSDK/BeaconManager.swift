//
//  BeaconManager.swift
//  BearoundSDK
//
//  CRITICAL: This class handles beacon detection including when app is TERMINATED
//  iOS will relaunch the app when entering a beacon region - we have ~30 seconds to act
//
//  Created by Bearound on 29/12/25.
//

import CoreLocation
import Foundation

#if canImport(UIKit)
    import UIKit
#endif

class BeaconManager: NSObject {

    // MARK: - Constants

    private let beaconUUID = BeaconConstants.uuid

    /// Grace period before removing beacon (foreground)
    private let beaconTimeoutForeground: TimeInterval = 15.0
    /// Grace period before removing beacon (background) - longer for stability
    private let beaconTimeoutBackground: TimeInterval = 30.0

    /// Background ranging duration when app is relaunched from terminated state
    /// iOS gives us ~30 seconds, we use 25 to ensure we complete before being killed
    private let terminatedAppRangingDuration: TimeInterval = 25.0

    /// Minimum misses before removing a beacon (prevents flicker)
    private let minMissCountForRemoval = 2

    /// Maximum RSSI samples for moving average
    private let rssiHistoryMaxCount = 5

    // MARK: - Properties

    private let locationManager = CLLocationManager()
    private var beaconRegion: CLBeaconRegion?

    private var isInForeground: Bool
    private var isRanging = false
    private(set) var isScanning = false

    // MARK: - Callbacks

    var onBeaconsUpdated: (([Beacon]) -> Void)?
    var onError: ((Error) -> Void)?
    var onScanningStateChanged: ((Bool) -> Void)?

    /// CRITICAL: Called when ranging completes in background - triggers sync
    var onBackgroundRangingComplete: (() -> Void)?

    /// Called when first beacon is detected in background - triggers immediate sync
    var onFirstBackgroundBeaconDetected: (() -> Void)?

    /// CRITICAL: Called when app was relaunched from terminated state
    var onAppRelaunchedFromTerminated: (() -> Void)?

    /// Called when iOS reports beacon region entry (BLE proximity)
    var onRegionEnter: (() -> Void)?

    /// Called when iOS reports beacon region exit
    var onRegionExit: (() -> Void)?

    /// Called when active scanning should START (region entered) — host should start BLE central scan.
    var onActiveScanShouldStart: (() -> Void)?

    /// Called when active scanning should STOP (region exited) — host should stop BLE central scan.
    var onActiveScanShouldStop: (() -> Void)?

    /// Called whenever the CLLocationManager reports an authorization change. The SDK uses this
    /// to re-evaluate whether the BLE eye is running Bluetooth-only (no region-monitoring waker)
    /// and must therefore stay in continuous active scanning instead of the idle duty cycle.
    var onAuthorizationChanged: (() -> Void)?

    // MARK: - Beacon State

    private var detectedBeacons: [String: Beacon] = [:]
    private var beaconLastSeen: [String: Date] = [:]
    private var beaconRSSIHistory: [String: [Int]] = [:]
    private var beaconMissCount: [String: Int] = [:]
    private let beaconLock = NSLock()

    // MARK: - Background State

    private var hasNotifiedFirstBackgroundBeacon = false
    /// True when iOS reports the device is currently inside the beacon region (per CLBeaconRegion state).
    private(set) var isInBeaconRegion = false
    private var isProcessingRegionEntry = false
    private var isBackgroundTemporaryRanging = false

    private var backgroundRangingTimer: DispatchSourceTimer?
    private var rangingWatchdog: DispatchSourceTimer?
    private var rangingRefreshTimer: DispatchSourceTimer?

    private var lastBeaconUpdate: Date?

    private var emptyBeaconCount = 0
    private var rangingRestartCount = 0
    private var lastRangingRestartTime: Date?
    private let maxRestartsPerMinute = 3

    // MARK: - Computed Properties

    private var beaconTimeout: TimeInterval {
        isInForeground ? beaconTimeoutForeground : beaconTimeoutBackground
    }

    private var hasBackgroundModes: Bool {
        guard let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] else {
            return false
        }
        return modes.contains("location")
    }

    // MARK: - Initialization

    override init() {
        #if canImport(UIKit)
        let appState = UIApplication.shared.applicationState
        isInForeground = (appState == .active)
        #else
        isInForeground = true
        #endif
        
        super.init()
        setupLocationManager()
        setupAppStateObservers()
        
        #if canImport(UIKit)
        if !isInForeground {
            NSLog("[BeAroundSDK] BeaconManager initialized in BACKGROUND state (appState=%ld)", appState.rawValue)
        }
        #endif
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stopWatchdog()
        stopRangingRefreshTimer()
        stopBackgroundRangingTimer()
    }

    // MARK: - Setup

    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager.distanceFilter = kCLDistanceFilterNone

        if #available(iOS 14.0, *) {
            locationManager.showsBackgroundLocationIndicator = false
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

    // MARK: - App State Handlers

    @objc private func appDidEnterForeground() {
        isInForeground = true
        hasNotifiedFirstBackgroundBeacon = false

        stopRangingRefreshTimer()

        if !isRanging {
            configureBackgroundUpdates(enabled: false)
        }

        // Doctrine: Location is for detection only. Once we know we're in a
        // region, the BLE eye (BluetoothManager) does the tracking. We do NOT
        // start CL ranging here — it would burn battery for no added value.
        // Region monitoring is still active (kernel-level), so iOS will fire
        // didExitRegion / didEnterRegion as needed.
    }

    @objc private func appDidEnterBackground() {
        isInForeground = false

        // Doctrine: do not start CL ranging on background transition. BLE
        // continues to run if we're inside a region. Drop the background-
        // location grant if no ranging is active.
        if !isRanging {
            configureBackgroundUpdates(enabled: false)
        }
    }

    // MARK: - Background Configuration

    private func configureBackgroundUpdates(enabled: Bool) {
        if enabled {
            guard hasBackgroundModes else {
                let error = NSError(
                    domain: "BeAroundSDK",
                    code: BearoundErrorCode.backgroundModesMissing.rawValue,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Background location updates require 'location' in UIBackgroundModes (Info.plist)"
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

    // MARK: - Public Methods

    func startScanning() {
        guard !isScanning else { return }

        let status: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            status = locationManager.authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }

        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            let error = NSError(
                domain: "BeAroundSDK",
                code: BearoundErrorCode.locationPermissionRequired.rawValue,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Location authorization required. Request permissions before starting beacon scanning."
                ]
            )
            onError?(error)
            return
        }

        startMonitoring()
    }

    func stopScanning() {
        guard isScanning else { return }

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

        beaconLock.lock()
        detectedBeacons.removeAll()
        beaconLastSeen.removeAll()
        beaconRSSIHistory.removeAll()
        beaconMissCount.removeAll()
        beaconLock.unlock()

        beaconRegion = nil
        isInBeaconRegion = false
        emptyBeaconCount = 0
        isScanning = false
        onScanningStateChanged?(false)
        onBeaconsUpdated?([])
    }

    func startRanging() {
        guard isScanning, let region = beaconRegion, !isRanging else { return }
        // Doctrine: ranging only runs inside a beacon region. Outside, only region
        // monitoring is active (kernel-level, no CL service running).
        guard isInBeaconRegion else {
            NSLog("[BeAroundSDK] startRanging skipped — not inside beacon region")
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
        guard let region = beaconRegion, isRanging else { return }

        // Don't stop ranging in background - critical for terminated app
        // Use pauseRanging() instead for temporary pause during scan intervals
        if !isInForeground { return }

        locationManager.stopRangingBeacons(satisfying: region.beaconIdentityConstraint)
        isRanging = false
        stopWatchdog()
        stopRangingRefreshTimer()
        configureBackgroundUpdates(enabled: false)

        // DON'T clear beacon data or notify empty list - keep beacons visible for continuous mode
        // Beacon data will be updated on next ranging cycle
    }

    /// Temporarily pause ranging (can be used in background for scan interval control)
    /// Unlike stopRanging(), this works in background and doesn't clear beacon data
    func pauseRanging() {
        guard let region = beaconRegion, isRanging else { return }

        locationManager.stopRangingBeacons(satisfying: region.beaconIdentityConstraint)
        isRanging = false
        stopRangingRefreshTimer()

        // Drop the background-location grant once ranging is paused
        locationManager.allowsBackgroundLocationUpdates = false

        NSLog("[BeAroundSDK] Ranging PAUSED (background=%d)", !isInForeground ? 1 : 0)
    }

    /// Resume ranging after a pause
    func resumeRanging() {
        guard let region = beaconRegion, !isRanging, isScanning else { return }
        // Doctrine: ranging only runs inside a beacon region. Outside, only region
        // monitoring is active. Duty-cycle resume callers will retry once we enter.
        guard isInBeaconRegion else {
            NSLog("[BeAroundSDK] resumeRanging skipped — not inside beacon region")
            return
        }

        configureBackgroundUpdates(enabled: !isInForeground)

        locationManager.startRangingBeacons(satisfying: region.beaconIdentityConstraint)
        isRanging = true

        if !isInForeground {
            startRangingRefreshTimer()
        }

        NSLog("[BeAroundSDK] Ranging RESUMED (background=%d)", !isInForeground ? 1 : 0)
    }

    /// Update the desired accuracy for location manager
    func updateDesiredAccuracy(_ accuracy: CLLocationAccuracy) {
        locationManager.desiredAccuracy = accuracy
    }

    /// Triggers the iOS Location authorization prompt at the requested level.
    /// Internal — exposed publicly via ``BeAroundSDK/requestLocationAuthorization(_:)``.
    func requestLocationAuthorization(_ level: BeAroundLocationAuthorization) {
        switch level {
        case .always:
            locationManager.requestAlwaysAuthorization()
        case .whenInUse:
            locationManager.requestWhenInUseAuthorization()
        }
        NSLog("[BeAroundSDK] Requested Location authorization (level=%@)", level.rawValue)
    }

    // MARK: - Region Monitoring (CRITICAL for terminated app)

    private func startMonitoring() {
        // Prevent duplicate setup
        if beaconRegion != nil && isScanning {
            NSLog("[BeAroundSDK] Region already monitored, skipping duplicate setup")
            return
        }

        let constraint = CLBeaconIdentityConstraint(uuid: beaconUUID)
        let region = CLBeaconRegion(
            beaconIdentityConstraint: constraint,
            identifier: "BeAroundRegion"
        )

        // CRITICAL: These settings enable iOS to wake terminated app
        region.notifyOnEntry = true
        region.notifyOnExit = true
        region.notifyEntryStateOnDisplay = true

        beaconRegion = region

        // Start monitoring FIRST - this is what wakes terminated apps
        locationManager.startMonitoring(for: region)
        locationManager.requestState(for: region)

        // Location updates are NOT started here. GPS only runs when a beacon is
        // actually detected (see didEnterRegion + processBeacons rising edge).

        isScanning = true
        onScanningStateChanged?(true)
        
        let authStatus: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            authStatus = locationManager.authorizationStatus
        } else {
            authStatus = CLLocationManager.authorizationStatus()
        }
        
        NSLog("[BeAroundSDK] Started monitoring beacon region (isInForeground=%d, notifyOnEntry=%d, notifyOnExit=%d, authStatus=%ld)",
              isInForeground ? 1 : 0, region.notifyOnEntry ? 1 : 0, region.notifyOnExit ? 1 : 0, authStatus.rawValue)
        
        if authStatus != .authorizedAlways {
            NSLog("[BeAroundSDK] WARNING: Location authorization is not 'Always' - terminated app relaunch may not work!")
            NSLog("[BeAroundSDK] App must request 'Always' authorization for region monitoring to work when terminated")
        }
    }

    // MARK: - RSSI Moving Average

    private func calculateMovingAverageRSSI(for identifier: String, newRSSI: Int) -> Int {
        var history = beaconRSSIHistory[identifier] ?? []
        history.append(newRSSI)

        if history.count > rssiHistoryMaxCount {
            history.removeFirst()
        }

        beaconRSSIHistory[identifier] = history
        return history.reduce(0, +) / history.count
    }

    private func clearRSSIHistory(for identifier: String) {
        beaconRSSIHistory.removeValue(forKey: identifier)
    }

    // MARK: - Beacon Processing

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
        let currentBeaconIds = Set(beacons.map { "\($0.major.intValue).\($0.minor.intValue)" })

        // Process detected beacons
        for clBeacon in beacons {
            let major = clBeacon.major.intValue
            let minor = clBeacon.minor.intValue
            let identifier = "\(major).\(minor)"

            let isValidRSSI = clBeacon.rssi != 0 && clBeacon.rssi != 127

            if isValidRSSI {
                let averagedRSSI = calculateMovingAverageRSSI(for: identifier, newRSSI: clBeacon.rssi)

                let beacon = Beacon(
                    uuid: beaconUUID,
                    major: major,
                    minor: minor,
                    rssi: averagedRSSI,
                    proximity: BeaconProximity(fromCL: clBeacon.proximity),
                    accuracy: clBeacon.accuracy
                )

                detectedBeacons[identifier] = beacon
                beaconLastSeen[identifier] = now
                beaconMissCount[identifier] = 0
                updatedBeacons.append(beacon)
            } else if let lastSeen = beaconLastSeen[identifier],
                      let cachedBeacon = detectedBeacons[identifier] {
                let timeSinceLastSeen = now.timeIntervalSince(lastSeen)

                if timeSinceLastSeen < beaconTimeout {
                    updatedBeacons.append(cachedBeacon)
                } else {
                    detectedBeacons.removeValue(forKey: identifier)
                    beaconLastSeen.removeValue(forKey: identifier)
                    clearRSSIHistory(for: identifier)
                    beaconMissCount.removeValue(forKey: identifier)
                }
            }
        }

        // Handle missed beacons with grace period
        for identifier in Array(beaconLastSeen.keys) where !currentBeaconIds.contains(identifier) {
            let missCount = (beaconMissCount[identifier] ?? 0) + 1
            beaconMissCount[identifier] = missCount

            if let lastSeen = beaconLastSeen[identifier],
               let cachedBeacon = detectedBeacons[identifier] {
                let timeSinceLastSeen = now.timeIntervalSince(lastSeen)

                // Only remove if timeout AND minimum misses reached
                if timeSinceLastSeen >= beaconTimeout && missCount >= minMissCountForRemoval {
                    detectedBeacons.removeValue(forKey: identifier)
                    beaconLastSeen.removeValue(forKey: identifier)
                    clearRSSIHistory(for: identifier)
                    beaconMissCount.removeValue(forKey: identifier)
                } else {
                    updatedBeacons.append(cachedBeacon)
                }
            }
        }

        let hasBeaconsNow = !updatedBeacons.isEmpty

        if hasBeaconsNow {
            onBeaconsUpdated?(updatedBeacons)

            // CRITICAL: Notify first beacon in background for immediate sync
            if !isInForeground && !hasNotifiedFirstBackgroundBeacon {
                hasNotifiedFirstBackgroundBeacon = true
                NSLog("[BeAroundSDK] First background beacon detected - triggering immediate sync")
                onFirstBackgroundBeaconDetected?()
            }
        }

        startWatchdog()
    }

    // MARK: - Timers

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

    /// CRITICAL: Timer for terminated app background ranging
    private func startBackgroundRangingTimer(duration: TimeInterval) {
        stopBackgroundRangingTimer()

        isBackgroundTemporaryRanging = true
        NSLog("[BeAroundSDK] Starting background ranging timer for %.0fs", duration)

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

        NSLog("[BeAroundSDK] Background ranging complete - triggering sync + dropping CL")

        if let region = beaconRegion, isRanging {
            locationManager.stopRangingBeacons(satisfying: region.beaconIdentityConstraint)
            isRanging = false
            stopWatchdog()
            stopRangingRefreshTimer()

            // CRITICAL: Trigger sync before iOS suspends us
            onBackgroundRangingComplete?()
        }

        // Doctrine: detection done — release the background-location grant so
        // iOS removes the "always location" indicator from the status bar.
        // Region monitoring continues kernel-level and does NOT need this flag.
        configureBackgroundUpdates(enabled: false)
    }

    private func refreshRanging() {
        guard isScanning, isRanging, !isInForeground else { return }
        restartRanging()
    }

    private func checkRangingHealth() {
        // Doctrine: CL ranging only runs during terminated-relaunch warm-up.
        // If ranging isn't active (steady-state, BLE-only), there's nothing
        // to "heal" — beacons are tracked by BluetoothManager.
        guard isScanning, isInBeaconRegion, isRanging else { return }

        if let lastUpdate = lastBeaconUpdate {
            if Date().timeIntervalSince(lastUpdate) > 30 {
                restartRanging()
            }
        } else {
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
                    code: BearoundErrorCode.rangingUnstable.rawValue,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Ranging unstable - restarted \(rangingRestartCount) times in last minute"
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

        let backoffDelay = min(0.5 * Double(rangingRestartCount), 5.0)

        DispatchQueue.main.asyncAfter(deadline: .now() + backoffDelay) { [weak self] in
            guard let self, self.isScanning, let region = self.beaconRegion else { return }

            self.locationManager.startRangingBeacons(satisfying: region.beaconIdentityConstraint)
            self.isRanging = true
            self.startWatchdog()
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension BeaconManager: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            status = manager.authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }

        // Surface every authorization change so the SDK can re-gate the BLE eye's duty cycle
        // (BLE-only vs Location-backed). Fired on all transitions, not just denial.
        onAuthorizationChanged?()

        if status == .denied || status == .restricted {
            let error = NSError(
                domain: "BeAroundSDK",
                code: BearoundErrorCode.locationPermissionDenied.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Location access denied or restricted"]
            )
            onError?(error)

            if isScanning {
                stopScanning()
            }
        }
    }

    func locationManager(_: CLLocationManager, didRange beacons: [CLBeacon], satisfying _: CLBeaconIdentityConstraint) {
        processBeacons(beacons)
    }

    /// CRITICAL: This is called when iOS relaunches the terminated app
    func locationManager(_: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let clBeaconRegion = region as? CLBeaconRegion else { return }

        // Prevent duplicate processing
        guard !isProcessingRegionEntry else {
            NSLog("[BeAroundSDK] Already processing region entry, skipping")
            return
        }
        isProcessingRegionEntry = true
        defer { isProcessingRegionEntry = false }

        #if canImport(UIKit)
        let actualAppState = UIApplication.shared.applicationState
        let actuallyInForeground = (actualAppState == .active)
        NSLog("[BeAroundSDK] ENTERED BEACON REGION (appState=%ld, isInForeground=%d, isScanning=%d, isRanging=%d)",
              actualAppState.rawValue, isInForeground ? 1 : 0, isScanning ? 1 : 0, isRanging ? 1 : 0)
        #else
        let actuallyInForeground = isInForeground
        NSLog("[BeAroundSDK] ENTERED BEACON REGION (isInForeground=%d, isScanning=%d, isRanging=%d)",
              isInForeground ? 1 : 0, isScanning ? 1 : 0, isRanging ? 1 : 0)
        #endif

        let wasAlreadyInRegion = isInBeaconRegion
        isInBeaconRegion = true
        if !wasAlreadyInRegion {
            onRegionEnter?()
            // Host (SDK) should start BLE central scan now that we're inside the region.
            // From here on, beacon ranging is done by the BLE eye — CoreLocation
            // is only used as the detection trigger (region monitoring stays
            // kernel-level, which is essentially free of battery).
            onActiveScanShouldStart?()
        }

        guard !isRanging else {
            NSLog("[BeAroundSDK] Already ranging, skipping region entry handling")
            return
        }

        // CRITICAL: cold-start from terminated state. CL ranging is the only way
        // to seed beacon data fast enough before the OS suspends us again — the
        // BLE central can take several seconds to wake from state-restoration.
        // We bounded the window to `terminatedAppRangingDuration` (25s) so we
        // collapse back to BLE-only as soon as possible.
        if !actuallyInForeground && !isScanning {
            configureBackgroundUpdates(enabled: true)
            NSLog("[BeAroundSDK] APP RELAUNCHED FROM TERMINATED STATE - starting ranging for %.0fs (one-shot)",
                  terminatedAppRangingDuration)

            let constraint = CLBeaconIdentityConstraint(uuid: beaconUUID)
            let bootRegion = CLBeaconRegion(
                beaconIdentityConstraint: constraint,
                identifier: "BeAroundRegion"
            )
            bootRegion.notifyOnEntry = true
            bootRegion.notifyOnExit = true
            bootRegion.notifyEntryStateOnDisplay = true
            beaconRegion = bootRegion

            isScanning = true
            onScanningStateChanged?(true)

            onAppRelaunchedFromTerminated?()

            locationManager.startRangingBeacons(satisfying: clBeaconRegion.beaconIdentityConstraint)
            isRanging = true
            startWatchdog()
            startBackgroundRangingTimer(duration: terminatedAppRangingDuration)
            return
        }

        // Steady-state (FG or BG with scanning already running): do NOT start
        // CL ranging. Beacons are tracked by the BLE eye (BluetoothManager).
        // Region monitoring keeps running kernel-level to detect the exit.
        NSLog("[BeAroundSDK] Region entered — staying on BLE-only (no CL ranging)")
    }

    func locationManager(_: CLLocationManager, didExitRegion region: CLRegion) {
        guard let beaconRegion = region as? CLBeaconRegion else { return }

        NSLog("[BeAroundSDK] EXITED BEACON REGION")

        let wasInRegion = isInBeaconRegion
        isInBeaconRegion = false
        if wasInRegion {
            onRegionExit?()
            // Host (SDK) should stop BLE central scan now that we left the region.
            onActiveScanShouldStop?()
        }
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
        beaconRSSIHistory.removeAll()
        beaconMissCount.removeAll()
        lastBeaconUpdate = nil
        beaconLock.unlock()

        onBeaconsUpdated?([])
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard let beaconRegion = region as? CLBeaconRegion else { return }

        NSLog("[BeAroundSDK] Region state determined: %d", state.rawValue)

        if state == .inside {
            locationManager(manager, didEnterRegion: beaconRegion)
        } else if isInBeaconRegion {
            // iOS reports we're now outside but we thought we were inside —
            // route through the exit handler so active scan gets stopped.
            locationManager(manager, didExitRegion: beaconRegion)
        }
    }

    func locationManager(_: CLLocationManager, didFailWithError error: Error) {
        NSLog("[BeAroundSDK] Location manager error: %@", error.localizedDescription)
        onError?(error)
    }
}
