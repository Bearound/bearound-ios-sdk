//
//  BearoundSDK.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import CoreLocation
import Foundation
import UIKit

public class BeAroundSDK {
    public static let shared = BeAroundSDK()

    public weak var delegate: BeAroundSDKDelegate?

    private var configuration: SDKConfiguration?

    private var sdkInfo: SDKInfo?

    private var userProperties: UserProperties?

    private let deviceInfoCollector = DeviceInfoCollector(isColdStart: true)

    private let beaconManager = BeaconManager()

    private let bluetoothManager = BluetoothManager()

    private var apiClient: APIClient?

    private var metadataCache: [String: BeaconMetadata] = [:]

    private var syncTimer: DispatchSourceTimer?
    private var countdownTimer: DispatchSourceTimer?
    private var nextSyncTime: Date?

    private var collectedBeacons: [String: Beacon] = [:]

    private let beaconQueue = DispatchQueue(label: "com.bearound.sdk.beaconQueue")

    private var isSyncing = false

    private var failedBatches: [[Beacon]] = []

    private var consecutiveFailures = 0

    private var lastFailureTime: Date?

    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

    private var isInBackground = false

    private var wasLaunchedInBackground = false

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

    public var isPeriodicScanningEnabled: Bool {
        configuration?.enablePeriodicScanning ?? false
    }

    private init() {
        let appState = UIApplication.shared.applicationState
        wasLaunchedInBackground = appState != .active
        
        if wasLaunchedInBackground {
            isInBackground = true
            // Use NSLog for background launches (print() doesn't work in background)
            NSLog("[BeAroundSDK] App launched in background (appState=%ld)", appState.rawValue)
        }

        setupCallbacks()
        setupAppStateObservers()
        
        // Auto-configure from saved settings if app was launched in background
        if wasLaunchedInBackground {
            autoConfigureFromStorage()
        }
    }
    
    /// Auto-configures the SDK from saved settings (used when app is relaunched in background)
    private func autoConfigureFromStorage() {
        guard configuration == nil else {
            NSLog("[BeAroundSDK] SDK already configured, skipping auto-configure")
            return
        }
        
        guard let savedConfig = SDKConfigStorage.load() else {
            NSLog("[BeAroundSDK] No saved configuration found for auto-configure")
            return
        }
        
        // Respect user's intention - only auto-start if scanning was active
        guard SDKConfigStorage.loadIsScanning() else {
            NSLog("[BeAroundSDK] User had scanning disabled, not auto-starting")
            // Still configure the SDK so it's ready if needed
            configuration = savedConfig
            apiClient = APIClient(configuration: savedConfig)
            let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
            let build = Int(buildNumber) ?? 1
            sdkInfo = SDKInfo(appId: savedConfig.appId, build: build)
            return
        }
        
        configuration = savedConfig
        apiClient = APIClient(configuration: savedConfig)
        
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let build = Int(buildNumber) ?? 1
        sdkInfo = SDKInfo(appId: savedConfig.appId, build: build)
        
        // In background mode, disable periodic scanning to use continuous ranging
        beaconManager.enablePeriodicScanning = false
        
        // CRITICAL: Auto-start scanning when relaunched in background
        // This ensures Region Monitoring is active
        beaconManager.startScanning()
        
        NSLog("[BeAroundSDK] Auto-configured and started scanning from storage")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stopSyncTimer()
        stopCountdownTimer()
        endBackgroundTask()
    }

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

        beaconManager.onBackgroundRangingComplete = { [weak self] in
            guard let self else { return }
            self.syncBeacons()
        }
        
        beaconManager.onFirstBackgroundBeaconDetected = { [weak self] in
            guard let self else { return }
            NSLog("[BeAroundSDK] First background beacon detected - syncing immediately (collectedBeacons=%d)", self.collectedBeacons.count)
            self.syncBeacons()
        }
        
        beaconManager.onSignificantLocationChange = { [weak self] in
            guard let self else { return }
            NSLog("[BeAroundSDK] Significant location change detected - syncing")
            self.syncBeacons()
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

        if let config = configuration, config.enablePeriodicScanning {
            beaconManager.enablePeriodicScanning = false
            if isScanning, !beaconManager.isScanning {
                beaconManager.startRanging()
            }
        }
        
        // Restart sync timer with background interval
        if isScanning {
            startSyncTimer()
        }
    }

    @objc private func appWillEnterForeground() {
        isInBackground = false

        if let config = configuration {
            beaconManager.enablePeriodicScanning = config.enablePeriodicScanning

            if isScanning {
                startSyncTimer()
            }
        }
    }

    public func configure(
        businessToken: String,
        foregroundScanInterval: ForegroundScanInterval = .seconds15,
        backgroundScanInterval: BackgroundScanInterval = .seconds60,
        maxQueuedPayloads: MaxQueuedPayloads = .medium,
        enableBluetoothScanning: Bool = false,
        enablePeriodicScanning: Bool = true
    ) {
        let config = SDKConfiguration(
            businessToken: businessToken,
            foregroundScanInterval: foregroundScanInterval,
            backgroundScanInterval: backgroundScanInterval,
            maxQueuedPayloads: maxQueuedPayloads,
            enableBluetoothScanning: enableBluetoothScanning,
            enablePeriodicScanning: enablePeriodicScanning
        )
        configuration = config
        apiClient = APIClient(configuration: config)

        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let build = Int(buildNumber) ?? 1

        sdkInfo = SDKInfo(appId: config.appId, build: build)
        
        // Save configuration for background relaunch
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

    public func setBluetoothScanning(enabled: Bool) {
        configuration?.enableBluetoothScanning = enabled

        if enabled, isScanning {
            bluetoothManager.startScanning()
        } else {
            bluetoothManager.stopScanning()
            metadataCache.removeAll()
        }
    }

    public var isBluetoothScanningEnabled: Bool {
        configuration?.enableBluetoothScanning ?? false
    }

    public func startScanning() {
        guard let config = configuration else {
            let error = NSError(
                domain: "BeAroundSDK",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "SDK not configured. Call configure(businessToken:syncInterval:) first."
                ]
            )
            delegate?.didFailWithError(error)
            return
        }

        // Sync state with actual app state before starting
        let actualAppState = UIApplication.shared.applicationState
        isInBackground = (actualAppState == .background)

        beaconManager.enablePeriodicScanning = config.enablePeriodicScanning

        beaconManager.startScanning()
        startSyncTimer()

        if config.enableBluetoothScanning {
            bluetoothManager.startScanning()
        }
        
        // Persist scanning state for background relaunch
        SDKConfigStorage.saveIsScanning(true)
        
        // Schedule background sync task
        if #available(iOS 13.0, *) {
            BackgroundTaskManager.shared.scheduleSync()
        }
        
        // Start significant location monitoring for additional background wake triggers
        beaconManager.startSignificantLocationMonitoring()
    }

    public func stopScanning() {
        beaconManager.stopScanning()
        beaconManager.stopSignificantLocationMonitoring()
        bluetoothManager.stopScanning()
        stopSyncTimer()
        stopCountdownTimer()

        syncBeacons()
        
        // Persist scanning state
        SDKConfigStorage.saveIsScanning(false)
        
        // Cancel pending background tasks
        if #available(iOS 13.0, *) {
            BackgroundTaskManager.shared.cancelPendingTasks()
        }
    }

    public static func isLocationAvailable() -> Bool {
        CLLocationManager.locationServicesEnabled()
    }

    public static func authorizationStatus() -> CLAuthorizationStatus {
        if #available(iOS 14.0, *) {
            CLLocationManager().authorizationStatus
        } else {
            CLLocationManager.authorizationStatus()
        }
    }

    private func startSyncTimer() {
        guard let config = configuration else { return }

        stopSyncTimer()
        startCountdownTimer()

        // Sync isInBackground with actual app state
        let actualAppState = UIApplication.shared.applicationState
        isInBackground = (actualAppState == .background)

        let syncInterval = config.syncInterval(isInBackground: isInBackground)
        let scanDuration = config.scanDuration(for: syncInterval)

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        syncTimer = timer

        if config.enablePeriodicScanning && !isInBackground {
            timer.schedule(deadline: .now() + syncInterval, repeating: syncInterval)
            timer.setEventHandler { [weak self] in
                guard let self else { return }

                self.beaconManager.stopRanging()
                self.syncBeacons()

                self.nextSyncTime = Date().addingTimeInterval(syncInterval)

                let delayUntilNextRanging = syncInterval - scanDuration
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + delayUntilNextRanging
                ) { [weak self] in
                    guard let self else { return }
                    guard self.beaconManager.isScanning else { return }
                    self.beaconManager.startRanging()
                }
            }

            let delayUntilFirstRanging = syncInterval - scanDuration
            nextSyncTime = Date().addingTimeInterval(syncInterval)

            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + delayUntilFirstRanging
            ) { [weak self] in
                guard let self else { return }
                guard self.beaconManager.isScanning else { return }
                self.beaconManager.startRanging()
            }

            timer.resume()
        } else {
            timer.schedule(deadline: .now() + syncInterval, repeating: syncInterval)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.nextSyncTime = Date().addingTimeInterval(syncInterval)
                self.syncBeacons()
            }

            nextSyncTime = Date().addingTimeInterval(syncInterval)
            timer.resume()
        }
    }

    private func stopSyncTimer() {
        syncTimer?.cancel()
        syncTimer = nil
    }

    private func startCountdownTimer() {
        stopCountdownTimer()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.updateCountdown()
        }
        countdownTimer = timer
        timer.resume()
    }

    private func stopCountdownTimer() {
        countdownTimer?.cancel()
        countdownTimer = nil
        nextSyncTime = nil
    }

    private func updateCountdown() {
        guard let nextSync = nextSyncTime else {
            delegate?.didUpdateSyncStatus(
                secondsUntilNextSync: 0, isRanging: beaconManager.isScanning)
            return
        }

        let secondsRemaining = max(0, Int(nextSync.timeIntervalSinceNow))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.didUpdateSyncStatus(
                secondsUntilNextSync: secondsRemaining,
                isRanging: self.beaconManager.isScanning
            )
        }
    }

    private func syncBeacons() {
        beaconQueue.async { [weak self] in
            guard let self else { return }

            self.beginBackgroundTask()

            guard !isSyncing else {
                self.endBackgroundTask()
                return
            }

            guard let apiClient,
                let sdkInfo
            else {
                NSLog("[BeAroundSDK] Sync skipped - SDK not configured (apiClient: %d, sdkInfo: %d)", self.apiClient != nil ? 1 : 0, self.sdkInfo != nil ? 1 : 0)
                self.endBackgroundTask()
                return
            }

            let shouldRetryFailed = shouldRetryFailedBatches()

            var beaconsToSend: [Beacon] = []
            var isRetry = false

            if shouldRetryFailed, let failedBatch = failedBatches.first {
                beaconsToSend = failedBatch
                isRetry = true
                failedBatches.removeFirst()
            } else if !collectedBeacons.isEmpty {
                beaconsToSend = Array(collectedBeacons.values)
                collectedBeacons.removeAll()
            } else {
                NSLog("[BeAroundSDK] Sync skipped - no beacons collected")
                self.endBackgroundTask()
                return
            }

            isSyncing = true
            let count = beaconsToSend.count

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
                    self.endBackgroundTask()

                    beaconQueue.async {
                        self.consecutiveFailures = 0
                        self.lastFailureTime = nil
                    }

                case .failure(let error):
                    self.endBackgroundTask()

                    beaconQueue.async {
                        self.consecutiveFailures += 1
                        self.lastFailureTime = Date()

                        let maxQueueSize = self.configuration?.maxQueuedPayloads.value ?? 100
                        
                        if self.failedBatches.count < maxQueueSize {
                            self.failedBatches.append(beaconsToSend)
                        } else {
                            let dropped = self.failedBatches.removeFirst()
                            self.failedBatches.append(beaconsToSend)
                        }

                        if self.consecutiveFailures >= 10 {

                            let circuitBreakerError = NSError(
                                domain: "BeAroundSDK",
                                code: 6,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "API unreachable after \(self.consecutiveFailures) consecutive failures. Beacons are queued for retry."
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
    
    /// Called by BackgroundTaskManager when BGTaskScheduler triggers a sync
    /// This method is internal and should not be called directly by app developers
    func performBackgroundSync(completion: @escaping (Bool) -> Void) {
        NSLog("[BeAroundSDK] performBackgroundSync called")
        
        beaconQueue.async { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            
            // Check if we have anything to sync
            let hasBeacons = !collectedBeacons.isEmpty
            let hasFailedBatches = !failedBatches.isEmpty
            
            if hasBeacons || hasFailedBatches {
                NSLog("[BeAroundSDK] Background sync: has beacons=%d, has failed batches=%d", hasBeacons ? 1 : 0, hasFailedBatches ? 1 : 0)
                syncBeacons()
                completion(true)
            } else {
                NSLog("[BeAroundSDK] Background sync: nothing to sync")
                completion(false)
            }
        }
    }
    
    /// Called by app when iOS triggers a background fetch
    /// App should implement application(_:performFetchWithCompletionHandler:) and call this method
    ///
    /// Example:
    /// ```swift
    /// func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    ///     BeAroundSDK.shared.performBackgroundFetch { success in
    ///         completionHandler(success ? .newData : .noData)
    ///     }
    /// }
    /// ```
    public func performBackgroundFetch(completion: @escaping (Bool) -> Void) {
        NSLog("[BeAroundSDK] Background fetch triggered")
        
        // Auto-configure if needed
        if configuration == nil {
            if let savedConfig = SDKConfigStorage.load() {
                configuration = savedConfig
                apiClient = APIClient(configuration: savedConfig)
                let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
                let build = Int(buildNumber) ?? 1
                sdkInfo = SDKInfo(appId: savedConfig.appId, build: build)
                NSLog("[BeAroundSDK] Auto-configured from storage during background fetch")
            } else {
                NSLog("[BeAroundSDK] Background fetch: no configuration available")
                completion(false)
                return
            }
        }
        
        performBackgroundSync(completion: completion)
    }
    
    // MARK: - Private Methods

    private func shouldRetryFailedBatches() -> Bool {
        guard !failedBatches.isEmpty,
            let lastFailure = lastFailureTime
        else {
            return false
        }

        let timeSinceFailure = Date().timeIntervalSince(lastFailure)

        let backoffDelay = min(5.0 * pow(2.0, Double(min(consecutiveFailures - 1, 3))), 60.0)

        return timeSinceFailure >= backoffDelay
    }

    private func beginBackgroundTask() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if backgroundTaskId != .invalid {
                return
            }

            backgroundTaskId = UIApplication.shared.beginBackgroundTask(
                withName: "BeAroundSDK-Sync"
            ) { [weak self] in
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if backgroundTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskId)
                backgroundTaskId = .invalid
            }
        }
    }
}

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
        guard configuration?.enableBluetoothScanning == true else { return }

        if let metadata {
            let key = "\(major).\(minor)"
            metadataCache[key] = metadata
        }
    }

    func didUpdateBluetoothState(isPoweredOn: Bool) {
        // Bluetooth state change handled silently
    }
}
