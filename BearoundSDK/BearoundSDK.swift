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
import UIKit

public class BeAroundSDK {

    // MARK: - Singleton

    public static let shared = BeAroundSDK()

    public static var version: String {
        return "2.3.0"
    }

    // MARK: - Public Properties

    public weak var delegate: BeAroundSDKDelegate?

    public var isScanning: Bool {
        isBluetoothOnlyMode ? bluetoothManager.isScanning : beaconManager.isScanning
    }

    public var currentSyncInterval: TimeInterval? {
        guard let config = configuration else { return nil }
        return config.syncInterval(isInBackground: isInBackground)
    }

    public var currentScanDuration: TimeInterval? {
        guard let config = configuration else { return nil }
        let interval = config.syncInterval(isInBackground: isInBackground)
        return config.scanDuration(for: interval)
    }

    public var pendingBatchCount: Int {
        offlineBatchStorage.batchCount
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
    private var collectedBeacons: [String: Beacon] = [:]
    private let beaconQueue = DispatchQueue(label: "com.bearound.sdk.beaconQueue")
    private var isSyncing = false

    private let offlineBatchStorage = OfflineBatchStorage()

    private var consecutiveFailures = 0
    private var lastFailureTime: Date?
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    private var isInBackground = false
    private var wasLaunchedInBackground = false
    private var isBluetoothOnlyMode = false
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

        // Check if Location is authorized to decide which scanning mode to use
        let locationStatus = Self.authorizationStatus()
        let locationAuthorized = (locationStatus == .authorizedWhenInUse || locationStatus == .authorizedAlways)

        if locationAuthorized {
            // For terminated app relaunch via Location, BeaconManager already started ranging
            // Just configure the SDK - don't start scanning again (it's already running)
            isBluetoothOnlyMode = false
            if !beaconManager.isScanning {
                beaconManager.startScanning()
                startSyncTimer()
            }
            // Also start BLE for metadata enrichment
            bluetoothManager.autoStartIfAuthorized()
            NSLog("[BeAroundSDK] AUTO-CONFIGURED from storage (Location mode, isScanning=%d)", beaconManager.isScanning ? 1 : 0)
        } else {
            // For terminated app relaunch via Bluetooth state restoration
            // Start in bluetooth-only mode
            isBluetoothOnlyMode = true
            bluetoothManager.autoStartIfAuthorized()
            startSyncTimer()
            delegate?.didChangeScanning(isScanning: true)
            NSLog("[BeAroundSDK] AUTO-CONFIGURED from storage (Bluetooth-only mode)")
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
                for beacon in enrichedBeacons {
                    let key = "\(beacon.major).\(beacon.minor)"
                    self.collectedBeacons[key] = beacon
                }
            }

            delegate?.didUpdateBeacons(enrichedBeacons)
        }

        beaconManager.onError = { [weak self] error in
            self?.delegate?.didFailWithError(error)
        }

        beaconManager.onScanningStateChanged = { [weak self] isScanning in
            self?.delegate?.didChangeScanning(isScanning: isScanning)
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
            guard let self, self.isBluetoothOnlyMode else { return }

            beaconQueue.async {
                // Build current set of tracked beacon keys
                let trackedKeys = Set(trackedBeacons.map { "\($0.major).\($0.minor)" })

                // Remove beacons that are no longer tracked (expired by grace period)
                for key in self.collectedBeacons.keys where !trackedKeys.contains(key) {
                    self.collectedBeacons.removeValue(forKey: key)
                }
            }

            let beacons = trackedBeacons.map { tracked in
                Beacon(
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
            }

            DispatchQueue.main.async {
                self.delegate?.didUpdateBeacons(beacons)
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

        if isScanning || isBluetoothOnlyMode {
            startSyncTimer()
        }
    }

    @objc private func appWillEnterForeground() {
        isInBackground = false

        if isScanning || isBluetoothOnlyMode {
            startSyncTimer()
        }
    }

    // MARK: - Public API

    public func configure(
        businessToken: String,
        foregroundScanInterval: ForegroundScanInterval = .seconds15,
        backgroundScanInterval: BackgroundScanInterval = .seconds60,
        maxQueuedPayloads: MaxQueuedPayloads = .medium
    ) {
        let config = SDKConfiguration(
            businessToken: businessToken,
            foregroundScanInterval: foregroundScanInterval,
            backgroundScanInterval: backgroundScanInterval,
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

        let actualAppState = UIApplication.shared.applicationState
        isInBackground = (actualAppState == .background)

        // Check if Location is authorized
        let locationStatus = Self.authorizationStatus()
        let locationAuthorized = (locationStatus == .authorizedWhenInUse || locationStatus == .authorizedAlways)

        if locationAuthorized {
            // Normal flow: Location + Bluetooth for metadata
            isBluetoothOnlyMode = false
            beaconManager.startScanning()
            startSyncTimer()
            bluetoothManager.autoStartIfAuthorized()

            // Start significant location monitoring for additional wake triggers
            beaconManager.startSignificantLocationMonitoring()
        } else {
            // Fallback: Bluetooth-only mode
            isBluetoothOnlyMode = true

            // Check if Bluetooth is available
            if #available(iOS 13.1, *) {
                let btAuth = CBCentralManager.authorization
                if btAuth == .denied || btAuth == .restricted {
                    let error = NSError(
                        domain: "BeAroundSDK",
                        code: 7,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Both Location and Bluetooth permissions are denied. Cannot scan for beacons."
                        ]
                    )
                    delegate?.didFailWithError(error)
                    return
                }
            }

            bluetoothManager.autoStartIfAuthorized()
            startSyncTimer()
            delegate?.didChangeScanning(isScanning: true)

            NSLog("[BeAroundSDK] Started in BLUETOOTH-ONLY mode (Location not authorized)")
        }

        // Persist scanning state for terminated app relaunch
        SDKConfigStorage.saveIsScanning(true)

        // Schedule background tasks (BGTaskScheduler)
        if #available(iOS 13.0, *) {
            BackgroundTaskManager.shared.scheduleSync()
            BackgroundTaskManager.shared.scheduleProcessingTask()
        }
    }

    public func stopScanning() {
        if isBluetoothOnlyMode {
            bluetoothManager.stopScanning()
            isBluetoothOnlyMode = false
            delegate?.didChangeScanning(isScanning: false)
        } else {
            beaconManager.stopScanning()
            beaconManager.stopSignificantLocationMonitoring()
            bluetoothManager.stopScanning()
        }

        stopSyncTimer()
        syncTrigger = "stop_scanning"
        syncBeaconsImmediately()

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

        let syncInterval = config.syncInterval(isInBackground: isInBackground)
        let scanDuration = config.scanDuration(for: syncInterval)
        let pauseDuration = syncInterval - scanDuration

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        syncTimer = timer

        // Bluetooth-only mode: continuous BLE scanning, just sync periodically
        if isBluetoothOnlyMode {
            timer.schedule(deadline: .now() + syncInterval, repeating: syncInterval)
            timer.setEventHandler { [weak self] in
                self?.syncTrigger = "bluetooth_timer"
                self?.syncBeacons()
            }
            timer.resume()
            return
        }

        if !isInBackground {
            if pauseDuration <= 0 {
                beaconManager.startRanging()

                timer.schedule(deadline: .now() + syncInterval, repeating: syncInterval)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.syncTrigger = "foreground_timer"
                    self.syncBeacons()
                }
                timer.resume()
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + pauseDuration) { [weak self] in
                guard let self, self.beaconManager.isScanning else { return }
                self.beaconManager.startRanging()

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + scanDuration) { [weak self] in
                    guard let self, self.beaconManager.isScanning else { return }
                    self.beaconManager.stopRanging()
                }
            }

            timer.schedule(deadline: .now() + syncInterval, repeating: syncInterval)
            timer.setEventHandler { [weak self] in
                guard let self, self.beaconManager.isScanning else { return }

                self.syncTrigger = "foreground_timer"
                self.syncBeacons()

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + pauseDuration) { [weak self] in
                    guard let self, self.beaconManager.isScanning else { return }
                    self.beaconManager.startRanging()

                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + scanDuration) { [weak self] in
                        guard let self, self.beaconManager.isScanning else { return }
                        self.beaconManager.stopRanging()
                    }
                }
            }
            timer.resume()
        } else {
            // BACKGROUND MODE: Implement proper scan/pause pattern
            // The 1/3 rule: scan for scanDuration, pause for pauseDuration

            if pauseDuration <= 0 {
                // No pause needed - continuous scanning
                if beaconManager.isScanning {
                    beaconManager.startRanging()
                }

                timer.schedule(deadline: .now() + syncInterval, repeating: syncInterval)
                timer.setEventHandler { [weak self] in
                    self?.syncTrigger = "background_timer"
                    self?.syncBeacons()
                }
                timer.resume()
            } else {
                // Start with pause, then scan at the end of each interval
                NSLog("[BeAroundSDK] Background scan pattern: pause=%.0fs, scan=%.0fs, interval=%.0fs",
                      pauseDuration, scanDuration, syncInterval)

                // Schedule scan to start after pause duration (scan at END of interval)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + pauseDuration) { [weak self] in
                    guard let self, self.beaconManager.isScanning else { return }
                    self.beaconManager.resumeRanging()
                }

                timer.schedule(deadline: .now() + syncInterval, repeating: syncInterval)
                timer.setEventHandler { [weak self] in
                    guard let self, self.beaconManager.isScanning else { return }

                    // Sync the beacons we just collected
                    self.syncTrigger = "background_timer"
                    self.syncBeacons()

                    // Pause ranging during the pause period
                    self.beaconManager.pauseRanging()

                    // Resume ranging after pause duration (to collect beacons before next sync)
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + pauseDuration) { [weak self] in
                        guard let self, self.beaconManager.isScanning else { return }
                        self.beaconManager.resumeRanging()
                    }
                }
                timer.resume()
            }
        }
    }

    private func stopSyncTimer() {
        syncTimer?.cancel()
        syncTimer = nil
    }

    // MARK: - Beacon Cleanup & Merge

    /// Remove beacons that haven't been updated recently
    /// Uses 2x the current sync interval as the grace period
    private func cleanupStaleBeacons() {
        let maxAge: TimeInterval
        if let config = configuration {
            maxAge = config.syncInterval(isInBackground: isInBackground) * 2
        } else {
            maxAge = 60.0
        }

        let now = Date()
        var removedCount = 0

        for (key, beacon) in collectedBeacons {
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
            if let existing = collectedBeacons[key] {
                // Enrich existing beacon with BLE Service Data if not already present
                if !existing.discoverySources.contains(.serviceUUID) {
                    var sources = existing.discoverySources
                    sources.insert(.serviceUUID)
                    collectedBeacons[key] = Beacon(
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
                }
            } else {
                // BLE-only beacon — add to collected
                collectedBeacons[key] = Beacon(
                    uuid: targetUUID,
                    major: tracked.major,
                    minor: tracked.minor,
                    rssi: tracked.rssi,
                    proximity: .bt,
                    accuracy: -1,
                    metadata: tracked.metadata,
                    txPower: tracked.txPower,
                    discoverySources: [tracked.discoverySource]
                )
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

            let shouldRetryFailed = shouldRetryFailedBatches()

            var beaconsToSend: [Beacon] = []
            var isRetry = false

            if shouldRetryFailed, let failedBatch = offlineBatchStorage.loadOldestBatch() {
                beaconsToSend = failedBatch.filter { $0.rssi != 0 }
                isRetry = true
                NSLog("[BeAroundSDK] Retrying failed batch with %d beacons", beaconsToSend.count)
            } else {
                // Clean up stale beacons and merge BLE Service Data
                self.cleanupStaleBeacons()
                self.mergeBLEBeacons()

                if !collectedBeacons.isEmpty {
                    // Filter out beacons with invalid RSSI (rssi: 0 = unknown)
                    beaconsToSend = Array(collectedBeacons.values).filter { $0.rssi != 0 }
                    NSLog("[BeAroundSDK] Syncing %d beacons (after cleanup/merge/filter)", beaconsToSend.count)
                }
            }

            guard !beaconsToSend.isEmpty else {
                NSLog("[BeAroundSDK] Nothing to sync")
                self.endBackgroundTask()
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

                beaconQueue.async {
                    self.isSyncing = false
                }

                switch result {
                case .success:
                    NSLog("[BeAroundSDK] Sync SUCCESS")
                    self.endBackgroundTask()

                    // Notify delegate of successful sync
                    DispatchQueue.main.async {
                        self.delegate?.didCompleteSync(beaconCount: beaconCount, success: true, error: nil)
                    }

                    beaconQueue.async {
                        self.consecutiveFailures = 0
                        self.lastFailureTime = nil

                        if isRetry {
                            self.offlineBatchStorage.removeOldestBatch()
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
                        self.consecutiveFailures += 1
                        self.lastFailureTime = Date()

                        // Save to persistent storage for retry
                        if !isRetry {
                            self.offlineBatchStorage.saveBatch(beaconsToSend)
                            NSLog("[BeAroundSDK] Saved failed batch to persistent storage")
                        }

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

        if let metadata {
            metadataCache[key] = metadata
        }

        if isBluetoothOnlyMode {
            let beacon = Beacon(
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

            beaconQueue.async {
                self.collectedBeacons[key] = beacon
            }
        }
    }

    func didUpdateBluetoothState(isPoweredOn: Bool) {
        if isBluetoothOnlyMode && !isPoweredOn {
            NSLog("[BeAroundSDK] Bluetooth powered off in bluetooth-only mode")
        }
    }
}
