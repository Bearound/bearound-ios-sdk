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

    /// SDK version, resolved automatically (see `SDKVersion.resolved`). The old
    /// implementation read `Bundle(for:)` directly, which under static linking
    /// (React Native default) resolves to the HOST APP's bundle — "1.0" on
    /// screen and in the ingest telemetry.
    public static var version: String { SDKVersion.resolved }

    /// Single, reused CLLocationManager for **read-only** queries of authorization /
    /// accuracy status. Created once and held for the app lifetime so we avoid the
    /// init/dealloc churn that happens when we say `CLLocationManager().authorizationStatus`
    /// from a hot path: each transient instance does a TCC IPC (`tcc_send_request_authorization`),
    /// allocates a daemon-side client (`_CLClientCreateConnection`), then dealloc'd 2ms later.
    /// Device logs on iPhone 16 Pro Max showed this churn cycling every ~1.5s and starving
    /// background BLE delivery (correlated with `CLConnection::handleInterruption` events and
    /// ~11s gaps in beacon ad delivery → false "entered zone with 0 beacons" UX).
    ///
    /// IMPORTANT: this manager is for status queries only — do NOT call
    /// `startMonitoring`/`startUpdatingLocation` on it. The actual region-monitoring
    /// CLLocationManager lives inside `BeaconManager`.
    private static let authQueryManager = CLLocationManager()

    // MARK: - Public Properties

    public weak var delegate: BeAroundSDKDelegate?

    public var isScanning: Bool {
        bluetoothManager.isScanning || beaconManager.isScanning
    }

    /// P5 — arms the Location eye when authorization arrives AFTER startScanning().
    /// Uses the persisted scanning intent (not the derived isScanning) so the case
    /// "host asked to scan but every eye was gated off" also recovers.
    private func startLocationEyeIfAuthorizedAndWanted() {
        guard configuration != nil,
              SDKConfigStorage.loadIsScanning(),
              !beaconManager.isScanning else { return }

        let status = Self.authorizationStatus()
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        if #available(iOS 14.0, *),
           Self.authQueryManager.accuracyAuthorization == .reducedAccuracy {
            NSLog("[BeAroundSDK] Precise Location OFF — Location eye stays off")
            return
        }

        NSLog("[BeAroundSDK] Location authorization granted post-start — arming the Location eye")
        beaconManager.startScanning()
        updateBleOnlyContinuousScanFlag()
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
            let acc = Self.authQueryManager.accuracyAuthorization
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

        // UIApplication.backgroundRefreshStatus is main-thread-only. Collect it (and the
        // BGTask registration flag, which is cheap) synchronously on main when we're off it.
        let backgroundRefresh: String
        if Thread.isMainThread {
            backgroundRefresh = Self.backgroundRefreshStatusString()
        } else {
            backgroundRefresh = DispatchQueue.main.sync { Self.backgroundRefreshStatusString() }
        }

        var bgTasksRegistered = false
        if #available(iOS 13.0, *) {
            bgTasksRegistered = BackgroundTaskManager.shared.tasksRegistered
        }

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
            sdkVersion: BeAroundSDK.version,
            authorizationStatus: Self.authorizationStatusString(Self.authorizationStatus()),
            bluetoothState: Self.bluetoothStateString(),
            backgroundRefreshStatus: backgroundRefresh,
            backgroundTasksRegistered: bgTasksRegistered
        )
    }

    /// Human-readable CoreLocation authorization status for diagnostics.
    private static func authorizationStatusString(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    /// Bluetooth state for diagnostics, derived without instantiating a new `CBCentralManager`
    /// (which would trigger the permission prompt). Combines the shared central's power state
    /// with the static, prompt-free `CBCentralManager.authorization`.
    private static func bluetoothStateString() -> String {
        if #available(iOS 13.1, *) {
            switch CBCentralManager.authorization {
            case .denied: return "unauthorized(denied)"
            case .restricted: return "unauthorized(restricted)"
            case .notDetermined: return "notDetermined"
            case .allowedAlways: break
            @unknown default: break
            }
        }
        return BeAroundSDK.shared.bluetoothManager.isPoweredOn ? "poweredOn" : "poweredOff"
    }

    /// `UIApplication.backgroundRefreshStatus` as a String. Must be called on the main thread.
    private static func backgroundRefreshStatusString() -> String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: return "available"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Private Properties

    private var configuration: SDKConfiguration?
    private var sdkInfo: SDKInfo?
    private var userProperties: UserProperties?

    private let deviceInfoCollector = DeviceInfoCollector(isColdStart: true)
    private let beaconManager = BeaconManager()
    private let bluetoothManager = BluetoothManager()
    private var apiClient: APIClient?

    /// Telemetry metadata by "major.minor" key. Written from bleQueue
    /// (didDiscoverBeacon) and read from main (CL enrichment callback) — every
    /// access must go through `metadataCacheLock`.
    private var metadataCache: [String: BeaconMetadata] = [:]
    private let metadataCacheLock = NSLock()

    private func cachedMetadata(for key: String) -> BeaconMetadata? {
        metadataCacheLock.lock(); defer { metadataCacheLock.unlock() }
        return metadataCache[key]
    }

    private func cacheMetadata(_ metadata: BeaconMetadata, for key: String) {
        metadataCacheLock.lock(); defer { metadataCacheLock.unlock() }
        metadataCache[key] = metadata
    }
    private var syncTimer: DispatchSourceTimer?
    private var collectedBeacons: [String: Beacon] = [:]
    /// Sampling model with volume containment: the SAME beacon re-syncs at most once
    /// per this interval (Android-parity 60 s). Keeps the per-sample ingest contract
    /// unchanged while cutting steady-state volume ~4x (a parked device stops emitting
    /// an event on every scan cycle).
    private static let sampleReportInterval: TimeInterval = 60.0

    /// How long a synced beacon stays in collectedBeacons after delivery (Android parity:
    /// 30s post-sync removal). Keeps the "synced" state visible to the host briefly while
    /// bounding the dictionary — see cleanupStaleBeacons.
    private static let syncedBeaconRetention: TimeInterval = 30.0

    /// Statuses where an identical retry fails identically (payload/credential problem,
    /// not transport). 413 included: a SINGLE batch over the limit is malformed, not
    /// splittable. Android-parity — see the drain's head-of-line guard.
    private static let permanentHTTPCodes: Set<Int> = [400, 401, 403, 404, 413, 422]

    private let beaconQueue = DispatchQueue(label: "com.bearound.sdk.beaconQueue")
    private var isSyncing = false

    private let offlineBatchStorage = OfflineBatchStorage.shared

    private var consecutiveFailures = 0
    private var lastFailureTime: Date?
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

    /// Dedicated assertion for the terminated-relaunch window. Separate from
    /// [backgroundTaskId] (the sync/upload assertion): iOS grants a location-relaunched
    /// app only ~10 s of runtime, while the cold-start CL ranging one-shot needs 25 s
    /// (terminatedAppRangingDuration) to seed a beacon + fire the safety sync. Without
    /// this assertion the process was suspended mid-ranging and the region relaunch
    /// produced ZERO syncs (field: iPhone 15 Pro Max — 3 relaunches logged, no sync).
    private var relaunchWindowTaskId: UIBackgroundTaskIdentifier = .invalid
    private var isInBackground = false
    private var wasLaunchedInBackground = false
    private var syncTrigger = "unknown"

    /// Timestamp of the last debounced immediate sync (Fix 2/6). Guards edge-triggered syncs
    /// (e.g. a flapping Bluetooth zone) from spamming the ingester.

    // MARK: - Initialization

    private init() {
        let appState = UIApplication.shared.applicationState
        // Only a REAL background launch counts. A normal foreground launch passes
        // through `.inactive` during didFinishLaunching — the old `!= .active`
        // check classified it as background, auto-configured from storage, opened
        // a relaunch assertion and started scanning before the host asked.
        wasLaunchedInBackground = appState == .background

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

        // Hold the relaunch window open from the very first instant of a background
        // relaunch — NOT only when didEnterRegion arrives. Field case: the CL answers
        // `unknown` on boot, nothing re-asks, and with no enter (→ no ranging, no
        // assertion) iOS kills the idle process in ~10 s before the state resolves.
        beginRelaunchWindowTask()

        // Explicit cold-relaunch marker: this path only runs on a background relaunch,
        // and it may flip isScanning=true BEFORE didEnterRegion is delivered — the old
        // `!isScanning` inference then skipped the 25 s seeding ranging AND the relaunch
        // window task. The flag survives that race; didEnterRegion consumes it.
        beaconManager.expectColdStartRanging = true

        guard let savedConfig = SDKConfigStorage.load() else {
            NSLog("[BeAroundSDK] No saved configuration for background relaunch")
            // No work to do — release the relaunch assertion instead of holding it
            // until the system expires it.
            endRelaunchWindowTask()
            return
        }

        restoreUserIdentityIfNeeded()

        // First-party error telemetry — install on background relaunch too, so a crash/error
        // that happens while the app was woken in the background is still captured. Idempotent.
        ErrorReporter.shared.install(
            businessToken: savedConfig.businessToken,
            apiBaseURL: savedConfig.apiBaseURL,
            technology: savedConfig.technology,
            sdkVersion: Self.version
        )

        // Periodic reconciliation settings must survive background relaunches too —
        // handleSyncTask/scheduleSync read them from the manager, not from the SDK.
        if #available(iOS 13.0, *) {
            BackgroundTaskManager.shared.applyPeriodicConfiguration(
                enabled: savedConfig.periodicReconciliationEnabled,
                interval: savedConfig.periodicReconciliationInterval,
                scanDuration: savedConfig.periodicScanDuration
            )
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
            // Scanning stays off — no cold-start ranging will run, so nothing else
            // would ever close this assertion. Release it now.
            endRelaunchWindowTask()
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
            if Self.authQueryManager.accuracyAuthorization == .reducedAccuracy {
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

            DispatchQueue.main.async { self.delegate?.didChangeScanning(isScanning: true) }
            NSLog("[BeAroundSDK] AUTO-CONFIGURED from storage (BLE=%d, CL=%d)", bluetoothAuthorized ? 1 : 0, locationCanRangeBeacons ? 1 : 0)
        } else {
            NSLog("[BeAroundSDK] AUTO-CONFIGURE: both BLE and Location denied/reduced, cannot scan")
        }
    }

    private func setupSDKInfo(from config: SDKConfiguration) {
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let build = Int(buildNumber) ?? 1
        // Wire the *real* SDK version (not SDKInfo's stale default) and the configured technology.
        sdkInfo = SDKInfo(
            version: BeAroundSDK.version,
            appId: config.appId,
            build: build,
            technology: config.technology
        )
    }

    // MARK: - Callbacks Setup

    private func setupCallbacks() {
        beaconManager.onBeaconsUpdated = { [weak self] beacons in
            guard let self else { return }

            // P1 — snapshot once per callback instead of racing the bleQueue's
            // cleanup timer with per-key dictionary reads from this (main) thread.
            let trackedSnapshot = self.bluetoothManager.trackedBeaconsSnapshot()
            let enrichedBeacons = beacons.map { beacon -> Beacon in
                let key = "\(beacon.major).\(beacon.minor)"
                let bleTracked = trackedSnapshot[key]
                let metadata = bleTracked?.metadata ?? self.cachedMetadata(for: key)

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
                    let existingSample = self.collectedBeacons[key]
                    if self.sampleIsDirty(existing: existingSample, newRSSI: beacon.rssi, newMetadata: beacon.metadata) {
                        beacon.syncedAt = existingSample?.syncedAt
                        beacon.alreadySynced = false
                    } else {
                        let pending = self.pendingStateForSample(existing: existingSample)
                        beacon.syncedAt = pending.syncedAt
                        beacon.alreadySynced = pending.alreadySynced
                    }
                    self.collectedBeacons[key] = beacon
                    updatedBeacons.append(beacon)
                }

                DispatchQueue.main.async {
                    self.delegate?.didUpdateBeacons(updatedBeacons)
                }

                // Detection-driven sync for the CoreLocation path — the missing link:
                // only the BLE path requested a sync on detection, so in CL-only the
                // first upload waited for the 15 s precision timer (field: enter at
                // 15:33:01, samples flowing, zero syncs for 40 s). Pending sample →
                // coordinator now (fg fast-path floor / bg batch window apply).
                if updatedBeacons.contains(where: { !$0.alreadySynced }) {
                    self.requestSync(reason: "cl_ranging_detection")
                }
            }
        }

        beaconManager.onError = { [weak self] error in
            ErrorReporter.shared.report(error, context: "beaconManager")
            // CoreLocation delegate callbacks arrive on the main thread, but ranging-watchdog
            // timers can fire this off other queues — always hop to main so the host's UI code
            // in didFailWithError never touches UIKit off-thread.
            DispatchQueue.main.async {
                self?.delegate?.didFailWithError(error)
            }
        }

        beaconManager.onScanningStateChanged = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.delegate?.didChangeScanning(isScanning: self.isScanning)
            }
        }

        // Triggered when background ranging completes
        beaconManager.onBackgroundRangingComplete = { [weak self] in
            guard let self else { return }
            NSLog("[BeAroundSDK] Background ranging complete - syncing NOW")
            self.syncTrigger = "background_ranging_complete"
            self.syncBeaconsImmediately()
            // The cold-start window served its purpose; the sync above holds its own
            // assertion (backgroundTaskId) for the upload itself.
            self.endRelaunchWindowTask()
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

                let backgroundBeacons = Array(self.collectedBeacons.values).filter { $0.rssi != 0 || $0.discoverySources.contains(.coreLocation) }
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

            // Hold the relaunch window open NOW: without this the OS suspends the
            // process ~10 s after the background relaunch, killing the 25 s cold-start
            // ranging before it can seed a beacon or fire its safety sync.
            self.beginRelaunchWindowTask()

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
            guard let self else { return }
            self.updateBleOnlyContinuousScanFlag()
            // Location granted AFTER startScanning(): the Location eye was gated off
            // at start (the SDK only calls beaconManager.startScanning when already
            // authorized) and nothing re-armed it — the eye stayed dead until the
            // host called startScanning() again. Arm it here.
            self.startLocationEyeIfAuthorizedAndWanted()
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
            self.requestSync(reason: "bluetooth_zone_enter")
        }

        bluetoothManager.onBluetoothZoneExit = { [weak self] in
            NSLog("[SDK] Bluetooth eye — EXIT ZONE (BLE falling edge after grace)")
            DispatchQueue.main.async {
                self?.delegate?.didExitBluetoothZone()
            }
        }

        // Diagnostic-only: BLE silent past the grace while backgrounded. iOS coalesces
        // repeated ads in background, so this is visibility loss — NOT a zone exit.
        // Cross-eye rule for BLE silence: while CL reports inside, silence is never exit.
        bluetoothManager.locationEyeInsideProvider = { [weak self] in
            self?.beaconManager.isInBeaconRegion ?? false
        }

        bluetoothManager.onBluetoothVisibilityStale = { elapsed in
            DetectionLogStore.append(type: "BLE_VISIBILITY_STALE", detail: String(format: "sem callback há %.0fs (zona preservada)", elapsed))
        }

        // Lifecycle: scanner stopped by host/SDK — surfaced for observability, never
        // translated into a presence exit.
        bluetoothManager.onScanningStopped = {
            DetectionLogStore.append(type: "BLE_SCAN_STOPPED", detail: "scanner desligado (lifecycle, não presença)")
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

            // (Removed) The 10 s tracked-snapshot purge deleted collectedBeacons entries
            // whenever iOS coalesced BLE callbacks for >10 s in background — the beacon
            // then came back as brand-new and re-synced. collectedBeacons represents the
            // presence session, not the last didDiscover snapshot; sample freshness is
            // governed by pendingStateForSample()'s report window instead.

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
                    let existingSample = self.collectedBeacons[key]
                    if self.sampleIsDirty(existing: existingSample, newRSSI: beacon.rssi, newMetadata: beacon.metadata) {
                        beacon.syncedAt = existingSample?.syncedAt
                        beacon.alreadySynced = false
                    } else {
                        let pending = self.pendingStateForSample(existing: existingSample)
                        beacon.syncedAt = pending.syncedAt
                        beacon.alreadySynced = pending.alreadySynced
                    }
                    self.collectedBeacons[key] = beacon
                    beaconsForDelegate.append(beacon)
                }

                // Cross-eye evidence for the CL exit hysteresis: the BLE eye seeing the
                // beacon is proof of presence the kernel's sparse windows may be missing.
                if !trackedBeacons.isEmpty {
                    self.beaconManager.noteBeaconEvidence()
                }

                // Drive sync from detection: timer is suspended in deep background, so the
                // BT-eye wake is the only chance to upload. Debounced.
                if !trackedBeacons.isEmpty {
                    self.requestSync(reason: "ble_detection")
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

        // Foreground flush: anything background couldn't deliver (frozen timers,
        // deferred uploads, retry backlog) ships NOW instead of waiting the first
        // timer tick (+15/60s). Kills the "events only arrive when I open the
        // app... minutes later" symptom; also drains the persisted retry queue.
        requestSync(reason: "foreground_flush")
    }

    // MARK: - Public API

    /// Configures the SDK. Call once per launch, before ``startScanning()``.
    ///
    /// - Parameters:
    ///   - businessToken: your Bearound business token (required, non-empty).
    ///   - scanPrecision: scan/sync precision profile. Default: `.high`.
    ///   - maxQueuedPayloads: cap for offline-batch retention. Default: `.medium`.
    ///   - technology: origin technology reported to the backend. Default `"ios-native"`
    ///     (the React Native / Flutter bridges pass their own).
    ///   - periodicReconciliationEnabled: enables the periodic background reconciliation
    ///     (`BGAppRefreshTask`). Best effort — iOS decides when (if) the task runs.
    ///     Default: `true`.
    ///   - periodicReconciliationInterval: **earliest** allowed start of the next attempt —
    ///     a floor, never a guaranteed cadence. Accepted range **10 min … 24 h** (out-of-range
    ///     values are clamped with a highlighted ⚠️ os_log; NaN/∞/≤0 fall back to the default).
    ///     Default: 20 minutes.
    ///   - periodicScanDuration: ceiling of the temporary BLE window inside the task.
    ///     Accepted range **3 … 15 s** — the ~30s BGTask budget must also fit the sync
    ///     (an oversized window makes every run expire and iOS stops granting executions).
    ///     Default: 12 seconds.
    public func configure(
        businessToken: String,
        scanPrecision: ScanPrecision = .high,
        maxQueuedPayloads: MaxQueuedPayloads = .medium,
        technology: String = "ios-native",
        periodicReconciliationEnabled: Bool = true,
        periodicReconciliationInterval: TimeInterval = PeriodicReconciliationDefaults.interval,
        periodicScanDuration: TimeInterval = PeriodicReconciliationDefaults.scanDuration,
        requestTrackingOnStart: Bool = true
    ) {
        let config = SDKConfiguration(
            businessToken: businessToken,
            scanPrecision: scanPrecision,
            maxQueuedPayloads: maxQueuedPayloads,
            technology: technology,
            periodicReconciliationEnabled: periodicReconciliationEnabled,
            periodicReconciliationInterval: periodicReconciliationInterval,
            periodicScanDuration: periodicScanDuration,
            requestTrackingOnStart: requestTrackingOnStart
        )

        configuration = config
        apiClient = APIClient(configuration: config)
        setupSDKInfo(from: config)

        offlineBatchStorage.maxBatchCount = config.maxQueuedPayloads.value

        // Save for background relaunch
        SDKConfigStorage.save(config)

        // Periodic reconciliation: apply the (sanitized) settings to the scheduler.
        // A reconfigure only affects FUTURE requests — the next scheduleSync() call
        // re-submits with the new interval (cancel-then-submit is already how the
        // scheduler stays idempotent); a task already running is never touched.
        // Disabling cancels pending future requests right away.
        if #available(iOS 13.0, *) {
            BackgroundTaskManager.shared.applyPeriodicConfiguration(
                enabled: config.periodicReconciliationEnabled,
                interval: config.periodicReconciliationInterval,
                scanDuration: config.periodicScanDuration
            )
            if !config.periodicReconciliationEnabled {
                BackgroundTaskManager.shared.cancelPeriodicReconciliation()
            }
        }

        // Auto-capture the APNs push token from the host app's AppDelegate (swizzling),
        // so clients get push targeting without writing any token-forwarding code.
        PushTokenAutoCapture.enableIfPossible()

        // First-party error telemetry — chains the uncaught-exception handler (idempotent) and
        // primes the transport. Best-effort; never affects the host app.
        ErrorReporter.shared.install(
            businessToken: config.businessToken,
            apiBaseURL: config.apiBaseURL,
            technology: config.technology,
            sdkVersion: Self.version
        )

        // App Tracking Transparency, raised by the SDK so the IDFA arrives without the host
        // wiring up a call. Waits for the app to be on screen, and stays silent entirely
        // unless the host declared NSUserTrackingUsageDescription.
        if config.requestTrackingOnStart {
            AdvertisingIdCollector.requestAuthorizationOnStart()
        }

        if isScanning {
            startSyncTimer()
        }
    }

    /// Enables or disables first-party SDK error telemetry (crash/error reports sent to
    /// Bearound's ingest endpoint to improve SDK reliability). Enabled by default.
    ///
    /// Disabling stops report delivery immediately; it does not affect beacon scanning, sync,
    /// or the host app's own crash reporting. Only errors originating inside the Bearound SDK
    /// are ever reported.
    public func setErrorReportingEnabled(_ enabled: Bool) {
        ErrorReporter.shared.setEnabled(enabled)
    }

    public func setUserProperties(_ properties: UserProperties) {
        userProperties = (userProperties ?? UserProperties()).merging(properties)
        SDKConfigStorage.saveInternalId(userProperties?.internalId)
    }

    public func clearUserProperties() {
        userProperties = nil
        SDKConfigStorage.saveInternalId(nil)
    }

    /// Restores the persisted user id into memory after a background relaunch.
    private func restoreUserIdentityIfNeeded() {
        guard userProperties?.internalId == nil,
              let internalId = SDKConfigStorage.loadInternalId() else { return }
        userProperties = (userProperties ?? UserProperties()).merging(UserProperties(internalId: internalId))
    }

    /// Registers the device's APNs push token so the backend can target this device for push
    /// (silent background sync today, user-facing notifications in the future).
    ///
    /// Call this from your `AppDelegate.didRegisterForRemoteNotificationsWithDeviceToken`,
    /// passing the hex string of the token. The SDK stores it and sends it with the next sync,
    /// mapped to the stable `deviceId`. It is re-sent whenever the token changes **or** after a
    /// 7-day heartbeat window (self-healing), so a dropped sync never permanently loses the token.
    public func setPushToken(_ token: String) {
        PushTokenStore.setToken(token)
        NSLog("[BeAroundSDK] Push token registered")
        // Se já estamos escaneando e o token ainda não foi enviado (novo/mudou),
        // empurra agora via register (beacons:[]) — senão só iria no próximo
        // register (TTL) ou ao detectar um beacon. Cobre apps que chamam
        // setPushToken DEPOIS do startScanning: o register-on-init já teria saído
        // sem o token, e o token NÃO faz parte do fingerprint (um register normal
        // não re-dispararia).
        if SDKConfigStorage.loadIsScanning(), PushTokenStore.tokenForPayload != nil {
            registerDeviceIfNeeded(force: true)
        }
    }

    public func startScanning() {
        guard configuration != nil else {
            let error = NSError(
                domain: "BeAroundSDK",
                code: BearoundErrorCode.notConfigured.rawValue,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "SDK not configured. Call configure(businessToken:) first."
                ]
            )
            ErrorReporter.shared.report(error, context: "startScanning")
            DispatchQueue.main.async { self.delegate?.didFailWithError(error) }
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
            let accuracy = Self.authQueryManager.accuracyAuthorization
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
                code: BearoundErrorCode.noScanAuthorization.rawValue,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Cannot scan for beacons. Bluetooth is denied and Location has Precise Location disabled."
                ]
            )
            ErrorReporter.shared.report(error, context: "startScanning")
            DispatchQueue.main.async { self.delegate?.didFailWithError(error) }
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

        // 2b. Encounter layer — runs whenever Bluetooth is authorized (same contract as
        //     the wifi collection); stops with stopScanning().
        if bluetoothAuthorized {
            bluetoothManager.setEncounterMesh(enabled: true)
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
        DispatchQueue.main.async { self.delegate?.didChangeScanning(isScanning: true) }
        SDKConfigStorage.saveIsScanning(true)

        if #available(iOS 13.0, *) {
            BackgroundTaskManager.shared.scheduleSync()
            BackgroundTaskManager.shared.scheduleProcessingTask()
        }

        os_log("[SDK] STARTED BLE=%{public}d CL=%{public}d", log: sdkLog, type: .info,
               bluetoothAuthorized ? 1 : 0, locationCanRangeBeacons ? 1 : 0)

        // 5. Device register — fire-and-forget, does not block scanning.
        //    Sends POST /ingest with beacons:[] + syncTrigger:"register" so every device
        //    appears in the Control Hub even if it never detects a beacon nearby.
        registerDeviceIfNeeded()
    }

    public func stopScanning() {
        bluetoothManager.setEncounterMesh(enabled: false)
        bluetoothManager.stopScanning()

        if beaconManager.isScanning {
            beaconManager.stopScanning()
        }

        stopSyncTimer()
        syncTrigger = "stop_scanning"
        syncBeaconsImmediately()
        DispatchQueue.main.async { self.delegate?.didChangeScanning(isScanning: false) }

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
            return authQueryManager.authorizationStatus
        } else {
            return CLLocationManager.authorizationStatus()
        }
    }

    /// Internal helper for telemetry collectors — returns the current accuracy
    /// authorization without instantiating a transient CLLocationManager.
    @available(iOS 14.0, *)
    internal static func sharedAccuracyAuthorization() -> CLAccuracyAuthorization {
        return authQueryManager.accuracyAuthorization
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

    /// Shows the App Tracking Transparency prompt and, once authorised, starts reporting the
    /// IDFA with every payload.
    ///
    /// **You usually do not need to call this.** The SDK raises the prompt by itself shortly
    /// after `configure()`. Call it only when you opted out with
    /// `configure(requestTrackingOnStart: false)` to control the moment — for example, after
    /// your own screen explaining why you are asking.
    ///
    /// Requires `NSUserTrackingUsageDescription` in your `Info.plist`; without that key iOS
    /// does not show the dialog and the status stays `notDetermined` forever. Only call it
    /// while the app is in the foreground — iOS silently ignores it otherwise.
    ///
    /// Answering is a one-time event per install — later calls return the stored decision
    /// with no UI, so it is safe to call on every launch.
    ///
    /// - Parameter completion: authorisation status on the main queue — `authorized`,
    ///   `denied`, `restricted`, `notDetermined`, or `unavailable` below iOS 14.
    public func requestTrackingAuthorization(completion: ((String) -> Void)? = nil) {
        AdvertisingIdCollector.requestAuthorization(completion: completion)
    }

    /// Current App Tracking Transparency status, without showing any prompt.
    public static func trackingAuthorizationStatus() -> String {
        AdvertisingIdCollector.authorizationStatus()
    }

    // MARK: - Device Register

    /// Sends a POST /ingest with `beacons: []` and `syncTrigger: "register"` when needed.
    ///
    /// Conditions (any one triggers a send):
    /// - Never registered before.
    /// - Fingerprint changed (businessToken / appId / sdkVersion / osVersion / appBuild).
    /// - More than 24 h since last successful register.
    ///
    /// Runs asynchronously on a background queue — does NOT block `startScanning()`.
    /// On HTTP 200 the store persists `lastSentAt` + `lastFingerprint`.
    private func registerDeviceIfNeeded(force: Bool = false) {
        guard let apiClient = apiClient, let sdkInfo = sdkInfo, let config = configuration else {
            NSLog("[BeAroundSDK] registerDeviceIfNeeded: SDK not fully configured, skipping")
            return
        }

        let deviceId = DeviceIdentifier.getDeviceId()
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let osVersion = UIDevice.current.systemVersion

        let fingerprint = RegisterStore.fingerprint(
            deviceId: deviceId,
            appId: sdkInfo.appId,
            businessToken: config.businessToken,
            sdkVersion: sdkInfo.version,
            osVersion: osVersion,
            appBuild: appBuild
        )

        guard force || RegisterStore.shouldRegister(currentFingerprint: fingerprint) else {
            NSLog("[BeAroundSDK] Device already registered and fingerprint unchanged — skipping register")
            return
        }

        NSLog("[BeAroundSDK] Sending device register (beacons:[], syncTrigger:register)")

        let locationPermission = Self.authorizationStatus()
        let bluetoothState = bluetoothManager.isPoweredOn ? "powered_on" : "powered_off"
        let appInForeground = !isInBackground

        var userDevice = deviceInfoCollector.collectDeviceInfo(
            locationPermission: locationPermission,
            bluetoothState: bluetoothState,
            appInForeground: appInForeground
        )
        attachEncounterData(to: &userDevice)

        apiClient.sendBeacons(
            [],
            sdkInfo: sdkInfo,
            userDevice: userDevice,
            userProperties: userProperties,
            syncTrigger: "register",
            delivery: .immediateFirst
        ) { [weak self] result in
            switch result {
            case .success:
                NSLog("[BeAroundSDK] Device register succeeded — persisting lastSentAt + fingerprint")
                RegisterStore.markRegistered(fingerprint: fingerprint)
                PushTokenStore.markSent(userDevice.pushToken)
            case .failure(let error):
                NSLog("[BeAroundSDK] Device register failed: %@ — will retry on next startScanning()", error.localizedDescription)
                DiagnosticsStore.shared.recordError("register: \(error.localizedDescription)")
                ErrorReporter.shared.report(error, context: "register")
                // Surface the failure to the host app. Previously this died in NSLog, so an
                // integrator with a bad token / offline device saw scanning "succeed" while the
                // device never appeared in the Control Hub, with no programmatic signal.
                DispatchQueue.main.async {
                    self?.delegate?.didFailWithError(error)
                }
            }
        }
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
                self?.requestSync(reason: "precision_high_timer")
            }
            timer.resume()

            NSLog("[BeAroundSDK] Precision HIGH: continuous scan, sync every %.0fs", config.syncInterval)
            return
        }

        // .medium / .low: continuous scan + sync timer. The old pseudo-duty-cycle
        // (resumeScanning/pauseScanning chained via un-cancellable asyncAfter closures)
        // fought the v2.6 always-registered-scan doctrine, and its orphan closures kept
        // firing after stopScanning(). iOS already duty-cycles a registered scan for
        // power; the SDK only needs the sync cadence.
        let cycleInterval = config.precisionCycleInterval
        bluetoothManager.resumeScanning()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        syncTimer = timer
        timer.schedule(deadline: .now() + cycleInterval, repeating: cycleInterval)
        timer.setEventHandler { [weak self] in
            self?.requestSync(reason: "precision_\(precision.rawValue)_timer")
        }
        timer.resume()

        NSLog("[BeAroundSDK] Precision %@: continuous scan, sync every %.0fs", precision.rawValue, cycleInterval)
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
            maxAge = config.syncInterval * 2
        } else {
            maxAge = 60.0
        }

        let now = Date()
        var removedCount = 0

        for (key, beacon) in collectedBeacons {
            if beacon.alreadySynced {
                // Synced entries used to be skipped, pointing at a "10s delayed cleanup"
                // that no longer exists — so every beacon ever synced stayed in the dict
                // until stopScanning() (unbounded growth as the device visits zones, and
                // the whole array is copied to the delegate on every emission). Retention
                // matches the Android SDK's 30s post-sync removal.
                let syncedAt = beacon.syncedAt ?? beacon.timestamp
                if now.timeIntervalSince(syncedAt) > Self.syncedBeaconRetention {
                    collectedBeacons.removeValue(forKey: key)
                    removedCount += 1
                }
                continue
            }
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
        let bleTracked = bluetoothManager.trackedBeaconsSnapshot()
        guard !bleTracked.isEmpty else { return }

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

    // MARK: - Sync coordinator
    //
    // Every hot trigger funnels through requestSync() on beaconQueue (serial), fixing
    // the uncoordinated-trigger family from the field review: a request landing during
    // an in-flight upload is QUEUED (not lost), timer and detection share one throttle
    // (no more double upload 1 s apart), and the foreground fast-path/background batch
    // window give low latency without duplicate payloads.
    private var syncPendingAfterCurrent = false
    private var pendingSyncReasons: Set<String> = []
    private var lastSyncFireAt: Date?
    private var coordinatorScheduled = false
    private var bgBatchWorkItem: DispatchWorkItem?

    /// Monotonic id of the in-flight sync — lets the stuck-sync watchdog release
    /// only ITS generation (a fresh sync must never be killed by an old timer).
    private var syncGeneration = 0
    /// The completion can simply never arrive while the process is suspended
    /// (background-session upload deferred by the system). Without a watchdog,
    /// `isSyncing` stays true forever and freezes every future sync of this
    /// process — the whole ingest pipeline hangs on one upload.
    private let syncWatchdogTimeout: TimeInterval = 45.0
    /// Callers holding a system execution window (BGTask / silent push) park a
    /// waiter here to give the window back only after the upload settles.
    private var syncSettledWaiters: [(id: UUID, callback: (Bool) -> Void)] = []

    /// beaconQueue only. Parks a waiter; on timeout it resolves `true` (the batch
    /// was persisted + handed to the background session — delivery is eventual).
    private func onSyncSettled(timeout: TimeInterval, _ callback: @escaping (Bool) -> Void) {
        let id = UUID()
        syncSettledWaiters.append((id: id, callback: callback))
        beaconQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            if let idx = self.syncSettledWaiters.firstIndex(where: { $0.id == id }) {
                let waiter = self.syncSettledWaiters.remove(at: idx)
                NSLog("[BeAroundSDK] Sync-settled waiter timed out after %.0fs — releasing window", timeout)
                waiter.callback(true)
            }
        }
    }

    /// beaconQueue only. Resolves every parked waiter with the sync outcome.
    private func notifySyncSettled(success: Bool) {
        guard !syncSettledWaiters.isEmpty else { return }
        let waiters = syncSettledWaiters
        syncSettledWaiters.removeAll()
        waiters.forEach { $0.callback(success) }
    }
    /// Foreground fast-path floor: a dirty sample may trigger an upload this soon after
    /// the previous one (HIGH). The 15 s precision timer remains as the fallback tick.
    /// P11 — the fast-path floor scales with the configured precision: MEDIUM/LOW
    /// hosts chose economy, so dirty samples must not drive HIGH-like cadence.
    /// FOREGROUND ONLY: the background path (1s batch window + detection-driven
    /// flush) is the delivery fix validated in the field and stays untouched.
    private var foregroundMinimumSyncInterval: TimeInterval {
        switch configuration?.scanPrecision {
        case .high: return 5.0
        case .medium: return 20.0
        case .low: return 60.0
        case .none: return 5.0
        }
    }
    /// Background: real callbacks open a short batch window, collect everything that
    /// arrives, then upload once — work fast and return, per Apple's bg guidance.
    private let backgroundBatchWindow: TimeInterval = 1.0

    /// Single entry point for every sync trigger.
    func requestSync(reason: String) {
        beaconQueue.async { [weak self] in
            guard let self else { return }
            self.pendingSyncReasons.insert(reason)

            if self.isSyncing {
                // Don't lose it: fire again right after the current upload finishes.
                self.syncPendingAfterCurrent = true
                return
            }
            if self.coordinatorScheduled { return }

            if self.isInBackground {
                // Short batch window: coalesce the burst from one wake, send once.
                self.coordinatorScheduled = true
                let work = DispatchWorkItem { [weak self] in self?.coordinatorFire() }
                self.bgBatchWorkItem = work
                self.beaconQueue.asyncAfter(deadline: .now() + self.backgroundBatchWindow, execute: work)
                return
            }

            // Foreground: honor the fast-path floor.
            let sinceLast = self.lastSyncFireAt.map { Date().timeIntervalSince($0) } ?? .infinity
            if sinceLast >= self.foregroundMinimumSyncInterval {
                self.coordinatorFire()
            } else {
                self.coordinatorScheduled = true
                let wait = self.foregroundMinimumSyncInterval - sinceLast
                self.beaconQueue.asyncAfter(deadline: .now() + wait) { [weak self] in
                    self?.coordinatorFire()
                }
            }
        }
    }

    /// Runs on beaconQueue. Consumes the pending reasons and starts one sync.
    private func coordinatorFire() {
        coordinatorScheduled = false
        bgBatchWorkItem = nil
        guard !pendingSyncReasons.isEmpty else { return }
        guard !isSyncing else { syncPendingAfterCurrent = true; return }
        let reasons = pendingSyncReasons.sorted().joined(separator: "+")
        pendingSyncReasons.removeAll()
        lastSyncFireAt = Date()
        syncTrigger = reasons   // written ONLY here on beaconQueue — the old cross-queue race is gone for coordinated paths
        syncBeacons()
    }

    /// Called wherever isSyncing returns to false: fires the queued follow-up so a
    /// sample that arrived mid-upload is never lost.
    /// Attaches encounter-mesh data (peer sightings + this device's rotating identifiers)
    /// to an outgoing payload. No-op before the mesh spins up (e.g. Bluetooth denied) —
    /// the fields stay empty and the payload builder omits them.
    private func attachEncounterData(to userDevice: inout UserDevice) {
        guard let mesh = bluetoothManager.encounterMesh else { return }
        userDevice.encounters = mesh.snapshotEncounters()
        userDevice.encounterIds = mesh.currentEncounterIds()
    }

    private func syncDidFinishCoordination() {
        beaconQueue.async { [weak self] in
            guard let self, self.syncPendingAfterCurrent else { return }
            self.syncPendingAfterCurrent = false
            self.coordinatorFire()
        }
    }

    /// Dirty check: is this callback a NEW business sample, or a repeat of what the
    /// backend already knows? New = enough time passed OR the signal moved OR the
    /// metadata changed. Repeats stay under the 60 s re-report umbrella.
    private let dirtyMinimumInterval: TimeInterval = 5.0
    private let dirtyMinimumRSSIDelta: Int = 3
    private func sampleIsDirty(existing: Beacon?, newRSSI: Int, newMetadata: BeaconMetadata?) -> Bool {
        guard let existing else { return true }
        if let syncedAt = existing.syncedAt, Date().timeIntervalSince(syncedAt) >= dirtyMinimumInterval,
           abs(existing.rssi - newRSSI) >= dirtyMinimumRSSIDelta { return true }
        if existing.metadata?.batteryLevel != newMetadata?.batteryLevel { return true }
        return false
    }

    /// Sampling + volume containment: a beacon already synced stays "synced" until
    /// [sampleReportInterval] has elapsed since syncedAt — then it becomes eligible again.
    private func pendingStateForSample(existing: Beacon?) -> (alreadySynced: Bool, syncedAt: Date?) {
        guard let existing, let syncedAt = existing.syncedAt else { return (false, existing?.syncedAt) }
        let withinWindow = Date().timeIntervalSince(syncedAt) < Self.sampleReportInterval
        return (existing.alreadySynced && withinWindow, syncedAt)
    }

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
                        !$0.alreadySynced && ($0.rssi != 0 || $0.discoverySources.contains(.coreLocation))
                    }
                    guard hasValidBeacon else {
                        NSLog("[BeAroundSDK] First-valid-beacon probe (%.1fs): no valid beacon yet", delay)
                        return
                    }
                    NSLog("[BeAroundSDK] First-valid-beacon probe (%.1fs): valid beacon present — syncing", delay)
                    // Debounced so the two probes (and a concurrent t+25s sync) don't double-fire.
                    self.requestSync(reason: "first_valid_beacon")
                }
            }
        }
    }


    private func syncBeacons() {
        beaconQueue.async { [weak self] in
            guard let self else { return }

            guard !isSyncing else {
                // Queue, don't drop: the coordinator fires again after the current upload.
                self.syncPendingAfterCurrent = true
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
                beaconsToSend = Array(collectedBeacons.values).filter { !$0.alreadySynced && ($0.rssi != 0 || $0.discoverySources.contains(.coreLocation)) }
                NSLog("[BeAroundSDK] Syncing %d of %d beacons (pending only)", beaconsToSend.count, collectedBeacons.count)
            }

            guard !beaconsToSend.isEmpty else {
                NSLog("[BeAroundSDK] No new beacons to sync")
                // No new beacons — drain retry queue if pending batches exist
                if self.shouldRetryFailedBatches() {
                    // The drain resolves the settled-waiters at ITS terminals.
                    self.drainRetryQueue()
                } else {
                    // P18 — nothing to send and nothing to drain: release any parked
                    // BGTask/push waiters NOW instead of letting them burn their
                    // full timeout window.
                    self.notifySyncSettled(success: true)
                }
                self.syncDidFinishCoordination()
                return
            }

            // Acquire the background assertion ONLY when there is a real batch to send
            // — the previous top-of-function acquisition burned begin/end cycles on
            // every empty tick (expensive at higher cadences).
            self.beginBackgroundTask()

            isSyncing = true
            let beaconCount = beaconsToSend.count

            // Stuck-sync watchdog: if the completion hasn't arrived in time
            // (suspended process, deferred background upload), release the lock so
            // the NEXT detection can sync — the persisted batch keeps this one safe.
            syncGeneration += 1
            let watchdogGeneration = syncGeneration
            beaconQueue.asyncAfter(deadline: .now() + syncWatchdogTimeout) { [weak self] in
                guard let self, self.isSyncing, self.syncGeneration == watchdogGeneration else { return }
                NSLog("[BeAroundSDK] Sync watchdog: releasing isSyncing after %.0fs (upload still pending — batch persisted)", self.syncWatchdogTimeout)
                self.isSyncing = false
                self.endBackgroundTask()
                self.notifySyncSettled(success: false)
                self.syncDidFinishCoordination()
            }

            // Fix 3 — Persist-before-send: durably store this batch BEFORE the upload so the
            // detection survives app suspension/termination. On a SUCCESSFUL completion we
            // remove exactly this batch; on failure we leave it for retry. This is the safety
            // net that guarantees eventual delivery even if the completion arrives after the
            // app has been relaunched. `persistedBatchId` is the on-disk filename of the batch.
            let persistedBatchId = self.offlineBatchStorage.saveBatchReturningId(beaconsToSend)
            // P20 — persist-before-send failed (disk full / data protection / no App
            // Support dir): the upload still goes out — blocking it would guarantee
            // the loss the persistence exists to prevent — but the durability gap is
            // real (a crash mid-upload loses this batch), so make it VISIBLE.
            if persistedBatchId == nil {
                NSLog("[BeAroundSDK] WARNING: persist-before-send failed — batch flies without a durable copy")
                DiagnosticsStore.shared.recordError("persist-before-send failed (\(beaconCount) beacons unprotected)")
                ErrorReporter.shared.report(
                    NSError(domain: "BeAroundSDK", code: BearoundErrorCode.storageFailure.rawValue,
                            userInfo: [NSLocalizedDescriptionKey: "persist-before-send returned nil"]),
                    context: "syncBeacons.persist"
                )
            }

            // Notify delegate that sync is starting
            DispatchQueue.main.async {
                self.delegate?.willStartSync(beaconCount: beaconCount)
            }

            let locationPermission = Self.authorizationStatus()
            let bluetoothState = bluetoothManager.isPoweredOn ? "powered_on" : "powered_off"
            let appInForeground = !isInBackground

            var userDevice = deviceInfoCollector.collectDeviceInfo(
                locationPermission: locationPermission,
                bluetoothState: bluetoothState,
                appInForeground: appInForeground
            )
            attachEncounterData(to: &userDevice)

            let trigger = self.syncTrigger
            self.syncTrigger = "unknown"

            apiClient.sendBeacons(
                beaconsToSend,
                sdkInfo: sdkInfo,
                userDevice: userDevice,
                userProperties: userProperties,
                syncTrigger: trigger,
                delivery: .immediateFirst,
                persistedBatchIds: persistedBatchId.map { [$0] } ?? []
            ) { [weak self] result in
                guard let self else { return }

                switch result {
                case .success:
                    NSLog("[BeAroundSDK] Sync SUCCESS")

                    // Fix 3 — batch delivered: drop the persisted copy so it is never re-sent.
                    // Reconciliation is valid even for a STALE completion (the upload really
                    // finished) — everything below it that touches current sync state is not.
                    if let persistedBatchId {
                        self.offlineBatchStorage.removeBatch(id: persistedBatchId)
                    }

                    // Record to the internal detection log (diagnostic only — no user-facing
                    // notification). The host app reacts to didCompleteSync if it wants one.
                    DetectionLogStore.append(type: "Sync OK", detail: "\(beaconCount) beacon(s) enviados ao ingester")

                    // Push token rode along in this payload and was accepted — record the
                    // heartbeat baseline for EXACTLY the token that was sent.
                    PushTokenStore.markSent(userDevice.pushToken)
                    DiagnosticsStore.shared.recordSync(success: true, beaconCount: beaconCount)

                    // Notify delegate of successful sync
                    DispatchQueue.main.async {
                        self.delegate?.didCompleteSync(beaconCount: beaconCount, success: true, error: nil)
                    }

                    // Build list of synced beacon keys before entering the queue
                    let syncedKeys = beaconsToSend.map { "\($0.major).\($0.minor)" }

                    // Mark synced + reset isSyncing in a SINGLE beaconQueue block to prevent race conditions
                    beaconQueue.async {
                        // P2 — stale-completion guard: if the watchdog already released
                        // THIS generation and a newer sync started, this late completion
                        // must not touch the new sync's state (isSyncing/assertion/waiters).
                        guard self.syncGeneration == watchdogGeneration else {
                            NSLog("[BeAroundSDK] Stale sync completion (gen %d, current %d) — state untouched", watchdogGeneration, self.syncGeneration)
                            return
                        }
                        self.endBackgroundTask()
                        self.isSyncing = false
                        self.notifySyncSettled(success: true)
                        self.syncDidFinishCoordination()
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

                        // (Removed) The 10 s post-sync removal recreated every parked beacon
                        // as "new and unsynced" on its next advertisement → perpetual re-sync.
                        // Entries now stay in collectedBeacons and re-report at most once per
                        // sampleReportInterval (see pendingStateForSample).

                        // Drain retry queue after new beacons synced
                        if self.shouldRetryFailedBatches() {
                            self.drainRetryQueue()
                        }
                    }

                case .failure(let error):
                    NSLog("[BeAroundSDK] Sync FAILED: %@", error.localizedDescription)

                    // Record to the internal detection log (diagnostic only — no user-facing
                    // notification). The host app reacts to didCompleteSync if it wants one.
                    DetectionLogStore.append(type: "Sync falhou", detail: "\(beaconCount) beacon(s) · \(error.localizedDescription)")

                    DiagnosticsStore.shared.recordSync(success: false, beaconCount: beaconCount)
                    DiagnosticsStore.shared.recordError(error.localizedDescription)
                    ErrorReporter.shared.report(error, context: "syncBeacons")

                    // Notify delegate of failed sync
                    DispatchQueue.main.async {
                        self.delegate?.didCompleteSync(beaconCount: beaconCount, success: false, error: error)
                    }

                    beaconQueue.async {
                        // P2 — stale-completion guard (see success path).
                        guard self.syncGeneration == watchdogGeneration else {
                            NSLog("[BeAroundSDK] Stale sync failure completion (gen %d, current %d) — state untouched", watchdogGeneration, self.syncGeneration)
                            return
                        }
                        self.endBackgroundTask()
                        self.isSyncing = false
                        self.notifySyncSettled(success: false)
                        self.syncDidFinishCoordination()
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
                                code: BearoundErrorCode.syncCircuitOpen.rawValue,
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
    /// - Parameter singleBatchMode: send ONE batch per request. Entered after a chunk is
    ///   rejected with a permanent HTTP status: the chunk mixes several persisted batches,
    ///   so the poison one can't be identified — single mode isolates it (delivered ones
    ///   drain, the rejected one is quarantined) and the queue keeps moving.
    private func drainRetryQueue(singleBatchMode: Bool = false) {
        beaconQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isSyncing else {
                NSLog("[BeAroundSDK] Retry drain skipped — sync in progress")
                return
            }
            guard let apiClient = self.apiClient, let sdkInfo = self.sdkInfo else {
                self.notifySyncSettled(success: false)
                return
            }

            let totalPending = self.offlineBatchStorage.batchCount
            guard totalPending > 0 else {
                NSLog("[BeAroundSDK] Retry queue empty, nothing to drain")
                // P18 — release parked BGTask/push waiters instead of timing out.
                self.notifySyncSettled(success: true)
                return
            }

            // P7 — id-addressed drain: remove EXACTLY the batches this chunk sent,
            // not "the N oldest at removal time" (a save/expiry between load and
            // remove used to shift the window onto unsent batches).
            let chunkRecords = self.offlineBatchStorage.loadOldestBatchesWithIds(singleBatchMode ? 1 : Self.retryChunkSize)
            let chunkIds = chunkRecords.map { $0.id }
            let chunkCount = chunkRecords.count
            let beaconsToSend = chunkRecords.flatMap { $0.beacons }.filter { $0.rssi != 0 || $0.discoverySources.contains(.coreLocation) }

            guard !beaconsToSend.isEmpty else {
                // All beacons in this chunk had rssi=0, skip and try next
                self.offlineBatchStorage.removeBatches(ids: chunkIds)
                NSLog("[BeAroundSDK] Skipped %d empty retry batches", chunkCount)
                self.drainRetryQueue()
                return
            }

            self.isSyncing = true
            let beaconCount = beaconsToSend.count

            // Same stuck-sync watchdog as syncBeacons — without it, a drain upload
            // whose completion never arrives freezes the pipeline through this door.
            self.syncGeneration += 1
            let drainGeneration = self.syncGeneration
            self.beaconQueue.asyncAfter(deadline: .now() + self.syncWatchdogTimeout) { [weak self] in
                guard let self, self.isSyncing, self.syncGeneration == drainGeneration else { return }
                NSLog("[BeAroundSDK] Drain watchdog: releasing isSyncing after %.0fs (upload still pending — batches remain persisted)", self.syncWatchdogTimeout)
                self.isSyncing = false
                self.endBackgroundTask()
                self.notifySyncSettled(success: false)
                self.syncDidFinishCoordination()
            }

            NSLog("[BeAroundSDK] Retry drain: sending chunk of %d batches (%d beacons), %d total pending",
                  chunkCount, beaconCount, totalPending)

            self.beginBackgroundTask()

            DispatchQueue.main.async {
                self.delegate?.willStartSync(beaconCount: beaconCount)
            }

            let locationPermission = Self.authorizationStatus()
            let bluetoothState = self.bluetoothManager.isPoweredOn ? "powered_on" : "powered_off"
            let appInForeground = !self.isInBackground

            var userDevice = self.deviceInfoCollector.collectDeviceInfo(
                locationPermission: locationPermission,
                bluetoothState: bluetoothState,
                appInForeground: appInForeground
            )
            self.attachEncounterData(to: &userDevice)

            apiClient.sendBeacons(
                beaconsToSend,
                sdkInfo: sdkInfo,
                userDevice: userDevice,
                userProperties: self.userProperties,
                syncTrigger: "retry_drain",
                delivery: .immediateFirst,
                persistedBatchIds: chunkIds
            ) { [weak self] result in
                guard let self else { return }

                switch result {
                case .success:
                    NSLog("[BeAroundSDK] Retry chunk SUCCESS (%d batches, %d beacons)", chunkCount, beaconCount)

                    // Reconciliation is valid even for a stale completion: these
                    // exact batches were delivered, so remove exactly them (by id).
                    self.offlineBatchStorage.removeBatches(ids: chunkIds)

                    // Record to the internal detection log (diagnostic only — no user-facing notification).
                    DetectionLogStore.append(type: "Sync OK", detail: "\(beaconCount) beacon(s) enviados ao ingester")

                    // Record the heartbeat baseline for EXACTLY the token that was sent.
                    PushTokenStore.markSent(userDevice.pushToken)
                    DiagnosticsStore.shared.recordSync(success: true, beaconCount: beaconCount)

                    DispatchQueue.main.async {
                        self.delegate?.didCompleteSync(beaconCount: beaconCount, success: true, error: nil)
                    }

                    self.beaconQueue.async {
                        // P2 — stale-completion guard (drain generation).
                        guard self.syncGeneration == drainGeneration else {
                            NSLog("[BeAroundSDK] Stale drain completion (gen %d, current %d) — state untouched", drainGeneration, self.syncGeneration)
                            return
                        }
                        self.endBackgroundTask()
                        self.isSyncing = false
                        self.syncDidFinishCoordination()
                        self.consecutiveFailures = 0
                        self.lastFailureTime = nil

                        // Continue draining if more batches remain
                        if self.offlineBatchStorage.batchCount > 0 {
                            NSLog("[BeAroundSDK] %d retry batches remaining, continuing drain...", self.offlineBatchStorage.batchCount)
                            self.drainRetryQueue()
                        } else {
                            NSLog("[BeAroundSDK] All retry batches drained successfully")
                            // P18 — the whole backlog is delivered: release parked waiters.
                            self.notifySyncSettled(success: true)
                        }
                    }

                case .failure(let error):
                    NSLog("[BeAroundSDK] Retry chunk FAILED: %@ — drain stopped", error.localizedDescription)

                    // Record to the internal detection log (diagnostic only — no user-facing notification).
                    DetectionLogStore.append(type: "Sync falhou", detail: "\(beaconCount) beacon(s) · \(error.localizedDescription)")

                    DiagnosticsStore.shared.recordSync(success: false, beaconCount: beaconCount)
                    DiagnosticsStore.shared.recordError(error.localizedDescription)
                    ErrorReporter.shared.report(error, context: "drainRetryQueue")

                    DispatchQueue.main.async {
                        self.delegate?.didCompleteSync(beaconCount: beaconCount, success: false, error: error)
                        self.delegate?.didFailWithError(error)
                    }

                    // Head-of-line guard: classify the failure. A permanent HTTP status
                    // (payload/credential problem — an identical retry fails identically)
                    // must NOT park the whole queue behind the poison batch for 7 days.
                    var permanentStatus: Int?
                    if case APIError.httpError(let code, _) = error, Self.permanentHTTPCodes.contains(code) {
                        permanentStatus = code
                    }

                    self.beaconQueue.async {
                        // P2 — stale-completion guard (drain generation).
                        guard self.syncGeneration == drainGeneration else {
                            NSLog("[BeAroundSDK] Stale drain failure completion (gen %d, current %d) — state untouched", drainGeneration, self.syncGeneration)
                            return
                        }
                        self.endBackgroundTask()
                        self.isSyncing = false

                        if let status = permanentStatus {
                            // Backend reachable — not a transport failure for the breaker.
                            if chunkCount == 1 {
                                // This exact batch is the poison: quarantine it, keep draining.
                                let poisonId = chunkIds[0]
                                NSLog("[BeAroundSDK] Batch %@ permanently rejected (HTTP %d) — quarantining, drain continues", poisonId, status)
                                DiagnosticsStore.shared.recordError("Batch quarantined (HTTP \(status)): \(poisonId)")
                                DetectionLogStore.append(type: "Sync falhou", detail: "batch rejeitado pelo backend (HTTP \(status)) — quarentenado")
                                self.offlineBatchStorage.quarantineBatch(id: poisonId)
                                self.syncDidFinishCoordination()
                                self.drainRetryQueue()
                            } else {
                                // Several batches in one request — can't tell WHICH one is
                                // poison. Re-drain one batch per request to isolate it.
                                NSLog("[BeAroundSDK] Chunk of %d rejected permanently (HTTP %d) — switching to single-batch drain", chunkCount, status)
                                self.syncDidFinishCoordination()
                                self.drainRetryQueue(singleBatchMode: true)
                            }
                            return
                        }

                        // Transient (network/408/429/5xx): stop; workers/backoff retry later.
                        // P18 — the drain terminal must resolve parked waiters too.
                        self.notifySyncSettled(success: false)
                        self.syncDidFinishCoordination()
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

        // Install the APNs push swizzle EARLY — here, at launch (the host calls this from
        // didFinishLaunching). Otherwise the swizzle only installs inside configure(), which on
        // Flutter/RN arrives late (via the Dart/JS bridge); the APNs token and any cold-launch
        // silent push are delivered BEFORE that, so they'd be missed and the manual AppDelegate
        // wiring becomes mandatory. Installing it here makes the SDK behave 1:1 with the native
        // app, where configure() runs early. enableIfPossible() is idempotent (guarded by
        // `installed`), so configure() calling it again is a harmless no-op.
        PushTokenAutoCapture.enableIfPossible()
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

        // ORDER MATTERS: store the system handler (which also revives the background
        // session) BEFORE any other SDK restoration. autoConfigureFromStorage() can
        // touch the session too — if events drained before the handler was stored,
        // urlSessionDidFinishEvents found nil and the system assertion was never
        // released (the OS then penalizes the app's background budget).
        BackgroundSessionManager.shared.setSystemEventsCompletionHandler(completionHandler)

        // Now restore the rest of the SDK for a cold launch driven purely by these events.
        if configuration == nil {
            autoConfigureFromStorage()
        }
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
    ///
    /// **Every terminal of a background wake must write this** — see
    /// `recordBackgroundScanInfo`. A wake that returns without writing leaves the previous
    /// wake's snapshot in place, and the host reports a scan that never happened.
    public private(set) var lastBackgroundScanInfo: BackgroundScanInfo?

    /// Single writer for [lastBackgroundScanInfo]. Call on `beaconQueue`.
    ///
    /// Exists because the snapshot is read by the host *after* the wake completes: any path
    /// that finishes without writing hands the host a stale reading it cannot tell apart
    /// from a fresh one.
    private func recordBackgroundScanInfo(beaconsFound: Int, ingestStarted: Bool, pendingBatches: Int) {
        lastBackgroundScanInfo = BackgroundScanInfo(
            beaconsFound: beaconsFound,
            ingestStarted: ingestStarted,
            pendingBatches: pendingBatches
        )
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
            let beaconsFound = collectedBeacons.count
            let pendingBatches = offlineBatchStorage.batchCount
            let ingestStarted = hasBeacons || hasFailedBatches

            // Snapshot BEFORE syncBeacons() may clear collectedBeacons, so the host app can
            // read an accurate count in its completion handler.
            self.recordBackgroundScanInfo(
                beaconsFound: beaconsFound,
                ingestStarted: ingestStarted,
                pendingBatches: pendingBatches
            )
            DiagnosticsStore.shared.recordScan(beaconCount: beaconsFound)

            if ingestStarted {
                NSLog("[BeAroundSDK] Background sync: beacons=%d, failed=%d",
                      hasBeacons ? 1 : 0, hasFailedBatches ? 1 : 0)
                self.syncTrigger = trigger
                // Hold the system window until the upload settles: completing the
                // BGTask/push handler right after STARTING the sync let iOS suspend
                // the process with the POST still in flight (top-5 fix #1).
                self.onSyncSettled(timeout: 20.0) { delivered in
                    completion(delivered)
                }
                syncBeacons()
            } else {
                NSLog("[BeAroundSDK] Background sync: nothing to sync")
                completion(false)
            }
        }
    }

    /// Called by BGTaskScheduler / silent push — refreshes BLE scan, collects Service Data, then syncs.
    /// `bleScanDuration` is the MAX wait: we sync as soon as a beacon is captured, or when it elapses.
    public func performBackgroundBLERefreshAndSync(bleScanDuration: TimeInterval = 10.0, trigger: String = "bg_task", completion: @escaping (Bool) -> Void) {
        NSLog("[BeAroundSDK] BGTask: reconciliation (trigger=%@, maxWait=%.0fs)", trigger, bleScanDuration)

        // Clear the previous wake's snapshot before doing anything. beaconQueue is serial,
        // so this always lands before whichever terminal records the real outcome. Belt and
        // braces: should any future path forget to record, the host reads "nothing happened"
        // instead of an old scan's numbers — wrong in the safe direction.
        beaconQueue.async { [weak self] in
            self?.recordBackgroundScanInfo(beaconsFound: 0, ingestStarted: false, pendingBatches: 0)
        }

        // ── Reconciliation policy ─────────────────────────────────────────────
        // The task must complement the standing CoreBluetooth/CoreLocation
        // mechanisms, never fight them or the host's intent.
        //
        // 1. Host intent: if the host called stopScanning() (persisted intent is
        //    OFF), the task NEVER arms a scan — it only drains pending data.
        //    Ownership rule collapses to: when intent is ON, (re)arming the scan
        //    is legitimate RECOVERY of a client iOS dropped, and leaving it armed
        //    is the desired steady state; when intent is OFF we never start one,
        //    so there is nothing to hand back.
        // 2. Low Power Mode / serious+critical thermal state: never arm a NEW
        //    scan window (an already-healthy scan is left untouched) — at most
        //    synchronize what is already collected/persisted.
        let wantsScanning = SDKConfigStorage.loadIsScanning()
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let thermal = ProcessInfo.processInfo.thermalState
        let thermalConstrained = thermal == .serious || thermal == .critical
        let mayTouchScan = wantsScanning && !lowPower && !thermalConstrained

        if mayTouchScan {
            // Ensure BLE is scanning
            if !bluetoothManager.isScanning {
                bluetoothManager.autoStartIfAuthorized()
                NSLog("[BeAroundSDK] BGTask: BLE scan started (recovery — host intent is scanning)")
            } else {
                bluetoothManager.refreshScan()
                NSLog("[BeAroundSDK] BGTask: BLE scan refreshed")
            }
        } else {
            NSLog("[BeAroundSDK] BGTask: synchronize-only (intent=%d lowPower=%d thermal=%d) — no scan window",
                  wantsScanning ? 1 : 0, lowPower ? 1 : 0, thermalConstrained ? 1 : 0)
            // No scan window → nothing new will appear; sync whatever exists NOW.
            beaconQueue.async { [weak self] in
                guard let self else {
                    completion(false)
                    return
                }
                let hasAnything = !self.collectedBeacons.isEmpty || self.offlineBatchStorage.batchCount > 0
                guard hasAnything else {
                    NSLog("[BeAroundSDK] BGTask: nothing to synchronize — completing")
                    // This terminal used to return without touching lastBackgroundScanInfo,
                    // leaving the PREVIOUS wake's snapshot in place: a device that had once
                    // seen 4 beacons kept reporting "4 beacons, uploading" on every wake for
                    // as long as this path was taken — nothing was scanned and nothing was
                    // sent. Record the truth of THIS wake instead.
                    self.recordBackgroundScanInfo(beaconsFound: 0, ingestStarted: false, pendingBatches: 0)
                    // ...and report it honestly: `false` means "no ingest was started", which
                    // the push handler maps to .noData. Answering .newData for a wake that
                    // uploaded nothing spends the app's push budget on nothing.
                    completion(false)
                    return
                }
                self.performBackgroundSync(trigger: trigger, completion: completion)
            }
            return
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
                restoreUserIdentityIfNeeded()
                if #available(iOS 13.0, *) {
                    BackgroundTaskManager.shared.applyPeriodicConfiguration(
                        enabled: savedConfig.periodicReconciliationEnabled,
                        interval: savedConfig.periodicReconciliationInterval,
                        scanDuration: savedConfig.periodicScanDuration
                    )
                }
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

    /// Acquires the terminated-relaunch window assertion (see [relaunchWindowTaskId]).
    private func beginRelaunchWindowTask() {
        let work = { [weak self] in
            guard let self, self.relaunchWindowTaskId == .invalid else { return }
            self.relaunchWindowTaskId = UIApplication.shared.beginBackgroundTask(withName: "BeAroundSDK-RelaunchWindow") { [weak self] in
                NSLog("[BeAroundSDK] Relaunch window expiring")
                self?.endRelaunchWindowTask()
            }
            NSLog("[BeAroundSDK] Relaunch window task started: %lu", self.relaunchWindowTaskId.rawValue)
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    }

    private func endRelaunchWindowTask() {
        DispatchQueue.main.async { [weak self] in
            guard let self, relaunchWindowTaskId != .invalid else { return }
            NSLog("[BeAroundSDK] Relaunch window task ended: %lu", relaunchWindowTaskId.rawValue)
            UIApplication.shared.endBackgroundTask(relaunchWindowTaskId)
            relaunchWindowTaskId = .invalid
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
            cacheMetadata(metadata, for: key)
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
            let existingSample = self.collectedBeacons[key]
            if self.sampleIsDirty(existing: existingSample, newRSSI: beacon.rssi, newMetadata: beacon.metadata) {
                beacon.syncedAt = existingSample?.syncedAt
                beacon.alreadySynced = false
            } else {
                let pending = self.pendingStateForSample(existing: existingSample)
                beacon.syncedAt = pending.syncedAt
                beacon.alreadySynced = pending.alreadySynced
            }
            self.collectedBeacons[key] = beacon
        }
    }

    func didUpdateBluetoothState(isPoweredOn: Bool) {
        if !isPoweredOn {
            NSLog("[BeAroundSDK] Bluetooth powered off")
        }
        refreshLocationOnlyRangingMode()
    }

    /// CL-only fallback wiring: when the app has no usable Bluetooth (permission
    /// denied/restricted or radio off), the BLE eye is dead — hand steady-state
    /// ranging to the Location eye so a Location-only permission profile still
    /// captures beacons. Re-evaluated on every CB state/authorization change.
    private func refreshLocationOnlyRangingMode() {
        var bluetoothUsable = bluetoothManager.isPoweredOn
        if #available(iOS 13.1, *) {
            let auth = CBCentralManager.authorization
            if auth == .denied || auth == .restricted { bluetoothUsable = false }
        }
        let fallback = !bluetoothUsable
        if beaconManager.rangeWhenBluetoothUnavailable != fallback {
            beaconManager.rangeWhenBluetoothUnavailable = fallback
            NSLog("[BeAroundSDK] CL-only ranging fallback %@ (bluetoothUsable=%d)",
                  fallback ? "ENABLED" : "disabled", bluetoothUsable ? 1 : 0)
            // Entering the fallback while already inside the region: kick ranging now
            // instead of waiting for the next region transition.
            if fallback, beaconManager.isInBeaconRegion {
                beaconManager.startRangingIfNeeded()
            } else if !fallback {
                // Bluetooth voltou: o ranging do fallback deixa de ter dono — parar
                // apenas se foi o fallback que o iniciou (RangingOwner), devolvendo o
                // tracking ao BLE eye sem matar um ranging de cold-start em andamento.
                beaconManager.stopFallbackRanging()
            }
        }
    }
}
