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

/// Level of Location authorization to request when opting into the **Location eye**.
///
/// The SDK runs in **Bluetooth-only** by default — no Location permission required,
/// no `Info.plist` `NSLocation*UsageDescription` keys needed. Beacons are detected in
/// foreground, background, and after iOS-initiated termination (state restoration).
///
/// Opt into the Location eye if you need the SDK to **survive a user force-quit**
/// (swipe-up in the app switcher). The Location eye uses kernel-level region
/// monitoring that iOS preserves across force-quit. Requires `.always`.
public enum BeAroundLocationAuthorization: String {
    /// Allows ranging while the app is in foreground only. Insufficient for terminated-app
    /// wake-up; provided for apps that only need foreground beacon proximity data.
    case whenInUse
    /// Required for region-monitoring wake-up of a terminated/force-quit app.
    /// Host app must declare `NSLocationAlwaysAndWhenInUseUsageDescription` in Info.plist.
    case always
}

public class BeAroundSDK {

    // MARK: - Singleton

    public static let shared = BeAroundSDK()

    public static var version: String {
        return "3.0.0"
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

    /// A read-only snapshot of the SDK's identity, state, and recent runtime activity.
    /// Safe to call anytime — reads in-memory counters and stored identifiers, no network.
    /// Use `.summary()` on the result for a log-friendly multi-line string.
    public func diagnostics() -> BeAroundDiagnostics {
        let store = DiagnosticsStore.shared
        return BeAroundDiagnostics(
            deviceId: DeviceIdentifier.getDeviceId(),
            deviceIdType: DeviceIdentifier.getDeviceIdType(),
            pushTokenMasked: PushTokenStore.maskedToken,
            pushTokenLastSentAt: PushTokenStore.lastSentAt,
            apnsEnvironment: APNSEnvironment.current(),
            isScanning: isScanning,
            pendingBatches: pendingBatchCount,
            lastScanAt: store.lastScanAt,
            lastScanBeaconCount: store.lastScanBeaconCount,
            lastSyncAt: store.lastSyncAt,
            lastSyncSuccess: store.lastSyncSuccess,
            lastSyncBeaconCount: store.lastSyncBeaconCount,
            lastPushReceivedAt: store.lastPushReceivedAt,
            recentErrors: store.recentErrors,
            sdkVersion: BeAroundSDK.version
        )
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

    /// Timestamp of the last debounced immediate sync (Fix 2/6). Guards edge-triggered syncs
    /// (e.g. a flapping Bluetooth zone) from spamming the ingester.
    private var lastDebouncedSyncTime: Date?
    private let debouncedSyncQueue = DispatchQueue(label: "com.bearound.sdk.debouncedSync")

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
            // Fix 1 — re-instantiate the background session with the same identifier so any
            // pending background-upload delegate callbacks from before termination are delivered.
            apiClient?.ensureBackgroundSessionAlive()
            return
        }

        configuration = savedConfig
        apiClient = APIClient(configuration: savedConfig)
        setupSDKInfo(from: savedConfig)

        // Fix 1 — re-instantiate the background session with the same identifier so any pending
        // background-upload delegate callbacks from before termination are delivered.
        apiClient?.ensureBackgroundSessionAlive()

        offlineBatchStorage.maxBatchCount = savedConfig.maxQueuedPayloads.value

        // Check authorizations independently
        let locationStatus = Self.authorizationStatus()
        let locationAuthorized = (locationStatus == .authorizedWhenInUse || locationStatus == .authorizedAlways)

        // BLE-only gating (see startScanning): without Location there is no region-monitoring
        // waker, so the BLE eye must stay continuously active instead of using the idle cycle.
        bluetoothManager.keepContinuousScanWhenBleOnly = !locationAuthorized

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

            // Fix 4 — arm the deferred-sync safety net on relaunch. Previously scheduleSync /
            // scheduleProcessingTask were only called from startScanning() (foreground), so a
            // terminated-then-relaunched app never re-scheduled its BGTasks. Schedule them here
            // so the background-relaunch path keeps the BGTaskScheduler net armed.
            if #available(iOS 13.0, *) {
                BackgroundTaskManager.shared.scheduleSync()
                BackgroundTaskManager.shared.scheduleProcessingTask()
            }

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

                // Record to the internal detection log (diagnostic only — no user-facing
                // notification). The host app reacts to didDetectBeaconInBackground to show
                // its own notification if it wants one.
                DetectionLogStore.append(type: "Background", detail: "\(backgroundBeacons.count) beacon(s) detectado(s)")

                DispatchQueue.main.async {
                    self.delegate?.didDetectBeaconInBackground(beacons: backgroundBeacons)
                }
            }

            // Best-effort immediate attempt (no-ops if nothing valid is collected yet at t≈0).
            self.syncTrigger = "display_on"
            self.syncBeaconsImmediately()

            // Fix 6 — the BLE refresh above takes a moment to settle, so at t≈0 collectedBeacons
            // is usually empty or rssi==0 and the immediate sync no-ops. Re-check shortly after
            // the refresh settles and sync as soon as the FIRST valid-RSSI beacon exists, instead
            // of waiting the full t+25s onBackgroundRangingComplete safety sync (which still runs).
            self.scheduleFirstValidBeaconSync()
        }

        beaconManager.onAppRelaunchedFromTerminated = { [weak self] in
            guard let self else { return }
            NSLog("[BeAroundSDK] APP RELAUNCHED FROM TERMINATED - ensuring configuration")

            if self.configuration == nil {
                self.autoConfigureFromStorage()
            }
        }

        // v2.4 — surface region transitions and location-capture lifecycle to the host app
        // v2.5 — region transitions also drive the BT eye duty-cycle wake/sleep
        beaconManager.onRegionEnter = { [weak self] in
            guard let self else { return }
            // Wake the Bluetooth eye: region entry is the canonical "user is at a beacon"
            // signal, fires from kernel-level CL monitoring even when the app is suspended.
            self.bluetoothManager.wakeToActive()
            // Record to the internal detection log (diagnostic only — no user-facing
            // notification). The host app reacts to didEnterBeaconRegion to show its own.
            DetectionLogStore.append(type: "Região", detail: "Entrou na zona do beacon")
            DispatchQueue.main.async {
                self.delegate?.didEnterBeaconRegion()
            }
        }

        beaconManager.onRegionExit = { [weak self] in
            guard let self else { return }
            // Put the Bluetooth eye back to sleep — user left the zone, stop burning battery.
            self.bluetoothManager.sleepToIdle()
            // Record to the internal detection log (diagnostic only — no user-facing notification).
            DetectionLogStore.append(type: "Região", detail: "Saiu da zona do beacon")
            DispatchQueue.main.async {
                self.delegate?.didExitBeaconRegion()
            }
        }

        // v2.5 — TWO EYES MODEL
        // The BLE scan no longer stops on Location region exit. It runs whenever the user has
        // granted BT permission AND the BluetoothManager was started (see startScanning()).
        // The "active scan" callback now just mirrors the BeaconManager's ranging state, which
        // is the Location eye's notion of "actively tracking". The BLE eye runs continuously
        // and surfaces its own zone presence via didEnterBluetoothZone / didExitBluetoothZone.
        beaconManager.onActiveScanShouldStart = { [weak self] in
            guard let self else { return }
            NSLog("[SDK] Active scan START — region entered (BLE already running independently)")
            self.bluetoothManager.autoStartIfAuthorized()
            DispatchQueue.main.async {
                self.delegate?.didChangeActiveScanState(isActive: true)
            }
        }

        beaconManager.onActiveScanShouldStop = { [weak self] in
            guard let self else { return }
            NSLog("[SDK] Active scan STOP — region exited (BLE keeps running independently)")
            // INTENTIONAL: do NOT stop the BluetoothManager here. The BLE eye is decoupled
            // from CoreLocation region monitoring as of v2.5. The Location eye exiting does
            // not silence the Bluetooth eye.
            DispatchQueue.main.async {
                self.delegate?.didChangeActiveScanState(isActive: false)
            }
        }

        // Re-evaluate BLE-only continuous-scan gating whenever Location authorization changes.
        // E.g. the user grants "Always" later — region monitoring becomes available, so the BLE
        // eye may resume the idle duty cycle. Or it gets revoked — the eye must stay active.
        beaconManager.onAuthorizationChanged = { [weak self] in
            self?.updateBleOnlyContinuousScanFlag()
        }

        bluetoothManager.delegate = self

        // v2.5 — Bluetooth eye: BLE-only zone presence, independent of CoreLocation region.
        bluetoothManager.onBluetoothZoneEnter = { [weak self] in
            guard let self else { return }
            NSLog("[SDK] Bluetooth eye — ENTER ZONE (BLE rising edge)")
            // Record to the internal detection log (diagnostic only — no user-facing
            // notification). The host app reacts to didEnterBluetoothZone to show its own.
            DetectionLogStore.append(type: "Região", detail: "Entrou na zona do beacon")
            DispatchQueue.main.async {
                self.delegate?.didEnterBluetoothZone()
            }

            // Fix 2 — close the BLE-only relaunch path: a rising-edge zone enter (which is the
            // only "user is at a beacon" signal when the app was relaunched via Bluetooth state
            // restoration) must trigger an ingest, not just a delegate callback. Debounced so a
            // flapping zone can't spam the ingester.
            self.syncBeaconsDebounced(trigger: "bluetooth_zone_enter")
        }

        bluetoothManager.onBluetoothZoneExit = { [weak self] in
            NSLog("[SDK] Bluetooth eye — EXIT ZONE (BLE falling edge after grace)")
            DispatchQueue.main.async {
                self?.delegate?.didExitBluetoothZone()
            }
        }

        // v2.5 — surface duty-cycle mode transitions of the BT eye to the host.
        // notifyScanModeChanged already dispatches on main, but we re-route through
        // the same path the other delegate calls use for consistency.
        bluetoothManager.onScanModeChanged = { [weak self] mode, nextIdleScanAt in
            NSLog("[SDK] BT scan mode → %@ (nextIdleScanAt=%@)",
                  mode.rawValue,
                  nextIdleScanAt.map { "\($0)" } ?? "nil")
            self?.delegate?.didChangeBluetoothScanMode(mode, nextIdleScanAt: nextIdleScanAt)
        }

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
                        uuid: BeaconConstants.uuid,
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

                // Drive sync from detection: timer is suspended in deep background, so the
                // BT-eye wake is the only chance to upload. Debounced.
                if !trackedBeacons.isEmpty {
                    self.syncBeaconsDebounced(trigger: "ble_detection")
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

        // Auto-capture the APNs push token from the host app's AppDelegate (swizzling),
        // so clients get push targeting without writing any token-forwarding code.
        PushTokenAutoCapture.enableIfPossible()

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

    /// Registers the device's APNs push token so the backend can target this device for push
    /// (silent background sync today, user-facing notifications in the future).
    ///
    /// Call this from your `AppDelegate.didRegisterForRemoteNotificationsWithDeviceToken`,
    /// passing the hex string of the token. The SDK stores it and sends it **once** with the
    /// next sync, mapped to the stable `deviceId`; it is re-sent only if the token changes.
    public func setPushToken(_ token: String) {
        PushTokenStore.setToken(token)
        NSLog("[BeAroundSDK] Push token registered (will sync on next request)")
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

        // BLE-only gating: if Location is not authorized, there is no region-monitoring waker,
        // so the BLE eye must stay continuously active (no idle duty cycle). Set this BEFORE
        // starting the BLE eye so it picks the right behavior from its first tick.
        bluetoothManager.keepContinuousScanWhenBleOnly = !locationAuthorized

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

        // 2. v2.5 TWO EYES — BLE eye starts here, independent of Location.
        //    Previously BLE was gated by CoreLocation region entry; that coupling is broken now.
        //    The Bluetooth eye runs whenever BT permission is granted and the SDK is scanning.
        //    Its zone presence is derived from its own rolling-window detector
        //    (see BluetoothManager.evaluateZonePresence) and surfaced as
        //    didEnterBluetoothZone / didExitBluetoothZone on the delegate.
        if bluetoothAuthorized {
            bluetoothManager.autoStartIfAuthorized()
        }

        // 3. Location eye — CoreLocation starts only if authorized AND precise location is on.
        //    Location updates are gated by beacon detection — never run continuously.
        if locationCanRangeBeacons {
            beaconManager.updateDesiredAccuracy(configuration!.precisionLocationAccuracy)
            beaconManager.startScanning()
        } else if beaconManager.isScanning {
            // CL was running but can no longer range beacons (e.g., Precise Location turned off)
            beaconManager.stopScanning()
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

    /// Pushes the current Location-authorization state into the BLE eye so it knows whether it
    /// may use the idle duty cycle.
    ///
    /// The BLE idle cycle (10s peek every 5 min) relies on the Location eye's region monitoring
    /// to wake it back to `.active` instantly on a region-enter. When Location is NOT authorized
    /// (notDetermined / denied / restricted) there is no such waker, so a demotion to idle would
    /// delay the next detection by up to a full cycle (5 min). In that case we tell the BLE eye
    /// to stay continuously active. When Location IS authorized (whenInUse or always) the duty
    /// cycle is safe and we leave it enabled.
    private func updateBleOnlyContinuousScanFlag() {
        let status = Self.authorizationStatus()
        let locationAuthorized = (status == .authorizedAlways || status == .authorizedWhenInUse)
        bluetoothManager.keepContinuousScanWhenBleOnly = !locationAuthorized
    }

    /// Opts the SDK into the **Location eye** by requesting Location authorization
    /// from the user. Calling this method is the only way to unlock force-quit-survival
    /// wake-up; without it, the SDK runs in Bluetooth-only mode.
    ///
    /// - Parameter level: `.always` (default) enables terminated-app wake-up via
    ///   CLBeaconRegion monitoring. `.whenInUse` only adds foreground ranging.
    ///
    /// The host app must declare the matching `Info.plist` key:
    /// - `NSLocationWhenInUseUsageDescription` for both levels
    /// - `NSLocationAlwaysAndWhenInUseUsageDescription` for `.always`
    ///
    /// This is a no-op if authorization has already been granted at the requested level.
    /// Authorization is asynchronous; observe `BeAroundSDKDelegate.didChangeScanning`
    /// or query ``authorizationStatus()`` to react to the user's decision.
    public func requestLocationAuthorization(_ level: BeAroundLocationAuthorization = .always) {
        beaconManager.requestLocationAuthorization(level)
    }

    // MARK: - Detection Log (internal diagnostic, not user-facing notifications)

    /// Returns the persistent detection log as JSON (mirrors Android
    /// `getDetectionLogJson`). Each entry: `{id, timestamp, state, type, detail}`.
    ///
    /// This is an internal diagnostic log of detection/sync events tagged with the
    /// process state. The SDK does NOT post user-facing notifications — the host app
    /// reacts to `BeAroundSDKDelegate` callbacks (e.g. `didEnterBeaconRegion`,
    /// `didCompleteSync`, `didDetectBeaconInBackground`) to show its own.
    public func getDetectionLogJson() -> String {
        return DetectionLogStore.readJSON()
    }

    /// Clear the persistent detection log.
    public func clearDetectionLog() {
        DetectionLogStore.clear()
    }

    // MARK: - Sync Timer

    private func startSyncTimer() {
        guard let config = configuration else { return }

        stopSyncTimer()

        let actualAppState = UIApplication.shared.applicationState
        isInBackground = (actualAppState == .background)

        let precision = config.scanPrecision

        // .high: Continuous BLE scan, sync every 15s.
        // Doctrine v3.x: CL ranging is NOT used in steady-state — Location
        // only triggers region enter via kernel-level monitoring, then the
        // BLE eye does all the tracking. This keeps the "Location active"
        // indicator off in the status bar.
        if precision == .high {
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

            // START scanning — BLE only. CL ranging is not used in steady-state
            // (see doctrine note in startSyncTimer above).
            self.bluetoothManager.resumeScanning()

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

        let targetUUID = BeaconConstants.uuid

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

    /// Fix 6 — re-checks shortly after a background BLE refresh and fires a sync as soon as the
    /// first valid-RSSI (rssi != 0) beacon has actually been collected, so the relaunch window
    /// doesn't have to wait the full t+25s onBackgroundRangingComplete safety sync. Two staggered
    /// probes (1.5s, 3s) cover the time the BLE radio needs to surface fresh Service Data; the
    /// debounce guarantees at most one sync fires across them.
    private func scheduleFirstValidBeaconSync() {
        let probeDelays: [TimeInterval] = [1.5, 3.0]
        for delay in probeDelays {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.beaconQueue.async {
                    self.mergeBLEBeacons()
                    let hasValidBeacon = self.collectedBeacons.values.contains {
                        !$0.alreadySynced && $0.rssi != 0
                    }
                    guard hasValidBeacon else {
                        NSLog("[BeAroundSDK] First-valid-beacon probe (%.1fs): no valid beacon yet", delay)
                        return
                    }
                    NSLog("[BeAroundSDK] First-valid-beacon probe (%.1fs): valid beacon present — syncing", delay)
                    // Debounced so the two probes (and a concurrent t+25s sync) don't double-fire.
                    self.syncBeaconsDebounced(trigger: "first_valid_beacon")
                }
            }
        }
    }

    /// Fires an immediate sync but at most once per `minInterval` seconds. Used by
    /// edge-triggered callers (Bluetooth-zone-enter, first-valid-beacon) so a flapping
    /// signal cannot spam the ingester. Thread-safe via `debouncedSyncQueue`.
    /// - Parameters:
    ///   - trigger: The `syncTrigger` to tag the sync with.
    ///   - minInterval: Minimum seconds between two debounced syncs (default 10s).
    private func syncBeaconsDebounced(trigger: String, minInterval: TimeInterval = 10) {
        debouncedSyncQueue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            if let last = self.lastDebouncedSyncTime, now.timeIntervalSince(last) < minInterval {
                NSLog("[BeAroundSDK] Debounced sync skipped (last was %.0fs ago, min=%.0fs, trigger=%@)",
                      now.timeIntervalSince(last), minInterval, trigger)
                return
            }
            self.lastDebouncedSyncTime = now
            self.syncTrigger = trigger
            NSLog("[BeAroundSDK] Debounced sync firing (trigger=%@)", trigger)
            self.syncBeaconsImmediately()
        }
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

            // Fix 3 — Persist-before-send: durably store this batch BEFORE the upload so the
            // detection survives app suspension/termination. On a SUCCESSFUL completion we
            // remove exactly this batch; on failure we leave it for retry. This is the safety
            // net that guarantees eventual delivery even if the completion arrives after the
            // app has been relaunched. `persistedBatchId` is the on-disk filename of the batch.
            let persistedBatchId = self.offlineBatchStorage.saveBatchReturningId(beaconsToSend)

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
                appInForeground: appInForeground
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

                    // Fix 3 — batch delivered: drop the persisted copy so it is never re-sent.
                    if let persistedBatchId {
                        self.offlineBatchStorage.removeBatch(id: persistedBatchId)
                    }

                    // Record to the internal detection log (diagnostic only — no user-facing
                    // notification). The host app reacts to didCompleteSync if it wants one.
                    DetectionLogStore.append(type: "Sync OK", detail: "\(beaconCount) beacon(s) enviados ao ingester")

                    // Push token rode along in this payload and was accepted — record the heartbeat baseline.
                    PushTokenStore.markSent()
                    DiagnosticsStore.shared.recordSync(success: true, beaconCount: beaconCount)

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

                    // Record to the internal detection log (diagnostic only — no user-facing
                    // notification). The host app reacts to didCompleteSync if it wants one.
                    DetectionLogStore.append(type: "Sync falhou", detail: "\(beaconCount) beacon(s) · \(error.localizedDescription)")

                    DiagnosticsStore.shared.recordSync(success: false, beaconCount: beaconCount)
                    DiagnosticsStore.shared.recordError(error.localizedDescription)

                    // Notify delegate of failed sync
                    DispatchQueue.main.async {
                        self.delegate?.didCompleteSync(beaconCount: beaconCount, success: false, error: error)
                    }

                    beaconQueue.async {
                        self.isSyncing = false
                        self.consecutiveFailures += 1
                        self.lastFailureTime = Date()

                        // Fix 3 — the batch was already persisted BEFORE the send
                        // (persist-before-send), so on failure we simply leave it on disk
                        // for the retry drain. No second save here (would duplicate).
                        NSLog("[BeAroundSDK] Sync failed — persisted batch %@ retained for retry",
                              persistedBatchId ?? "nil")

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
                appInForeground: appInForeground
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

                    // Record to the internal detection log (diagnostic only — no user-facing notification).
                    DetectionLogStore.append(type: "Sync OK", detail: "\(beaconCount) beacon(s) enviados ao ingester")

                    // Push token rode along in this payload and was accepted — record the heartbeat baseline.
                    PushTokenStore.markSent()
                    DiagnosticsStore.shared.recordSync(success: true, beaconCount: beaconCount)

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

                    // Record to the internal detection log (diagnostic only — no user-facing notification).
                    DetectionLogStore.append(type: "Sync falhou", detail: "\(beaconCount) beacon(s) · \(error.localizedDescription)")

                    DiagnosticsStore.shared.recordSync(success: false, beaconCount: beaconCount)
                    DiagnosticsStore.shared.recordError(error.localizedDescription)

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

    /// Background-upload identifier owned by the SDK's background `URLSession`.
    /// The host app compares the `identifier` it receives against this value.
    public static var backgroundURLSessionIdentifier: String {
        BackgroundSessionManager.backgroundSessionIdentifier
    }

    /// Forwarded from the host app's
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    ///
    /// When the OS relaunches the app to deliver pending background-upload results, it hands
    /// over a `completionHandler` that must be invoked once all events have been processed.
    /// This stores that handler and makes sure the SDK's background session is alive so its
    /// delegate callbacks (including `urlSessionDidFinishEvents`) fire and eventually call it.
    ///
    /// - Parameters:
    ///   - identifier: The session identifier the OS supplied.
    ///   - completionHandler: The system handler to invoke when events finish draining.
    public func handleBackgroundURLSessionEvents(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundSessionManager.backgroundSessionIdentifier else {
            NSLog("[BeAroundSDK] Ignoring background events for unknown session '%@'", identifier)
            completionHandler()
            return
        }

        NSLog("[BeAroundSDK] Handling background URLSession events for '%@'", identifier)

        // Make sure we have a configured apiClient (and therefore a live background session)
        // even if the app was cold-launched purely to deliver these events.
        if configuration == nil {
            autoConfigureFromStorage()
        }

        BackgroundSessionManager.shared.setSystemEventsCompletionHandler(completionHandler)
    }

    /// Snapshot of the most recent background scan+sync attempt. Host apps can read this in the
    /// completion of `performBackgroundBLERefreshAndSync` to surface a detailed local notification
    /// (did the scan run, how many beacons were found, whether an upload was started).
    public struct BackgroundScanInfo {
        public let beaconsFound: Int
        public let ingestStarted: Bool
        public let pendingBatches: Int
    }

    /// Set right before the background-sync completion fires, on `beaconQueue`.
    public private(set) var lastBackgroundScanInfo: BackgroundScanInfo?

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
            let beaconsFound = collectedBeacons.count
            let pendingBatches = offlineBatchStorage.batchCount
            let ingestStarted = hasBeacons || hasFailedBatches

            // Snapshot BEFORE syncBeacons() may clear collectedBeacons, so the host app can
            // read an accurate count in its completion handler.
            self.lastBackgroundScanInfo = BackgroundScanInfo(
                beaconsFound: beaconsFound,
                ingestStarted: ingestStarted,
                pendingBatches: pendingBatches
            )
            DiagnosticsStore.shared.recordScan(beaconCount: beaconsFound)

            if ingestStarted {
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

    /// Called by BGTaskScheduler / silent push — refreshes BLE scan, collects Service Data, then syncs.
    /// `bleScanDuration` is the MAX wait: we sync as soon as a beacon is captured, or when it elapses.
    public func performBackgroundBLERefreshAndSync(bleScanDuration: TimeInterval = 10.0, trigger: String = "bg_task", completion: @escaping (Bool) -> Void) {
        NSLog("[BeAroundSDK] BGTask: refreshing BLE scan for Service Data (trigger=%@, maxWait=%.0fs)", trigger, bleScanDuration)

        // Ensure BLE is scanning
        if !bluetoothManager.isScanning {
            bluetoothManager.autoStartIfAuthorized()
            NSLog("[BeAroundSDK] BGTask: BLE scan started")
        } else {
            bluetoothManager.refreshScan()
            NSLog("[BeAroundSDK] BGTask: BLE scan refreshed")
        }

        // Background BLE on a cold wake is slow: CoreBluetooth must power on (async), then the
        // iOS-throttled background scan window has to catch an advertising packet. A fixed short
        // wait often fires BEFORE the scan even started, so we'd sync with 0 beacons even while
        // physically inside the zone. Instead, POLL and sync as soon as data appears — bounded by
        // `bleScanDuration` as the ceiling for the cold/empty case.
        let deadline = Date().addingTimeInterval(bleScanDuration)
        let pollInterval: TimeInterval = 0.5

        func waitForData() {
            beaconQueue.async { [weak self] in
                guard let self else {
                    completion(false)
                    return
                }
                let hasData = !self.collectedBeacons.isEmpty || self.offlineBatchStorage.batchCount > 0
                if hasData {
                    NSLog("[BeAroundSDK] BGTask: data ready (beacons=%d) — syncing", self.collectedBeacons.count)
                    self.performBackgroundSync(trigger: trigger, completion: completion)
                } else if Date() >= deadline {
                    NSLog("[BeAroundSDK] BGTask: max wait (%.0fs) reached, no beacons captured", bleScanDuration)
                    self.performBackgroundSync(trigger: trigger, completion: completion)
                } else {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + pollInterval) {
                        waitForData()
                    }
                }
            }
        }
        waitForData()
    }

    /// Called by app's performFetchWithCompletionHandler
    public func performBackgroundFetch(completion: @escaping (Bool) -> Void) {
        NSLog("[BeAroundSDK] Background fetch triggered")

        if configuration == nil {
            if let savedConfig = SDKConfigStorage.load() {
                configuration = savedConfig
                apiClient = APIClient(configuration: savedConfig)
                setupSDKInfo(from: savedConfig)
                // Fix 1 — keep the background-upload session alive on this relaunch path too.
                apiClient?.ensureBackgroundSessionAlive()
                offlineBatchStorage.maxBatchCount = savedConfig.maxQueuedPayloads.value
                NSLog("[BeAroundSDK] Auto-configured during background fetch")
            } else {
                NSLog("[BeAroundSDK] Background fetch: no config")
                completion(false)
                return
            }
        }

        performBackgroundBLERefreshAndSync(bleScanDuration: 10.0, trigger: "background_fetch", completion: completion)
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
        // Fix 5 — acquire the UIBackgroundTask assertion SYNCHRONOUSLY before returning, so the
        // caller (syncBeacons / drainRetryQueue, both on beaconQueue) does not reach
        // task.resume() before the assertion is held. The previous version hopped to
        // main.async and returned immediately, racing the network call against suspension.
        let work = { [weak self] in
            guard let self, self.backgroundTaskId == .invalid else { return }
            self.backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "BeAroundSDK-Sync") { [weak self] in
                NSLog("[BeAroundSDK] Background task expiring")
                self?.endBackgroundTask()
            }
            NSLog("[BeAroundSDK] Background task started: %lu", self.backgroundTaskId.rawValue)
        }

        if Thread.isMainThread {
            work()
        } else {
            // Safe: callers run on beaconQueue (never main), so this cannot deadlock.
            DispatchQueue.main.sync(execute: work)
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

        // Always add to collectedBeacons. We do NOT skip when the beacon is
        // already CL-tracked anymore — CL ranging is off in steady-state, so
        // BLE is the canonical source of beacon data. But we DO inherit the
        // `.coreLocation` source if we're inside a region the Location eye
        // detected, so the host UI can count the beacon under both eyes.
        beaconQueue.async {
            var sources: Set<BeaconDiscoverySource> = [discoverySource]

            // If the Location eye is currently reporting "inside the beacon
            // region", credit it for this detection too — that's what the
            // two-eyes UI uses to render the "Location" counter.
            if self.beaconManager.isInBeaconRegion {
                sources.insert(.coreLocation)
            }

            // Preserve any source the previous snapshot had (e.g. .coreLocation
            // set during the terminated-relaunch warm-up).
            if let existing = self.collectedBeacons[key] {
                sources.formUnion(existing.discoverySources)
            }

            var beacon = Beacon(
                uuid: BeaconConstants.uuid,
                major: major,
                minor: minor,
                rssi: rssi,
                proximity: .bt,
                accuracy: -1,
                metadata: metadata,
                txPower: txPower,
                discoverySources: sources
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
