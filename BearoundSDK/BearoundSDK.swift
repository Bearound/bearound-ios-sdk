//
//  BearoundSDK.swift
//  BearoundSDK
//  ios will relaunch the app when entering beacon region, 30 seconds +/-
//
//  Created by Bearound on 29/12/25.
//

import CoreLocation
import Foundation
import UIKit

public class BeAroundSDK {

    // MARK: - Singleton

    public static let shared = BeAroundSDK()

    // MARK: - Public Properties

    public weak var delegate: BeAroundSDKDelegate?

    public var isScanning: Bool {
        beaconManager.isScanning
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

        // For terminated app relaunch, BeaconManager already started ranging
        // Just configure the SDK - don't start scanning again (it's already running)
        // Don't start sync timer here - the background ranging timer will trigger sync when complete
        if !beaconManager.isScanning {
            beaconManager.startScanning()
            startSyncTimer()
        }

        NSLog("[BeAroundSDK] AUTO-CONFIGURED from storage (isScanning=%d)", beaconManager.isScanning ? 1 : 0)
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
                let metadata = self.metadataCache[key]

                return Beacon(
                    uuid: beacon.uuid,
                    major: beacon.major,
                    minor: beacon.minor,
                    rssi: beacon.rssi,
                    proximity: beacon.proximity,
                    accuracy: beacon.accuracy,
                    timestamp: beacon.timestamp,
                    metadata: metadata,
                    txPower: metadata?.txPower ?? beacon.txPower
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
            self.syncBeaconsImmediately()
        }

        // Triggered on first beacon detection in background
        beaconManager.onFirstBackgroundBeaconDetected = { [weak self] in
            guard let self else { return }
            let beaconCount = self.collectedBeacons.count
            NSLog("[BeAroundSDK] First background beacon - syncing NOW (beacons=%d)", beaconCount)

            // Notify delegate of background beacon detection
            DispatchQueue.main.async {
                self.delegate?.didDetectBeaconInBackground(beaconCount: max(beaconCount, 1))
            }

            self.syncBeaconsImmediately()
        }

        beaconManager.onSignificantLocationChange = { [weak self] in
            guard let self else { return }
            NSLog("[BeAroundSDK] Significant location change - syncing")
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
        foregroundScanInterval: ForegroundScanInterval = ForegroundScanInterval(seconds: ForegroundScanInterval.default),
        backgroundScanInterval: BackgroundScanInterval = BackgroundScanInterval(seconds: BackgroundScanInterval.default),
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

        beaconManager.startScanning()
        startSyncTimer()

        bluetoothManager.autoStartIfAuthorized()

        // Persist scanning state for terminated app relaunch
        SDKConfigStorage.saveIsScanning(true)

        // Schedule background tasks
        if #available(iOS 13.0, *) {
            BackgroundTaskManager.shared.scheduleSync()
        }

        // Start significant location monitoring for additional wake triggers
        beaconManager.startSignificantLocationMonitoring()
    }

    public func stopScanning() {
        beaconManager.stopScanning()
        beaconManager.stopSignificantLocationMonitoring()
        bluetoothManager.stopScanning()
        stopSyncTimer()

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

        if !isInBackground {
            if pauseDuration <= 0 {
                beaconManager.startRanging()
                
                timer.schedule(deadline: .now() + syncInterval, repeating: syncInterval)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
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
                beaconsToSend = failedBatch
                isRetry = true
                NSLog("[BeAroundSDK] Retrying failed batch with %d beacons", beaconsToSend.count)
            } else if !collectedBeacons.isEmpty {
                beaconsToSend = Array(collectedBeacons.values)
                collectedBeacons.removeAll()
                NSLog("[BeAroundSDK] Syncing %d collected beacons", beaconsToSend.count)
            } else {
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

            apiClient.sendBeacons(
                beaconsToSend,
                sdkInfo: sdkInfo,
                userDevice: userDevice,
                userProperties: userProperties
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
    public func performBackgroundSync(completion: @escaping (Bool) -> Void) {
        NSLog("[BeAroundSDK] Background task triggered")

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
                syncBeacons()
                completion(true)
            } else {
                NSLog("[BeAroundSDK] Background sync: nothing to sync")
                completion(false)
            }
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

        performBackgroundSync(completion: completion)
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
        rssi _: Int,
        txPower: Int,
        metadata: BeaconMetadata?,
        isConnectable: Bool
    ) {
        if let metadata {
            let key = "\(major).\(minor)"
            metadataCache[key] = metadata
        }
    }

    func didUpdateBluetoothState(isPoweredOn: Bool) {
        // Handled silently
    }
}
