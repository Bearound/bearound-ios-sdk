//
//  BearoundSDK.swift
//  BearoundSDK
//  ios will relaunch the app when entering beacon region, 30 seconds +/-
//
//  Created by Bearound on 29/12/25.
//

import CoreBluetooth
import CoreLocation
import Foundation
import os.log
import UIKit

private let sdkLog = OSLog(subsystem: "com.bearound.sdk", category: "SDK")

public class BeAroundSDK {

    // MARK: - Singleton

    public static let shared = BeAroundSDK()

    public static var version: String {
        return "2.3.6"
    }

    // MARK: - Public Properties

    public weak var delegate: BeAroundSDKDelegate?

    public var isScanning: Bool {
        bluetoothManager.isScanning || beaconManager.isScanning
    }

    public var currentScanPrecision: ScanPrecision? {
        configuration?.scanPrecision
    }

    /// Diagnostic info for debugging BLE/CL scanning issues
    public var bleDiagnosticInfo: String {
        let clScanning = beaconManager.isScanning
        let bleInfo = bluetoothManager.diagnosticInfo
        var accuracyInfo = "n/a"
        if #available(iOS 14.0, *) {
            let acc = CLLocationManager().accuracyAuthorization
            accuracyInfo = acc == .fullAccuracy ? "full" : "reduced"
        }
        let locStatus = Self.authorizationStatus().rawValue
        return "BLE[\(bleInfo)] CL[scanning=\(clScanning) locAuth=\(locStatus) accuracy=\(accuracyInfo)]"
    }

    public var pendingBatchCount: Int {
        offlineBatchStorage.batchCount
    }

    public var pendingBatches: [[Beacon]] {
        offlineBatchStorage.loadAllBatches()
    }

    // MARK: - Private Properties

    private var configuration: SDKConfiguration?
    private var sdkInfo: SDKInfo?
    private var userProperties: UserProperties?

    private let deviceInfoCollector = DeviceInfoCollector(isColdStart: true)
    private let beaconManager = BeaconManager()
    private let bluetoothManager = BluetoothManager()
    private var apiClient: APIClient?

    private var metadataCache: [String: BeaconMetadata] = [:]
    private var syncTimer: DispatchSourceTimer?
    private var dutyCycleTimer: DispatchSourceTimer?
    private var collectedBeacons: [String: Beacon] = [:]
    private let beaconQueue = DispatchQueue(label: "com.bearound.sdk.beaconQueue")
    private var isSyncing = false

    private let offlineBatchStorage = OfflineBatchStorage()

    private var consecutiveFailures = 0
    private var lastFailureTime: Date?
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    private var isInBackground = false
    private var wasLaunchedInBackground = false
    private var syncTrigger = "unknown"

    // MARK: - Initialization

    private init() {
        let appState = UIApplication.shared.applicationState
        wasLaunchedInBackground = appState != .active

        if wasLaunchedInBackground {
            isInBackground = true
            NSLog("[BeAroundSDK] APP LAUNCHED IN BACKGROUND (appState=%ld)", appState.rawValue)
        }

        setupCallbacks()
        setupAppStateObservers()

        // Auto-configure when app is relaunched
        if wasLaunchedInBackground {
            autoConfigureFromStorage()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stopSyncTimer()
        endBackgroundTask()
    }

    // MARK: - Auto Configuration

    /// Auto-configures SDK when app is relaunched in background by iOS
    private func autoConfigureFromStorage() {
        guard configuration == nil else {
            NSLog("[BeAroundSDK] Already configured, skipping auto-configure")
            return
        }

        guard let savedConfig = SDKConfigStorage.load() else {
            NSLog("[BeAroundSDK] No saved configuration for background relaunch")
            return
        }

        // Only auto-start if scanning was active before termination
        guard SDKConfigStorage.loadIsScanning() else {
            NSLog("[BeAroundSDK] Scanning was disabled, not auto-starting")
            configuration = savedConfig
            apiClient = APIClient(configuration: savedConfig)
            setupSDKInfo(from: savedConfig)
            return
        }

        configuration = savedConfig
        apiClient = APIClient(configuration: savedConfig)
        setupSDKInfo(from: savedConfig)

        offlineBatchStorage.maxBatchCount = savedConfig.maxQueuedPayloads.value

        // Check authorizations independently
        let locationStatus = Self.authorizationStatus()
        let locationAuthorized = (locationStatus == .authorizedWhenInUse || locationStatus == .authorizedAlways)

        // iOS 14+: Precise Location off disables all beacon APIs
        var locationCanRangeBeacons = locationAuthorized
        if #available(iOS 14.0, *) {
            if CLLocationManager().accuracyAuthorization == .reducedAccuracy {
                locationCanRangeBeacons = false
                NSLog("[BeAroundSDK] Precise Location is OFF — skipping CoreLocation beacons")
            }
        }

        var bluetoothAuthorized = true
        if #available(iOS 13.1, *) {
            let btAuth = CBCentralManager.authorization
            bluetoothAuthorized = (btAuth != .denied && btAuth != .restricted)
        }

        // BLE starts if authorized
        if bluetoothAuthorized {
            bluetoothManager.autoStartIfAuthorized()
        }

        // CoreLocation starts only if authorized AND precise location is on
        if locationCanRangeBeacons {
            beaconManager.updateDesiredAccuracy(savedConfig.precisionLocationAccuracy)
            if !beaconManager.isScanning {
                beaconManager.startScanning()
            }
        }

        // At least one must be available
        if bluetoothAuthorized || locationCanRangeBeacons {
            startSyncTimer()
            delegate?.didChangeScanning(isScanning: true)
            NSLog("[BeAroundSDK] AUTO-CONFIGURED from storage (BLE=%d, CL=%d)", bluetoothAuthorized ? 1 : 0, locationCanRangeBeacons ? 1 : 0)
        } else {
            NSLog("[BeAroundSDK] AUTO-CONFIGURE: both BLE and Location denied/reduced, cannot scan")
        }
    }

    private func setupSDKInfo(from config: SDKConfiguration) {
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let build = Int(buildNumber) ?? 1
        sdkInfo = SDKInfo(appId: config.appId, build: build)
    }

    // MARK: - Callbacks Setup

    private func setupCallbacks() {
        beaconManager.onBeaconsUpdated = { [weak self] beacons in
            guard let self else { return }

            let enrichedBeacons = beacons.map { beacon -> Beacon in
                let key = "\(beacon.major).\(beacon.minor)"
                let bleTracked = self.bluetoothManager.trackedBeacons[key]
                let metadata = bleTracked?.metadata ?? self.metadataCache[key]

                var sources: Set<BeaconDiscoverySource> = [.coreLocation]
                if bleTracked != nil {
                    sources.insert(.serviceUUID)
                }

                return Beacon(
                    uuid: beacon.uuid,
                    major: beacon.major,
                    minor: beacon.minor,
                    rssi: beacon.rssi,
                    proximity: beacon.proximity,
                    accuracy: beacon.accuracy,
                    timestamp: beacon.timestamp,
                    metadata: metadata,
                    txPower: metadata?.txPower ?? beacon.txPower,
                    discoverySources: sources
                )
            }

            beaconQueue.async {
                var updatedBeacons: [Beacon] = []
                for var beacon in enrichedBeacons {
                    let key = "\(beacon.major).\(beacon.minor)"
                    if let existing = self.collectedBeacons[key] {
                        beacon.syncedAt = existing.syncedAt
                    }
                    // Real detection → always pending sync
                    beacon.alreadySynced = false
                    self.collectedBeacons[key] = beacon
                    updatedBeacons.append(beacon)
                }

                DispatchQueue.main.async {
                    self.delegate?.didUpdateBeacons(updatedBeacons)
                }
            }
        }

        beaconManager.onError = { [weak self] error in
            self?.delegate?.didFailWithError(error)
        }

        beaconManager.onScanningStateChanged = { [weak self] _ in
            guard let self else { return }
            self.delegate?.didChangeScanning(isScanning: self.isScanning)
        }

        // Triggered when background ranging completes
        beaconManager.onBackgroundRangingComplete = { [weak self] in
            guard let self else { return }
            NSLog("[BeAroundSDK] Background ranging complete - syncing NOW")
            self.syncTrigger = "background_ranging_complete"
            self.syncBeaconsImmediately()
        }

        // Triggered on first beacon detection in background (unlock/display on)
        beaconManager.onFirstBackgroundBeaconDetected = { [weak self] in
            guard let self else { return }
            NSLog("[BeAroundSDK] First background beacon (unlock/display) - refreshing BLE and syncing")

            // Refresh BLE scan to get fresh Service Data on unlock
            self.bluetoothManager.refreshScan()

            // Merge BLE beacons and build clean list on beaconQueue for thread safety
            self.beaconQueue.async {
                self.mergeBLEBeacons()
                self.cleanupStaleBeacons()

                let backgroundBeacons = Array(self.collectedBeacons.values).filter { $0.rssi != 0 }
                NSLog("[BeAroundSDK] Background beacon count after cleanup/merge: %d", backgroundBeacons.count)

                DispatchQueue.main.async {
                    self.delegate?.didDetectBeaconInBackground(beacons: backgroundBeacons)
                }
            }

            self.syncTrigger = "display_on"
            self.syncBeaconsImmediately()
        }

        beaconManager.onSignificantLocationChange = { [weak self] in
            guard let self else { return }
            NSLog("[BeAroundSDK] Significant location change - syncing")
            self.syncTrigger = "significant_location"
            self.syncBeaconsImmediately()
        }

        beaconManager.onAppRelaunchedFromTerminated = { [weak self] in
            guard let self else { return }
            NSLog("[BeAroundSDK] APP RELAUNCHED FROM TERMINATED - ensuring configuration")

            if self.configuration == nil {
                self.autoConfigureFromStorage()
            }
        }

        bluetoothManager.delegate = self

        bluetoothManager.onBeaconsUpdated = { [weak self] trackedBeacons in
            guard let self else { return }
            os_log("[SDK] BLE onBeaconsUpdated count=%{public}d clScanning=%{public}d",
                   log: sdkLog, type: .info, trackedBeacons.count, self.beaconManager.isScanning ? 1 : 0)

            beaconQueue.async {
                let trackedKeys = Set(trackedBeacons.map { "\($0.major).\($0.minor)" })

                // Cleanup: only remove BLE-only beacons that left range (don't remove CL beacons)
                for key in self.collectedBeacons.keys where !trackedKeys.contains(key) {
                    if let beacon = self.collectedBeacons[key],
                       !beacon.discoverySources.contains(.coreLocation) {
                        self.collectedBeacons.removeValue(forKey: key)
                    }
                }
            }

            beaconQueue.async {
                var beaconsForDelegate: [Beacon] = []
                for tracked in trackedBeacons {
                    let key = "\(tracked.major).\(tracked.minor)"

                    // If CL is already tracking this beacon, don't overwrite (CL has better proximity/accuracy)
                    if let existing = self.collectedBeacons[key],
                       existing.discoverySources.contains(.coreLocation) {
                        beaconsForDelegate.append(existing)
                        continue
                    }

                    // BLE-only beacon
                    var beacon = Beacon(
                        uuid: UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!,
                        major: tracked.major,
                        minor: tracked.minor,
                        rssi: tracked.rssi,
                        proximity: .bt,
                        accuracy: -1,
                        metadata: tracked.metadata,
                        txPower: tracked.txPower,
                        discoverySources: [tracked.discoverySource]
                    )
                    if let existing = self.collectedBeacons[key] {
                        beacon.syncedAt = existing.syncedAt
                    }
                    beacon.alreadySynced = false
                    self.collectedBeacons[key] = beacon
                    beaconsForDelegate.append(beacon)
                }

                DispatchQueue.main.async {
                    self.delegate?.didUpdateBeacons(beaconsForDelegate)
                }
            }
        }
    }

    private func setupAppStateObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func appDidEnterBackground() {
        isInBackground = true

        // Restart duty cycle — precision-based, no FG/BG recalculation needed
        if isScanning {
            startSyncTimer()
        }
    }

    @objc private func appWillEnterForeground() {
        isInBackground = false

        if isScanning {
            startSyncTimer()
        }
    }

    // MARK: - Public API

    public func configure(
        businessToken: String,
        scanPrecision: ScanPrecision = .high,
        maxQueuedPayloads: MaxQueuedPayloads = .medium
    ) {
        let config = SDKConfiguration(
            businessToken: businessToken,
            scanPrecision: scanPrecision,
            maxQueuedPayloads: maxQueuedPayloads
        )

        configuration = config
        apiClient = APIClient(configuration: config)
        setupSDKInfo(from: config)

        offlineBatchStorage.maxBatchCount = config.maxQueuedPayloads.value

        // Save for background relaunch
        SDKConfigStorage.save(config)

        if isScanning {
            startSyncTimer()
        }
    }

    public func setUserProperties(_ properties: UserProperties) {
        userProperties = properties
    }

    public func clearUserProperties() {
        userProperties = nil
    }

    public func startScanning() {
        guard configuration != nil else {
            let error = NSError(
                domain: "BeAroundSDK",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "SDK not configured. Call configure(businessToken:) first."
                ]
            )
            delegate?.didFailWithError(error)
            return
        }

        isInBackground = (UIApplication.shared.applicationState == .background)

        os_log("[SDK] ========== startScanning() ==========", log: sdkLog, type: .info)

        // 1. Check authorizations independently
        let locationStatus = Self.authorizationStatus()
        let locationAuthorized = (locationStatus == .authorizedWhenInUse || locationStatus == .authorizedAlways)
        os_log("[SDK] locationStatus=%{public}ld authorized=%{public}d", log: sdkLog, type: .info, locationStatus.rawValue, locationAuthorized ? 1 : 0)

        // iOS 14+: Precise Location off (reducedAccuracy) disables all beacon APIs (ranging + region monitoring)
        var locationCanRangeBeacons = locationAuthorized
        if #available(iOS 14.0, *) {
            let accuracy = CLLocationManager().accuracyAuthorization
            os_log("[SDK] accuracyAuth=%{public}ld (0=full, 1=reduced)", log: sdkLog, type: .info, accuracy.rawValue)
            if accuracy == .reducedAccuracy {
                locationCanRangeBeacons = false
                os_log("[SDK] Precise OFF — CL disabled", log: sdkLog, type: .info)
            }
        }

        var bluetoothAuthorized = true
        if #available(iOS 13.1, *) {
            let btAuth = CBCentralManager.authorization
            bluetoothAuthorized = (btAuth != .denied && btAuth != .restricted)
            os_log("[SDK] btAuth=%{public}ld bleAuthorized=%{public}d", log: sdkLog, type: .info, btAuth.rawValue, bluetoothAuthorized ? 1 : 0)
        }

        // If neither system can run, error
        guard locationCanRangeBeacons || bluetoothAuthorized else {
            let error = NSError(
                domain: "BeAroundSDK",
                code: 7,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Cannot scan for beacons. Bluetooth is denied and Location has Precise Location disabled."
                ]
            )
            delegate?.didFailWithError(error)
            return
        }

        // 2. BLE starts if authorized
        if bluetoothAuthorized {
            bluetoothManager.autoStartIfAuthorized()
        }

        // 3. CoreLocation starts only if authorized AND precise location is on
        if locationCanRangeBeacons {
            beaconManager.updateDesiredAccuracy(configuration!.precisionLocationAccuracy)
            beaconManager.startScanning()
            beaconManager.startSignificantLocationMonitoring()
        } else if beaconManager.isScanning {
            // CL was running but can no longer range beacons (e.g., Precise Location turned off)
            beaconManager.stopScanning()
            beaconManager.stopSignificantLocationMonitoring()
        }

        // 4. Always: sync timer, persist, BGTasks
        startSyncTimer()
        delegate?.didChangeScanning(isScanning: true)
        SDKConfigStorage.saveIsScanning(true)

        if #available(iOS 13.0, *) {
            BackgroundTaskManager.shared.scheduleSync()
            BackgroundTaskManager.shared.scheduleProcessingTask()
        }

        os_log("[SDK] STARTED BLE=%{public}d CL=%{public}d", log: sdkLog, type: .info,
               bluetoothAuthorized ? 1 : 0, locationCanRangeBeacons ? 1 : 0)
    }

    public func stopScanning() {
        bluetoothManager.stopScanning()

        if beaconManager.isScanning {
            beaconManager.stopScanning()
            beaconManager.stopSignificantLocationMonitoring()
        }

        stopSyncTimer()
        syncTrigger = "stop_scanning"
        syncBeaconsImmediately()
        delegate?.didChangeScanning(isScanning: false)

        SDKConfigStorage.saveIsScanning(false)

        if #available(iOS 13.0, *) {
            BackgroundTaskManager.shared.cancelPendingTasks()
        }
    }

    public static func isLocationAvailable() -> Bool {
        CLLocationManager.locationServicesEnabled()
    }

    public static func authorizationStatus() -> CLAuthorizationStatus {
        if #available(iOS 14.0, *) {
            return CLLocationManager().authorizationStatus
        } else {
            return CLLocationManager.authorizationStatus()
        }
    }

    // MARK: - Sync Timer

    private func startSyncTimer() {
        guard let config = configuration else { return }

        stopSyncTimer()

        let actualAppState = UIApplication.shared.applicationState
        isInBackground = (actualAppState == .background)

        let precision = config.scanPrecision

        // .high: Continuous BLE + CL, sync every 15s
        if precision == .high {
            // Ensure CL is ranging continuously
            if beaconManager.isScanning {
                beaconManager.resumeRanging()
            }
            // Ensure BLE is scanning continuously
            bluetoothManager.resumeScanning()

            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            syncTimer = timer
            timer.schedule(deadline: .now() + config.syncInterval, repeating: config.syncInterval)
            timer.setEventHandler { [weak self] in
                self?.syncTrigger = "precision_high_timer"
                self?.syncBeacons()
            }
            timer.resume()

            NSLog("[BeAroundSDK] Precision HIGH: continuous scan, sync every %.0fs", config.syncInterval)
            return
        }

        // .medium / .low: Duty cycle — N cycles of 10s scan + pause, then sync
        let scanDuration = config.precisionScanDuration
        let pauseDuration = config.precisionPauseDuration
        let cycleCount = config.precisionCycleCount
        let cycleInterval = config.precisionCycleInterval

        NSLog("[BeAroundSDK] Precision %@: %d cycles of %.0fs scan + %.0fs pause, interval=%.0fs",
              precision.rawValue, cycleCount, scanDuration, pauseDuration, cycleInterval)

        // Start first set of cycles immediately
        startDutyCycles(scanDuration: scanDuration, pauseDuration: pauseDuration, cycleCount: cycleCount)

        // Repeat every cycleInterval
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        syncTimer = timer
        timer.schedule(deadline: .now() + cycleInterval, repeating: cycleInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Sync at the start of each new interval (after previous cycles completed)
            self.syncTrigger = "precision_\(precision.rawValue)_timer"
            self.syncBeacons()

            // Start new set of cycles
            self.startDutyCycles(scanDuration: scanDuration, pauseDuration: pauseDuration, cycleCount: cycleCount)
        }
        timer.resume()
    }

    /// Runs N duty cycles of scan+pause for BLE and CL
    private func startDutyCycles(scanDuration: TimeInterval, pauseDuration: TimeInterval, cycleCount: Int) {
        stopDutyCycleTimer()

        var currentCycle = 0

        func runCycle() {
            guard currentCycle < cycleCount else { return }

            // START scanning
            self.bluetoothManager.resumeScanning()
            if self.beaconManager.isScanning {
                self.beaconManager.resumeRanging()
            }

            NSLog("[BeAroundSDK] Duty cycle %d/%d START (scan %.0fs)", currentCycle + 1, cycleCount, scanDuration)

            // After scanDuration, PAUSE
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + scanDuration) { [weak self] in
                guard let self else { return }

                self.bluetoothManager.pauseScanning()
                if self.beaconManager.isScanning {
                    self.beaconManager.pauseRanging()
                }

                NSLog("[BeAroundSDK] Duty cycle %d/%d PAUSE (%.0fs)", currentCycle + 1, cycleCount, pauseDuration)

                currentCycle += 1

                // If more cycles remain, schedule next one after pause
                if currentCycle < cycleCount {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + pauseDuration) {
                        runCycle()
                    }
                }
            }
        }

        runCycle()
    }

    private func stopSyncTimer() {
        syncTimer?.cancel()
        syncTimer = nil
        stopDutyCycleTimer()
    }

    private func stopDutyCycleTimer() {
        dutyCycleTimer?.cancel()
        dutyCycleTimer = nil
    }

    // MARK: - Beacon Cleanup & Merge

    /// Remove beacons that haven't been updated recently
    /// Uses 2x the current sync interval as the grace period
    private func cleanupStaleBeacons() {
        let maxAge: TimeInterval
        if let config = configuration {
            maxAge = config.syncInterval * 2
        } else {
            maxAge = 60.0
        }

        let now = Date()
        var removedCount = 0

        for (key, beacon) in collectedBeacons {
            // Skip synced beacons — their removal is handled by the 10s delayed cleanup
            if beacon.alreadySynced { continue }
            if now.timeIntervalSince(beacon.timestamp) > maxAge {
                collectedBeacons.removeValue(forKey: key)
                removedCount += 1
            }
        }

        if removedCount > 0 {
            NSLog("[BeAroundSDK] Cleaned up %d stale beacons from collectedBeacons", removedCount)
        }
    }

    /// Merge BLE-tracked beacons into collectedBeacons for sync
    /// Adds BLE-only beacons and enriches existing beacons with Service UUID source
    private func mergeBLEBeacons() {
        let bleTracked = bluetoothManager.trackedBeacons
        guard !bleTracked.isEmpty else { return }

        let targetUUID = UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!

        for (key, tracked) in bleTracked {
            // Only enrich beacons that already exist in collectedBeacons
            // Never add new beacons here — that's the job of detection callbacks
            guard let existing = collectedBeacons[key] else { continue }

            // Only enrich with Service UUID source if not already present
            if !existing.discoverySources.contains(.serviceUUID) {
                var sources = existing.discoverySources
                sources.insert(.serviceUUID)
                var enriched = Beacon(
                    uuid: existing.uuid,
                    major: existing.major,
                    minor: existing.minor,
                    rssi: existing.rssi,
                    proximity: existing.proximity,
                    accuracy: existing.accuracy,
                    timestamp: existing.timestamp,
                    metadata: tracked.metadata ?? existing.metadata,
                    txPower: tracked.txPower,
                    discoverySources: sources
                )
                enriched.alreadySynced = existing.alreadySynced
                enriched.syncedAt = existing.syncedAt
                collectedBeacons[key] = enriched
            }
        }
    }

    // MARK: - Beacon Sync

    private func syncBeaconsImmediately() {
        syncBeacons()
    }

    private func syncBeacons() {
        beaconQueue.async { [weak self] in
            guard let self else { return }

            // Begin background task to ensure we complete before iOS kills us
            self.beginBackgroundTask()

            guard !isSyncing else {
                self.endBackgroundTask()
                return
            }

            guard let apiClient = self.apiClient, let sdkInfo = self.sdkInfo else {
                NSLog("[BeAroundSDK] Sync failed - not configured")
                self.endBackgroundTask()
                return
            }

            var beaconsToSend: [Beacon] = []

            // Clean up stale beacons and merge BLE Service Data
            self.cleanupStaleBeacons()
            self.mergeBLEBeacons()

            if !collectedBeacons.isEmpty {
                // Log state of all collected beacons before filtering
                for (key, b) in collectedBeacons {
                    let age = Int(Date().timeIntervalSince(b.timestamp))
                    NSLog("[BeAroundSDK] COLLECTED %@ | synced=%d | rssi=%d | age=%ds | syncedAt=%@",
                          key,
                          b.alreadySynced ? 1 : 0,
                          b.rssi,
                          age,
                          b.syncedAt?.description ?? "nil")
                }

                // Only send beacons that haven't been synced yet, and filter invalid RSSI
                beaconsToSend = Array(collectedBeacons.values).filter { !$0.alreadySynced && $0.rssi != 0 }
                NSLog("[BeAroundSDK] Syncing %d of %d beacons (pending only)", beaconsToSend.count, collectedBeacons.count)
            }

            guard !beaconsToSend.isEmpty else {
                NSLog("[BeAroundSDK] No new beacons to sync")
                self.endBackgroundTask()
                // No new beacons — drain retry queue if pending batches exist
                if self.shouldRetryFailedBatches() {
                    self.drainRetryQueue()
                }
                return
            }

            isSyncing = true
            let beaconCount = beaconsToSend.count

            // Notify delegate that sync is starting
            DispatchQueue.main.async {
                self.delegate?.willStartSync(beaconCount: beaconCount)
            }

            let locationPermission = Self.authorizationStatus()
            let bluetoothState = bluetoothManager.isPoweredOn ? "powered_on" : "powered_off"
            let appInForeground = !isInBackground

            let userDevice = deviceInfoCollector.collectDeviceInfo(
                locationPermission: locationPermission,
                bluetoothState: bluetoothState,
                appInForeground: appInForeground,
                location: beaconManager.lastLocation
            )

            let trigger = self.syncTrigger
            self.syncTrigger = "unknown"

            apiClient.sendBeacons(
                beaconsToSend,
                sdkInfo: sdkInfo,
                userDevice: userDevice,
                userProperties: userProperties,
                syncTrigger: trigger
            ) { [weak self] result in
                guard let self else { return }

                switch result {
                case .success:
                    NSLog("[BeAroundSDK] Sync SUCCESS")
                    self.endBackgroundTask()

                    // Notify delegate of successful sync
                    DispatchQueue.main.async {
                        self.delegate?.didCompleteSync(beaconCount: beaconCount, success: true, error: nil)
                    }

                    // Build list of synced beacon keys before entering the queue
                    let syncedKeys = beaconsToSend.map { "\($0.major).\($0.minor)" }

                    // Mark synced + reset isSyncing in a SINGLE beaconQueue block to prevent race conditions
                    beaconQueue.async {
                        self.isSyncing = false
                        self.consecutiveFailures = 0
                        self.lastFailureTime = nil

                        // Mark sent beacons as synced
                        let now = Date()
                        for key in syncedKeys {
                            if self.collectedBeacons[key] != nil {
                                self.collectedBeacons[key]!.alreadySynced = true
                                self.collectedBeacons[key]!.syncedAt = now
                                NSLog("[BeAroundSDK] MARKED SYNCED: %@", key)
                            }
                        }

                        // Notify delegate with updated beacons (UI reflects "synced" state)
                        let updatedBeacons = Array(self.collectedBeacons.values)
                        DispatchQueue.main.async {
                            self.delegate?.didUpdateBeacons(updatedBeacons)
                        }

                        // Schedule delayed removal after 10 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                            guard let self else { return }
                            self.beaconQueue.async {
                                for key in syncedKeys {
                                    // Only remove if still marked as synced (not re-detected)
                                    if self.collectedBeacons[key]?.alreadySynced == true {
                                        self.collectedBeacons.removeValue(forKey: key)
                                        NSLog("[BeAroundSDK] REMOVED (10s expired): %@", key)
                                    } else {
                                        NSLog("[BeAroundSDK] KEPT (re-detected): %@", key)
                                    }
                                }
                            }
                        }

                        // Drain retry queue after new beacons synced
                        if self.shouldRetryFailedBatches() {
                            self.drainRetryQueue()
                        }
                    }

                case .failure(let error):
                    NSLog("[BeAroundSDK] Sync FAILED: %@", error.localizedDescription)
                    self.endBackgroundTask()

                    // Notify delegate of failed sync
                    DispatchQueue.main.async {
                        self.delegate?.didCompleteSync(beaconCount: beaconCount, success: false, error: error)
                    }

                    beaconQueue.async {
                        self.isSyncing = false
                        self.consecutiveFailures += 1
                        self.lastFailureTime = Date()

                        // Save to persistent storage for retry
                        self.offlineBatchStorage.saveBatch(beaconsToSend)
                        NSLog("[BeAroundSDK] Saved failed batch to persistent storage")

                        if self.consecutiveFailures >= 10 {
                            let circuitBreakerError = NSError(
                                domain: "BeAroundSDK",
                                code: 6,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "API unreachable after \(self.consecutiveFailures) failures. Beacons queued for retry."
                                ]
                            )
                            DispatchQueue.main.async {
                                self.delegate?.didFailWithError(circuitBreakerError)
                            }
                        }
                    }

                    DispatchQueue.main.async {
                        self.delegate?.didFailWithError(error)
                    }
                }
            }
        }
    }

    // MARK: - Retry Queue Drain (chunked)

    /// Maximum number of batches to merge per retry API call
    private static let retryChunkSize = 5

    /// Drains the retry queue by sending batches in chunks of 5, sequentially.
    /// On success of each chunk, immediately sends the next until the queue is empty.
    /// On failure, stops draining (will retry on next sync cycle).
    private func drainRetryQueue() {
        beaconQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isSyncing else {
                NSLog("[BeAroundSDK] Retry drain skipped — sync in progress")
                return
            }
            guard let apiClient = self.apiClient, let sdkInfo = self.sdkInfo else { return }

            let totalPending = self.offlineBatchStorage.batchCount
            guard totalPending > 0 else {
                NSLog("[BeAroundSDK] Retry queue empty, nothing to drain")
                return
            }

            let chunkBatches = self.offlineBatchStorage.loadOldestBatches(Self.retryChunkSize)
            let chunkCount = chunkBatches.count
            let beaconsToSend = chunkBatches.flatMap { $0 }.filter { $0.rssi != 0 }

            guard !beaconsToSend.isEmpty else {
                // All beacons in this chunk had rssi=0, skip and try next
                self.offlineBatchStorage.removeOldestBatches(chunkCount)
                NSLog("[BeAroundSDK] Skipped %d empty retry batches", chunkCount)
                self.drainRetryQueue()
                return
            }

            self.isSyncing = true
            let beaconCount = beaconsToSend.count

            NSLog("[BeAroundSDK] Retry drain: sending chunk of %d batches (%d beacons), %d total pending",
                  chunkCount, beaconCount, totalPending)

            self.beginBackgroundTask()

            DispatchQueue.main.async {
                self.delegate?.willStartSync(beaconCount: beaconCount)
            }

            let locationPermission = Self.authorizationStatus()
            let bluetoothState = self.bluetoothManager.isPoweredOn ? "powered_on" : "powered_off"
            let appInForeground = !self.isInBackground

            let userDevice = self.deviceInfoCollector.collectDeviceInfo(
                locationPermission: locationPermission,
                bluetoothState: bluetoothState,
                appInForeground: appInForeground,
                location: self.beaconManager.lastLocation
            )

            apiClient.sendBeacons(
                beaconsToSend,
                sdkInfo: sdkInfo,
                userDevice: userDevice,
                userProperties: self.userProperties,
                syncTrigger: "retry_drain"
            ) { [weak self] result in
                guard let self else { return }

                switch result {
                case .success:
                    NSLog("[BeAroundSDK] Retry chunk SUCCESS (%d batches, %d beacons)", chunkCount, beaconCount)
                    self.endBackgroundTask()

                    DispatchQueue.main.async {
                        self.delegate?.didCompleteSync(beaconCount: beaconCount, success: true, error: nil)
                    }

                    self.beaconQueue.async {
                        self.isSyncing = false
                        self.consecutiveFailures = 0
                        self.lastFailureTime = nil
                        self.offlineBatchStorage.removeOldestBatches(chunkCount)

                        // Continue draining if more batches remain
                        if self.offlineBatchStorage.batchCount > 0 {
                            NSLog("[BeAroundSDK] %d retry batches remaining, continuing drain...", self.offlineBatchStorage.batchCount)
                            self.drainRetryQueue()
                        } else {
                            NSLog("[BeAroundSDK] All retry batches drained successfully")
                        }
                    }

                case .failure(let error):
                    NSLog("[BeAroundSDK] Retry chunk FAILED: %@ — drain stopped", error.localizedDescription)
                    self.endBackgroundTask()

                    DispatchQueue.main.async {
                        self.delegate?.didCompleteSync(beaconCount: beaconCount, success: false, error: error)
                        self.delegate?.didFailWithError(error)
                    }

                    self.beaconQueue.async {
                        self.isSyncing = false
                        self.consecutiveFailures += 1
                        self.lastFailureTime = Date()
                    }
                }
            }
        }
    }

    // MARK: - Background Execution Support

    /// Registers background tasks with the system
    /// Must be called in application(_:didFinishLaunchingWithOptions:) BEFORE the app finishes launching
    public func registerBackgroundTasks() {
        if #available(iOS 13.0, *) {
            BackgroundTaskManager.shared.registerTasks()
        }
    }

    /// Called by BackgroundTaskManager when BGTaskScheduler triggers
    public func performBackgroundSync(trigger: String = "background_sync", completion: @escaping (Bool) -> Void) {
        NSLog("[BeAroundSDK] Background task triggered (trigger=%@)", trigger)

        beaconQueue.async { [weak self] in
            guard let self else {
                completion(false)
                return
            }

            let hasBeacons = !collectedBeacons.isEmpty
            let hasFailedBatches = offlineBatchStorage.batchCount > 0

            if hasBeacons || hasFailedBatches {
                NSLog("[BeAroundSDK] Background sync: beacons=%d, failed=%d",
                      hasBeacons ? 1 : 0, hasFailedBatches ? 1 : 0)
                self.syncTrigger = trigger
                syncBeacons()
                completion(true)
            } else {
                NSLog("[BeAroundSDK] Background sync: nothing to sync")
                completion(false)
            }
        }
    }

    /// Called by BGTaskScheduler — refreshes BLE scan, collects Service Data, then syncs
    public func performBackgroundBLERefreshAndSync(bleScanDuration: TimeInterval = 3.0, trigger: String = "bg_task", completion: @escaping (Bool) -> Void) {
        NSLog("[BeAroundSDK] BGTask: refreshing BLE scan for Service Data (trigger=%@)", trigger)

        // Ensure BLE is scanning
        if !bluetoothManager.isScanning {
            bluetoothManager.autoStartIfAuthorized()
            NSLog("[BeAroundSDK] BGTask: BLE scan started")
        } else {
            bluetoothManager.refreshScan()
            NSLog("[BeAroundSDK] BGTask: BLE scan refreshed")
        }

        // Wait for BLE to collect fresh Service Data from nearby beacons
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + bleScanDuration) { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            self.performBackgroundSync(trigger: trigger, completion: completion)
        }
    }

    /// Called by app's performFetchWithCompletionHandler
    public func performBackgroundFetch(completion: @escaping (Bool) -> Void) {
        NSLog("[BeAroundSDK] Background fetch triggered")

        if configuration == nil {
            if let savedConfig = SDKConfigStorage.load() {
                configuration = savedConfig
                apiClient = APIClient(configuration: savedConfig)
                setupSDKInfo(from: savedConfig)
                offlineBatchStorage.maxBatchCount = savedConfig.maxQueuedPayloads.value
                NSLog("[BeAroundSDK] Auto-configured during background fetch")
            } else {
                NSLog("[BeAroundSDK] Background fetch: no config")
                completion(false)
                return
            }
        }

        performBackgroundBLERefreshAndSync(bleScanDuration: 3.0, trigger: "background_fetch", completion: completion)
    }

    // MARK: - Private Helpers

    private func shouldRetryFailedBatches() -> Bool {
        guard offlineBatchStorage.batchCount > 0 else { return false }

        guard let lastFailure = lastFailureTime else {
            return true  // No recent failure, retry
        }

        let timeSinceFailure = Date().timeIntervalSince(lastFailure)
        let backoffDelay = min(5.0 * pow(2.0, Double(min(consecutiveFailures - 1, 3))), 60.0)

        return timeSinceFailure >= backoffDelay
    }

    private func beginBackgroundTask() {
        DispatchQueue.main.async { [weak self] in
            guard let self, backgroundTaskId == .invalid else { return }

            backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "BeAroundSDK-Sync") { [weak self] in
                NSLog("[BeAroundSDK] Background task expiring")
                self?.endBackgroundTask()
            }

            NSLog("[BeAroundSDK] Background task started: %lu", backgroundTaskId.rawValue)
        }
    }

    private func endBackgroundTask() {
        DispatchQueue.main.async { [weak self] in
            guard let self, backgroundTaskId != .invalid else { return }

            NSLog("[BeAroundSDK] Background task ended: %lu", backgroundTaskId.rawValue)
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
            backgroundTaskId = .invalid
        }
    }
}

// MARK: - BluetoothManagerDelegate

extension BeAroundSDK: BluetoothManagerDelegate {
    func didDiscoverBeacon(
        uuid _: UUID,
        major: Int,
        minor: Int,
        rssi: Int,
        txPower: Int,
        metadata: BeaconMetadata?,
        isConnectable: Bool,
        discoverySource: BeaconDiscoverySource
    ) {
        let key = "\(major).\(minor)"
        os_log("[SDK] didDiscoverBeacon key=%{public}@ rssi=%{public}d clScanning=%{public}d",
               log: sdkLog, type: .info, key, rssi, beaconManager.isScanning ? 1 : 0)

        // Always cache metadata
        if let metadata {
            metadataCache[key] = metadata
        }

        // Always add to collectedBeacons (skip if CL is already tracking)
        beaconQueue.async {
            if let existing = self.collectedBeacons[key],
               existing.discoverySources.contains(.coreLocation) {
                return // CL is already tracking, don't overwrite
            }

            var beacon = Beacon(
                uuid: UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!,
                major: major,
                minor: minor,
                rssi: rssi,
                proximity: .bt,
                accuracy: -1,
                metadata: metadata,
                txPower: txPower,
                discoverySources: [discoverySource]
            )
            if let existing = self.collectedBeacons[key] {
                beacon.syncedAt = existing.syncedAt
            }
            beacon.alreadySynced = false
            self.collectedBeacons[key] = beacon
        }
    }

    func didUpdateBluetoothState(isPoweredOn: Bool) {
        if !isPoweredOn {
            NSLog("[BeAroundSDK] Bluetooth powered off")
        }
    }
}
