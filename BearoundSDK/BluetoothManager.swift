//
//  BluetoothManager.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import CoreBluetooth
import Foundation
import os.log
#if canImport(UIKit)
    import UIKit
#endif

private let bleLog = OSLog(subsystem: "com.bearound.sdk", category: "BLE")

/// Public scan mode for the Bluetooth eye, exposed so host apps can render the
/// current power profile of the BLE scanner.
///
/// - Note: On iOS the underlying CB scan is **always registered and continuous** (iOS does its
///   own background power duty-cycling), so this is a UI/bookkeeping label over an always-on
///   scan — not a radio on/off switch. The two-eyes model treats the BT eye as event-driven:
///   it reports `.idle` by default and is promoted to `.active` by either a CLBeaconRegion enter
///   (Location eye) or a beacon hit.
public enum BluetoothScanMode: String {
    /// UI label: the eye is reporting "no zone activity". The CB scan filter stays registered
    /// with iOS the whole time; iOS keeps low-power scanning alive and wakes the process on a
    /// match. Near-zero battery — managed by iOS, not by stopping the radio.
    case idle
    /// Host receives detection callbacks at native cadence plus heartbeat ticks. Switched to on
    /// region entry, or on a beacon hit.
    case active
}

protocol BluetoothManagerDelegate: AnyObject {
    func didDiscoverBeacon(
        uuid: UUID,
        major: Int,
        minor: Int,
        rssi: Int,
        txPower: Int,
        metadata: BeaconMetadata?,
        isConnectable: Bool,
        discoverySource: BeaconDiscoverySource
    )
    func didUpdateBluetoothState(isPoweredOn: Bool)
}

struct TrackedBLEBeacon {
    let major: Int
    let minor: Int
    var rssi: Int
    var metadata: BeaconMetadata?
    var txPower: Int
    var lastSeen: Date
    var isConnectable: Bool
    var discoverySource: BeaconDiscoverySource
}

class BluetoothManager: NSObject {
    weak var delegate: BluetoothManagerDelegate?

    /// Dedicated background queue for CBCentralManager — ensures callbacks are delivered
    /// even when the app is suspended (with bluetooth-central background mode)
    private let bleQueue = DispatchQueue(label: "com.bearound.sdk.bleQueue", qos: .utility)

    private static let restoreIdentifier = "com.bearound.sdk.centralManager"

    private lazy var centralManager: CBCentralManager = {
        CBCentralManager(
            delegate: self,
            queue: bleQueue,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: BluetoothManager.restoreIdentifier
            ]
        )
    }()

    private let targetUUID = UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!
    private let beadServiceUUID = CBUUID(string: "BEAD")
    private(set) var isScanning = false

    private var lastSeenBeacons: [String: Date] = [:]
    private let deduplicationInterval: TimeInterval = 1.0

    /// track if we should auto start scanning when bluetooth is on
    private var pendingAutoStart = false

    /// Tracks whether the app is in background for scan mode selection
    private var isInBackground: Bool = false

    /// When `true`, the BLE eye must NEVER demote its mode label from `.active` to `.idle` — it
    /// stays reported as continuously active for as long as it is running. (The radio itself is
    /// always registered and continuous regardless; this only governs the `.active`/`.idle` label
    /// and the active-mode heartbeat tick.)
    ///
    /// WHY: demoting to `.idle` is only safe when the **Location eye** (CoreLocation region
    /// monitoring) is available, because a region-enter promotes the eye back to `.active`
    /// instantly. When the SDK runs **Bluetooth-only** (Location authorization is neither
    /// `.authorizedAlways` nor `.authorizedWhenInUse`) there is NO waker — nothing promotes the
    /// eye back out of `.idle`, so the host would stop receiving active-mode callbacks until the
    /// next beacon hit. Staying `.active` keeps the heartbeat tick and zone callbacks flowing.
    ///
    /// Set by `BeAroundSDK` from the current Location authorization on `startScanning()` and on
    /// every authorization change. Defaults to `false` so the mode is allowed to fall back to
    /// `.idle` whenever Location IS authorized (region monitoring provides the instant wake-up there).
    var keepContinuousScanWhenBleOnly: Bool = false

    // MARK: - Beacon Tracking

    /// Grace period before removing a beacon (seconds)
    private let beaconGracePeriod: TimeInterval = 10.0

    /// Cleanup interval for expired beacons
    private let cleanupInterval: TimeInterval = 5.0

    /// Tracked beacons with last-seen timestamps
    private(set) var trackedBeacons: [String: TrackedBLEBeacon] = [:]

    /// Timer to periodically clean up expired beacons
    private var cleanupTimer: DispatchSourceTimer?

    /// Called when tracked beacons list changes (add/remove/update)
    var onBeaconsUpdated: (([TrackedBLEBeacon]) -> Void)?

    // MARK: - BLE-only Zone Detection (v2.5)
    //
    // Independent of CoreLocation region monitoring. Drives the "Bluetooth eye":
    //  - Rising edge: first beacon seen while currentlyInZone == false → onBluetoothZoneEnter
    //  - Falling edge: zoneExitGracePeriod elapses with no beacon seen → onBluetoothZoneExit
    //
    // The grace period absorbs transient RSSI dropouts so the zone state doesn't flicker.

    /// True when the BLE eye currently sees the device inside a beacon zone.
    private(set) var isInBluetoothZone: Bool = false

    /// How long the BLE eye waits without any beacon detection before declaring "zone exited".
    /// Long enough to absorb RSSI dropouts and BLE-radio gaps while the user stays in the
    /// zone. Increased from 10s → 60s after observing flicker (enter/exit ping-pong with
    /// the device stationary). 60s aligns with CoreLocation region monitoring cadence.
    private let zoneExitGracePeriod: TimeInterval = 60.0

    /// Timer that checks tracked beacons and flips the zone state when grace expires.
    private var zonePresenceTimer: DispatchSourceTimer?

    /// Tick interval for the zone-presence evaluator.
    private let zonePresenceTickInterval: TimeInterval = 2.0

    /// Fires once when the BLE eye sees a beacon and the zone was previously empty (rising edge).
    var onBluetoothZoneEnter: (() -> Void)?

    /// Fires once when the BLE eye has not seen any beacon for `zoneExitGracePeriod` (falling edge).
    var onBluetoothZoneExit: (() -> Void)?

    // MARK: - Duty Cycle (v2.6)
    //
    // The radio is ALWAYS registered with iOS and scans continuously — there is no app-level
    // idle peek anymore (iOS does its own background power duty-cycling). `currentScanMode` is
    // now a UI/bookkeeping label over that always-on scan, not a radio on/off switch:
    //   .idle   — UI label only. The CB scan filter stays registered; iOS keeps low-power
    //             scanning alive (and wakes the process on a match for terminated-app delivery).
    //   .active — host gets heartbeat ticks (`activeTickCadence`) and zone callbacks. Switched
    //             back to .idle (label only) when BLE sees no beacon for `activeToIdleGrace`,
    //             unless `keepContinuousScanWhenBleOnly` is set.

    /// Active mode "UI tick" cadence — host gets a heartbeat callback this often while active.
    /// Scanner stays continuously on; this is just for host-visible progress.
    private let activeTickCadence: TimeInterval = 10.0

    /// In active mode, after this many seconds without a single detection we fall back to idle.
    /// Longer than `zoneExitGracePeriod` (60s) because that one tracks zone presence, this one
    /// tracks "user has clearly walked away, time to save battery".
    private let activeToIdleGrace: TimeInterval = 120.0   // 2 min

    /// Current scan mode. Drives the duty cycle timer and the host-visible "Modo" display.
    private(set) var currentScanMode: BluetoothScanMode = .idle

    /// Absolute time at which the next idle peek will start. Nil when in active mode.
    private(set) var nextIdleScanAt: Date?

    /// Duty-cycle timer that drives idle peeks and the active-mode tick.
    private var dutyCycleTimer: DispatchSourceTimer?

    /// Fires whenever the BLE scan mode changes. `nextIdleScanAt` is non-nil only in `.idle`.
    var onScanModeChanged: ((BluetoothScanMode, Date?) -> Void)?

    var isPoweredOn: Bool {
        centralManager.state == .poweredOn
    }

    /// Diagnostic info for debugging BLE issues
    var diagnosticInfo: String {
        let state = centralManager.state.rawValue // 0=unknown,1=resetting,2=unsupported,3=unauthorized,4=poweredOff,5=poweredOn
        var btAuth = -1
        if #available(iOS 13.1, *) {
            btAuth = CBCentralManager.authorization.rawValue // 0=notDetermined,1=restricted,2=denied,3=allowedAlways
        }
        return "CBState=\(state) btAuth=\(btAuth) scanning=\(isScanning) pending=\(pendingAutoStart) tracked=\(trackedBeacons.count)"
    }

    override init() {
        super.init()
        _ = centralManager
        setupAppStateObservers()

        #if canImport(UIKit)
            isInBackground = UIApplication.shared.applicationState == .background
        #endif
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - App State Observers

    private func setupAppStateObservers() {
        #if canImport(UIKit)
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
        #endif
    }

    @objc private func appDidEnterBackground() {
        isInBackground = true
        // v2.5.1 — Promote to ACTIVE on background entry. If we go to background with the
        // scanner OFF (IDLE), iOS has nothing to preserve and BT-only wake-up dies. By
        // promoting here we hand iOS a running scan it can low-power until a BEAD match.
        if isScanning && currentScanMode == .idle {
            os_log("[BLE] app -> background: promoting IDLE -> ACTIVE for BT wake-up persistence", log: bleLog, type: .info)
            wakeToActive()
        }
    }

    @objc private func appWillEnterForeground() {
        isInBackground = false
        // No demotion here — the regular activeToIdleGrace will demote us back to IDLE
        // when beacons stop being seen. Foreground arrival itself doesn't change scan mode.
    }

    // MARK: - Public Methods

    /// Starts the BLE eye. v2.6: scan is **always** registered with iOS immediately
    /// (ACTIVE mode), regardless of foreground/background.
    ///
    /// Rationale: CoreBluetooth state preservation & restoration only works if a scan
    /// filter is active in the kernel at the moment the process is terminated. The
    /// previous design started in IDLE (scanner OFF) in foreground and only registered
    /// the filter 5 minutes later via the first idle peek — meaning a user who tapped
    /// Start and immediately swiped the app away (the dominant real-world pattern)
    /// would never get BT wake-up. iOS handles its own background duty-cycling for
    /// power; we don't need to layer a second one on top and risk breaking the wake-up.
    ///
    /// External wake-ups (Location eye region enter) call wakeToActive() which is now
    /// a no-op if already active — we're already in the right state.
    func startScanning() {
        os_log("[BLE] startScanning() — state=%{public}ld isScanning=%{public}d isInBackground=%{public}d",
               log: bleLog, type: .info, centralManager.state.rawValue, isScanning ? 1 : 0, isInBackground ? 1 : 0)
        guard centralManager.state == .poweredOn else {
            os_log("[BLE] BLOCKED: state=%{public}ld (not poweredOn)", log: bleLog, type: .error, centralManager.state.rawValue)
            return
        }

        guard !isScanning else {
            os_log("[BLE] BLOCKED: already scanning", log: bleLog, type: .info)
            return
        }

        isScanning = true
        startCleanupTimer()
        startZonePresenceTimer()

        // ALWAYS register the scan with iOS immediately. This is mandatory for
        // CBCentralManager state restoration to work — iOS must have an active scan
        // filter at the moment the process is terminated, otherwise willRestoreState
        // will never fire and the BT-only wake-up path is permanently dead.
        currentScanMode = .active
        nextIdleScanAt = nil
        beginScan()
        scheduleActiveTick()
        os_log("[BLE] startScanning() SUCCESS — ACTIVE mode (scan registered for wake-up persistence)", log: bleLog, type: .info)
        notifyScanModeChanged()
    }

    /// Restarts the active scan with the correct parameters for the current app state
    private func restartScan() {
        guard isScanning, centralManager.state == .poweredOn else { return }
        centralManager.stopScan()
        beginScan()
    }

    /// Starts the actual CoreBluetooth scan with BEAD Service UUID filter
    /// iOS delivers all advertisement data (including manufacturer data) for matched peripherals
    private func beginScan() {
        let allowDuplicates = true
        centralManager.scanForPeripherals(
            withServices: [beadServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
        )
        print("[BluetoothManager] Started BLE scanning (Service UUID BEAD, duplicates=\(allowDuplicates))")
    }

    func stopScanning() {
        // Always cancel any pending auto-start so a deferred BT power-on doesn't
        // sneak a scan back in after we asked to stop (e.g. after region exit).
        pendingAutoStart = false

        guard isScanning else { return }

        isScanning = false
        centralManager.stopScan()
        stopCleanupTimer()
        stopZonePresenceTimer()
        stopDutyCycleTimer()
        nextIdleScanAt = nil
        lastSeenBeacons.removeAll()
        trackedBeacons.removeAll()

        // When the BLE eye is shut off we surface a falling edge so consumers can
        // drop their "in zone" state — even though the cause is scan-stopped, not
        // "no beacons in range". Without this the UI would stay stuck on "in zone".
        if isInBluetoothZone {
            isInBluetoothZone = false
            onBluetoothZoneExit?()
        }

        // Surface the mode reset so the UI doesn't get stuck showing "ACTIVE" or
        // a stale countdown after the user explicitly stopped the SDK.
        if currentScanMode != .idle {
            currentScanMode = .idle
            notifyScanModeChanged()
        }

        print("[BluetoothManager] Stopped BLE scanning")
    }

    // MARK: - Duty Cycle Implementation (v2.5)

    /// External wake-up — called by the SDK facade when the Location eye reports
    /// region entry. Cancels any pending idle peek and switches to continuous scan.
    /// No-op if already active or if the BLE eye isn't running.
    func wakeToActive() {
        guard isScanning, currentScanMode != .active else { return }
        guard centralManager.state == .poweredOn else {
            os_log("[BLE] wakeToActive() blocked — state=%{public}ld", log: bleLog, type: .error, centralManager.state.rawValue)
            return
        }

        os_log("[BLE] WAKE TO ACTIVE — switching from .idle (region entry triggered)", log: bleLog, type: .info)
        currentScanMode = .active
        nextIdleScanAt = nil
        beginScan()
        scheduleActiveTick()
        notifyScanModeChanged()
    }

    /// External sleep — called by the SDK facade when the Location eye reports
    /// region exit. v2.6: this is now a **UI-only** mode change. The scanner stays
    /// registered with iOS so state restoration keeps working. Stopping the scan here
    /// (as we used to) would unregister the kernel filter and kill BT wake-up the
    /// moment the user wandered out of the zone.
    ///
    /// Also called internally when active mode sees no detections for `activeToIdleGrace`.
    func sleepToIdle() {
        guard isScanning, currentScanMode != .idle else { return }
        guard !isInBackground else {
            os_log("[BLE] sleepToIdle blocked — in background, staying ACTIVE", log: bleLog, type: .info)
            return
        }
        // BLE-only mode: never drop the label to .idle. Without the Location eye there is no
        // region-enter to promote us back to .active, so the host would stop getting active-mode
        // callbacks until the next beacon hit. Stay reported as active and keep the active tick
        // running. (The radio stays registered/continuous either way — this is label-only.)
        guard !keepContinuousScanWhenBleOnly else {
            os_log("[BLE] sleepToIdle blocked — BLE-only (no region-monitoring waker), staying ACTIVE", log: bleLog, type: .info)
            return
        }

        os_log("[BLE] SLEEP TO IDLE — UI label change only, scanner stays registered with iOS", log: bleLog, type: .info)
        currentScanMode = .idle
        // Do NOT call centralManager.stopScan() — that would unregister the filter and
        // break CB state restoration. iOS auto-duty-cycles the scan for us.
        nextIdleScanAt = nil
        stopDutyCycleTimer()
        notifyScanModeChanged()
    }

    /// Active mode tick — fires every `activeTickCadence` while in .active. Used to detect
    /// "no beacons for too long" (grace expired) and demote back to idle.
    private func scheduleActiveTick() {
        stopDutyCycleTimer()

        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(deadline: .now() + activeTickCadence, repeating: activeTickCadence)
        timer.setEventHandler { [weak self] in
            self?.evaluateActiveGrace()
        }
        dutyCycleTimer = timer
        timer.resume()
    }

    /// Demotes to idle if no beacon has been detected for `activeToIdleGrace`. Called by
    /// the active-tick timer. Region exit from the Location eye triggers sleepToIdle()
    /// directly, bypassing this grace.
    /// v2.5.1: in background, never demote — keep scanner alive for iOS BT wake-up.
    private func evaluateActiveGrace() {
        guard currentScanMode == .active else { return }
        guard !isInBackground else { return }  // background: don't demote, sleepToIdle() blocks too
        // BLE-only: never demote. The repeating active tick keeps itself scheduled, so we
        // simply skip the grace check and stay .active. (See keepContinuousScanWhenBleOnly.)
        guard !keepContinuousScanWhenBleOnly else { return }

        let now = Date()
        let lastSeen = trackedBeacons.values.map(\.lastSeen).max()

        if let last = lastSeen, now.timeIntervalSince(last) < activeToIdleGrace {
            return  // recent detection, stay active
        }

        // Either we never saw anything in active mode, or grace expired.
        os_log("[BLE] active grace expired — falling back to idle", log: bleLog, type: .info)
        sleepToIdle()
    }

    private func stopDutyCycleTimer() {
        dutyCycleTimer?.cancel()
        dutyCycleTimer = nil
    }

    /// Dispatches the mode change to the main queue. Host UI updates via Combine
    /// should not block the BLE serial queue.
    private func notifyScanModeChanged() {
        let mode = currentScanMode
        let next = nextIdleScanAt
        DispatchQueue.main.async { [weak self] in
            self?.onScanModeChanged?(mode, next)
        }
    }

    /// Force restart BLE scan to get fresh Service Data (e.g. on unlock/display events)
    func refreshScan() {
        guard isScanning, centralManager.state == .poweredOn else { return }
        centralManager.stopScan()
        beginScan()
        NSLog("[BluetoothManager] Refreshed BLE scan for Service Data (unlock event)")
    }

    /// v2.6: Pauses host-side bookkeeping only — the underlying CB scan stays
    /// registered with iOS so state restoration keeps working. The "pause" semantic
    /// was inherited from the SDK-level duty cycle which originally toggled both
    /// CoreLocation ranging AND the BLE scan. The BLE filter is cheap enough that
    /// pausing it offered no real battery win, but the cost was lethal — every pause
    /// unregistered the kernel filter and broke terminated-app wake-up. Now only the
    /// cleanup timer is paused; the scan keeps running.
    func pauseScanning() {
        guard isScanning, centralManager.state == .poweredOn else { return }
        // Do NOT call centralManager.stopScan() — see method docstring.
        stopCleanupTimer()
    }

    /// Resume BLE scanning after a pause
    func resumeScanning() {
        guard isScanning, centralManager.state == .poweredOn else { return }
        beginScan()
        startCleanupTimer()
    }

    // MARK: - Auto-Enable

    /// Auto-starts Bluetooth scanning if permission is already granted
    /// This eliminates the need to manually call setBluetoothScanning(enabled: true)
    func autoStartIfAuthorized() {
        if #available(iOS 13.1, *) {
            let btAuth = CBCentralManager.authorization
            os_log("[BLE] autoStartIfAuthorized() btAuth=%{public}ld state=%{public}ld isScanning=%{public}d pending=%{public}d",
                   log: bleLog, type: .info, btAuth.rawValue, centralManager.state.rawValue, isScanning ? 1 : 0, pendingAutoStart ? 1 : 0)
            switch btAuth {
            case .allowedAlways:
                if centralManager.state == .poweredOn {
                    startScanning()
                } else {
                    pendingAutoStart = true
                    os_log("[BLE] pending — BT not poweredOn (state=%{public}ld)", log: bleLog, type: .info, centralManager.state.rawValue)
                }
            case .notDetermined:
                pendingAutoStart = true
                os_log("[BLE] auth notDetermined — pending=true", log: bleLog, type: .info)
            case .denied, .restricted:
                os_log("[BLE] auth DENIED/RESTRICTED", log: bleLog, type: .error)
                pendingAutoStart = false
            @unknown default:
                os_log("[BLE] auth unknown (%{public}ld)", log: bleLog, type: .error, btAuth.rawValue)
                pendingAutoStart = false
            }
        } else {
            if centralManager.state == .poweredOn {
                startScanning()
            } else {
                pendingAutoStart = true
            }
        }
    }

    // MARK: - Beacon Tracking

    private func trackBeacon(major: Int, minor: Int, rssi: Int, txPower: Int, metadata: BeaconMetadata?, isConnectable: Bool, discoverySource: BeaconDiscoverySource) {
        let key = "\(major).\(minor)"
        var tracked = trackedBeacons[key] ?? TrackedBLEBeacon(
            major: major,
            minor: minor,
            rssi: rssi,
            metadata: metadata,
            txPower: txPower,
            lastSeen: Date(),
            isConnectable: isConnectable,
            discoverySource: discoverySource
        )

        tracked.rssi = rssi
        tracked.lastSeen = Date()
        tracked.isConnectable = isConnectable
        if let metadata {
            tracked.metadata = metadata
        }
        tracked.txPower = txPower
        // Upgrade to serviceUUID if applicable, never downgrade
        if discoverySource == .serviceUUID {
            tracked.discoverySource = .serviceUUID
        }

        trackedBeacons[key] = tracked
        onBeaconsUpdated?(Array(trackedBeacons.values))

        // Rising edge: any beacon seen flips the BLE eye to "in zone" if it was previously out.
        // Subsequent detections while in-zone are no-ops — the falling edge is timer-driven.
        if !isInBluetoothZone {
            isInBluetoothZone = true
            onBluetoothZoneEnter?()
        }

        // v2.5 duty-cycle promotion: a detection during an idle peek means the user is
        // actually in a zone, so we transition to active to maintain continuous visibility.
        if currentScanMode == .idle {
            os_log("[BLE] idle peek HIT — promoting to active", log: bleLog, type: .info)
            currentScanMode = .active
            nextIdleScanAt = nil
            // beginScan() already happened (we're inside its callback path); just rewire
            // the duty cycle from "peek-end timer" to "active tick".
            scheduleActiveTick()
            notifyScanModeChanged()
        }
    }

    private func startCleanupTimer() {
        stopCleanupTimer()

        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(deadline: .now() + cleanupInterval, repeating: cleanupInterval)
        timer.setEventHandler { [weak self] in
            self?.cleanupExpiredBeacons()
        }
        cleanupTimer = timer
        timer.resume()
    }

    private func stopCleanupTimer() {
        cleanupTimer?.cancel()
        cleanupTimer = nil
    }

    private func cleanupExpiredBeacons() {
        let now = Date()
        var didRemove = false

        for (key, beacon) in trackedBeacons {
            if now.timeIntervalSince(beacon.lastSeen) > beaconGracePeriod {
                trackedBeacons.removeValue(forKey: key)
                didRemove = true
            }
        }

        if didRemove {
            onBeaconsUpdated?(Array(trackedBeacons.values))
        }
    }

    // MARK: - Bluetooth Zone Presence (v2.5)

    /// Starts the timer that evaluates BLE-zone falling edges. The rising edge is event-driven
    /// (fired inline from `trackBeacon`); the falling edge needs a periodic check because the
    /// "no beacons in range" event has no native callback — it's the absence of detections.
    private func startZonePresenceTimer() {
        stopZonePresenceTimer()

        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(deadline: .now() + zonePresenceTickInterval, repeating: zonePresenceTickInterval)
        timer.setEventHandler { [weak self] in
            self?.evaluateZonePresence()
        }
        zonePresenceTimer = timer
        timer.resume()
    }

    private func stopZonePresenceTimer() {
        zonePresenceTimer?.cancel()
        zonePresenceTimer = nil
    }

    /// Called by the zone-presence timer. Flips `isInBluetoothZone` from true to false when
    /// no beacon has been seen for `zoneExitGracePeriod`. The rising edge is handled inline.
    private func evaluateZonePresence() {
        guard isInBluetoothZone else { return }

        let now = Date()
        let lastBeaconSeen = trackedBeacons.values.map(\.lastSeen).max()

        guard let last = lastBeaconSeen else {
            // No tracked beacons at all — cleanup already evicted them. Treat as zone exit.
            isInBluetoothZone = false
            onBluetoothZoneExit?()
            return
        }

        if now.timeIntervalSince(last) > zoneExitGracePeriod {
            isInBluetoothZone = false
            onBluetoothZoneExit?()
        }
    }

    // MARK: - Private Methods

    private func parseIBeaconData(from manufacturerData: Data) -> (
        uuid: UUID, major: Int, minor: Int, txPower: Int
    )? {
        guard manufacturerData.count >= 25 else { return nil }

        let companyID = manufacturerData.withUnsafeBytes {
            $0.load(fromByteOffset: 0, as: UInt16.self)
        }
        guard companyID == 0x004C else { return nil }

        guard manufacturerData[2] == 0x02, manufacturerData[3] == 0x15 else { return nil }

        let uuidData = manufacturerData.subdata(in: 4..<20)
        guard let uuid = UUID(data: uuidData) else { return nil }

        let major = Int(manufacturerData[20]) << 8 | Int(manufacturerData[21])

        let minor = Int(manufacturerData[22]) << 8 | Int(manufacturerData[23])

        let txPower = Int(Int8(bitPattern: manufacturerData[24]))

        return (uuid: uuid, major: major, minor: minor, txPower: txPower)
    }

    /// Parse BEAD Service Data (11 bytes LE) from advertisement data
    /// Returns (major, minor, metadata) or nil if not present/invalid
    private func parseBeadServiceData(from advertisementData: [String: Any], rssi: Int, isConnectable: Bool) -> (major: Int, minor: Int, metadata: BeaconMetadata)? {
        guard let serviceDataDict = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
              let data = serviceDataDict[beadServiceUUID],
              data.count >= 11 else {
            return nil
        }

        let firmware = UInt16(data[0]) | (UInt16(data[1]) << 8)
        let major = UInt16(data[2]) | (UInt16(data[3]) << 8)
        let minor = UInt16(data[4]) | (UInt16(data[5]) << 8)
        let motion = UInt16(data[6]) | (UInt16(data[7]) << 8)
        let temperature = Int8(bitPattern: data[8])
        let battery = UInt16(data[9]) | (UInt16(data[10]) << 8)

        let metadata = BeaconMetadata(
            firmwareVersion: String(firmware),
            batteryLevel: Int(battery),
            movements: Int(motion),
            temperature: Int(temperature),
            txPower: nil,
            rssiFromBLE: rssi,
            isConnectable: isConnectable
        )

        return (major: Int(major), minor: Int(minor), metadata: metadata)
    }

    private func shouldProcessBeacon(major: Int, minor: Int) -> Bool {
        let key = "\(major).\(minor)"

        if let lastSeen = lastSeenBeacons[key] {
            let timeSinceLastSeen = Date().timeIntervalSince(lastSeen)
            if timeSinceLastSeen < deduplicationInterval {
                return false
            }
        }

        lastSeenBeacons[key] = Date()
        return true
    }
}

extension BluetoothManager: CBCentralManagerDelegate {

    /// Called by iOS when the app is relaunched into background after being terminated.
    /// Restores the CBCentralManager state so BLE scanning can resume automatically.
    ///
    /// v2.5.1: state restoration means iOS just woke us up because of a BT advertisement
    /// match. We force `isInBackground = true` so the subsequent startScanning() enters
    /// ACTIVE mode (not IDLE) — otherwise we'd immediately stop the scanner iOS just
    /// handed back to us.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        NSLog("[BluetoothManager] State restoration triggered (BT wake-up path)")

        // The app was just relaunched into background by iOS. Reflect that explicitly so
        // startScanning() picks the right initial mode.
        isInBackground = true

        if let services = dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID],
           services.contains(beadServiceUUID) {
            pendingAutoStart = true
            NSLog("[BluetoothManager] Restored: was scanning for BEAD service UUID — will enter ACTIVE mode")
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let isPoweredOn = central.state == .poweredOn
        os_log("[BLE] didUpdateState state=%{public}ld poweredOn=%{public}d pending=%{public}d scanning=%{public}d",
               log: bleLog, type: .info, central.state.rawValue, isPoweredOn ? 1 : 0, pendingAutoStart ? 1 : 0, isScanning ? 1 : 0)
        delegate?.didUpdateBluetoothState(isPoweredOn: isPoweredOn)

        if isPoweredOn {
            if pendingAutoStart {
                pendingAutoStart = false

                if #available(iOS 13.1, *) {
                    let btAuth = CBCentralManager.authorization
                    os_log("[BLE] pending path — btAuth=%{public}ld", log: bleLog, type: .info, btAuth.rawValue)
                    if btAuth == .allowedAlways {
                        startScanning()
                    } else {
                        os_log("[BLE] BLOCKED: btAuth=%{public}ld (not allowedAlways)", log: bleLog, type: .error, btAuth.rawValue)
                    }
                } else {
                    startScanning()
                }
            } else if isScanning {
                os_log("[BLE] BT recovered — restarting scan", log: bleLog, type: .info)
                restartScan()
            } else {
                os_log("[BLE] poweredOn but idle (pending=false, scanning=false)", log: bleLog, type: .info)
            }
        } else if !isPoweredOn, isScanning {
            os_log("[BLE] powered off while scanning — isScanning=false", log: bleLog, type: .error)
            isScanning = false
        }
    }

    func centralManager(
        _: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        os_log("[BLE] didDiscover rssi=%{public}d", log: bleLog, type: .info, RSSI.intValue)
        guard RSSI.intValue != 127, RSSI.intValue != 0 else { return }

        let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool ?? false

        // PRIORITY 1: Service Data BEAD — has major, minor AND full metadata
        if let (major, minor, metadata) = parseBeadServiceData(from: advertisementData, rssi: RSSI.intValue, isConnectable: connectable) {
            let txPower = metadata.txPower ?? -59

            trackBeacon(major: major, minor: minor, rssi: RSSI.intValue, txPower: txPower, metadata: metadata, isConnectable: connectable, discoverySource: .serviceUUID)

            if shouldProcessBeacon(major: major, minor: minor) {
                delegate?.didDiscoverBeacon(
                    uuid: targetUUID,
                    major: major,
                    minor: minor,
                    rssi: RSSI.intValue,
                    txPower: txPower,
                    metadata: metadata,
                    isConnectable: connectable,
                    discoverySource: .serviceUUID
                )
            }
            return
        }

        // PRIORITY 2: iBeacon manufacturer data (0x004C) — major, minor only, no metadata
        // Fallback if scan response with Service Data hasn't arrived yet
        if let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           let beaconData = parseIBeaconData(from: manufacturerData),
           beaconData.uuid == targetUUID {

            trackBeacon(major: beaconData.major, minor: beaconData.minor, rssi: RSSI.intValue, txPower: beaconData.txPower, metadata: nil, isConnectable: connectable, discoverySource: .serviceUUID)

            if shouldProcessBeacon(major: beaconData.major, minor: beaconData.minor) {
                delegate?.didDiscoverBeacon(
                    uuid: beaconData.uuid,
                    major: beaconData.major,
                    minor: beaconData.minor,
                    rssi: RSSI.intValue,
                    txPower: beaconData.txPower,
                    metadata: nil,
                    isConnectable: connectable,
                    discoverySource: .serviceUUID
                )
            }
        }
    }
}

extension UUID {
    init?(data: Data) {
        guard data.count == 16 else { return nil }
        let uuid = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> uuid_t in
            return (
                ptr[0], ptr[1], ptr[2], ptr[3],
                ptr[4], ptr[5], ptr[6], ptr[7],
                ptr[8], ptr[9], ptr[10], ptr[11],
                ptr[12], ptr[13], ptr[14], ptr[15]
            )
        }
        self.init(uuid: uuid)
    }
}
