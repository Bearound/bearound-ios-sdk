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

    private var isTemporaryRanging = false

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
        wasLaunchedInBackground = UIApplication.shared.applicationState != .active
        if wasLaunchedInBackground {
            isInBackground = true
            print("[BeAroundSDK] App launched in background (likely by beacon monitoring)")
        }

        setupCallbacks()
        setupAppStateObservers()
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
            print("[BeAroundSDK] Background ranging complete - syncing collected beacons")
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
        print("[BeAroundSDK] App entered background - switching to continuous ranging mode")

        if let config = configuration, config.enablePeriodicScanning {
            beaconManager.enablePeriodicScanning = false
            if isScanning, !beaconManager.isScanning {
                beaconManager.startRanging()
            }
        }
    }

    @objc private func appWillEnterForeground() {
        isInBackground = false
        print("[BeAroundSDK] App entered foreground - restoring periodic mode if configured")

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

        if isScanning {
            startSyncTimer()
        }
    }

    public func setUserProperties(_ properties: UserProperties) {
        userProperties = properties
        print(
            "[BeAroundSDK] User properties updated: internalId=\(properties.internalId ?? "nil"), email=\(properties.email ?? "nil"), name=\(properties.name ?? "nil"), custom=\(properties.customProperties.count) properties"
        )
    }

    public func clearUserProperties() {
        userProperties = nil
        print("[BeAroundSDK] User properties cleared")
    }

    public func setBluetoothScanning(enabled: Bool) {
        configuration?.enableBluetoothScanning = enabled

        if enabled, isScanning {
            bluetoothManager.startScanning()
        } else if !enabled {
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
    }

    public func stopScanning() {
        beaconManager.stopScanning()
        bluetoothManager.stopScanning()
        stopSyncTimer()
        stopCountdownTimer()

        syncBeacons()
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
                print("BeAroundSDK: Synced beacons to API")

                self.nextSyncTime = Date().addingTimeInterval(syncInterval)

                let delayUntilNextRanging = syncInterval - scanDuration
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + delayUntilNextRanging
                ) { [weak self] in
                    guard let self else { return }
                    guard self.beaconManager.isScanning else { return }
                    print(
                        "BeAroundSDK: Starting ranging \(String(format: "%.1f", scanDuration))s before next sync"
                    )
                    self.beaconManager.startRanging()
                }
            }

            let delayUntilFirstRanging = syncInterval - scanDuration
            nextSyncTime = Date().addingTimeInterval(syncInterval)

            print(
                "BeAroundSDK: First ranging will start in \(String(format: "%.1f", delayUntilFirstRanging))s (sync in \(String(format: "%.1f", syncInterval))s)"
            )
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + delayUntilFirstRanging
            ) { [weak self] in
                guard let self else { return }
                guard self.beaconManager.isScanning else { return }
                print(
                    "BeAroundSDK: Starting initial ranging for \(String(format: "%.1f", scanDuration))s"
                )
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
                print("BeAroundSDK: Skipping sync - previous sync still in progress")
                self.endBackgroundTask()
                return
            }

            guard let apiClient,
                let sdkInfo
            else {
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
                print(
                    "BeAroundSDK: Retrying failed batch with \(beaconsToSend.count) beacon\(beaconsToSend.count == 1 ? "" : "s") (attempt after \(consecutiveFailures) failures)"
                )
            } else if !collectedBeacons.isEmpty {
                beaconsToSend = Array(collectedBeacons.values)
                collectedBeacons.removeAll()
            } else {
                return
            }

            isSyncing = true
            let count = beaconsToSend.count

            if !isRetry {
                print(
                    "BeAroundSDK: Sending \(count) beacon\(count == 1 ? "" : "s") to \(configuration?.apiBaseURL ?? "unknown")/ingest"
                )
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
                    print(
                        "BeAroundSDK: Successfully sent \(count) beacon\(count == 1 ? "" : "s") (HTTP 200)"
                    )
                    self.endBackgroundTask()

                    beaconQueue.async {
                        self.consecutiveFailures = 0
                        self.lastFailureTime = nil

                        if !self.failedBatches.isEmpty {
                            print(
                                "BeAroundSDK: Recovered from failures - \(self.failedBatches.count) batch\(self.failedBatches.count == 1 ? "" : "es") still queued for retry"
                            )
                        }
                    }

                case .failure(let error):
                    print("BeAroundSDK: Failed to send beacons - \(error.localizedDescription)")
                    self.endBackgroundTask()

                    beaconQueue.async {
                        self.consecutiveFailures += 1
                        self.lastFailureTime = Date()

                        let maxQueueSize = self.configuration?.maxQueuedPayloads.value ?? 100
                        
                        if self.failedBatches.count < maxQueueSize {
                            self.failedBatches.append(beaconsToSend)
                            print(
                                "BeAroundSDK: Queued \(count) beacon\(count == 1 ? "" : "s") for retry (queue size: \(self.failedBatches.count)/\(maxQueueSize), consecutive failures: \(self.consecutiveFailures))"
                            )
                        } else {
                            let dropped = self.failedBatches.removeFirst()
                            self.failedBatches.append(beaconsToSend)
                            print(
                                "BeAroundSDK: Retry queue full - dropped \(dropped.count) oldest beacons (queue: \(self.failedBatches.count)/\(maxQueueSize))"
                            )
                        }

                        if self.consecutiveFailures >= 10 {
                            print(
                                "BeAroundSDK: Circuit breaker triggered - \(self.consecutiveFailures) consecutive failures. API may be down."
                            )

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
                print("[BeAroundSDK] Background task expiring - cleaning up")
                self?.endBackgroundTask()
            }

            if backgroundTaskId != .invalid {
                print("[BeAroundSDK] Background task started (id: \(backgroundTaskId.rawValue))")
            }
        }
    }

    private func endBackgroundTask() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if backgroundTaskId != .invalid {
                print("[BeAroundSDK] Background task ended (id: \(backgroundTaskId.rawValue))")
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
            print(
                "[BeAroundSDK] Cached metadata for beacon \(major).\(minor): battery=\(metadata.batteryLevel)%, firmware=\(metadata.firmwareVersion), txPower=\(metadata.txPower ?? 0)dBm, rssi=\(metadata.rssiFromBLE ?? 0)dBm, connectable=\(isConnectable)"
            )
        }
    }

    func didUpdateBluetoothState(isPoweredOn: Bool) {
        if !isPoweredOn, configuration?.enableBluetoothScanning == true {
            print("[BeAroundSDK] Bluetooth is off - metadata scanning unavailable")
        }
    }
}
