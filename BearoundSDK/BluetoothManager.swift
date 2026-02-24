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
    }

    @objc private func appWillEnterForeground() {
        isInBackground = false
    }

    // MARK: - Public Methods

    func startScanning() {
        os_log("[BLE] startScanning() — state=%{public}ld isScanning=%{public}d", log: bleLog, type: .info, centralManager.state.rawValue, isScanning ? 1 : 0)
        guard centralManager.state == .poweredOn else {
            os_log("[BLE] BLOCKED: state=%{public}ld (not poweredOn)", log: bleLog, type: .error, centralManager.state.rawValue)
            return
        }

        guard !isScanning else {
            os_log("[BLE] BLOCKED: already scanning", log: bleLog, type: .info)
            return
        }

        isScanning = true
        beginScan()
        startCleanupTimer()
        os_log("[BLE] startScanning() SUCCESS", log: bleLog, type: .info)
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
        guard isScanning else { return }

        isScanning = false
        pendingAutoStart = false
        centralManager.stopScan()
        stopCleanupTimer()
        lastSeenBeacons.removeAll()
        trackedBeacons.removeAll()

        print("[BluetoothManager] Stopped BLE scanning")
    }

    /// Force restart BLE scan to get fresh Service Data (e.g. on unlock/display events)
    func refreshScan() {
        guard isScanning, centralManager.state == .poweredOn else { return }
        centralManager.stopScan()
        beginScan()
        NSLog("[BluetoothManager] Refreshed BLE scan for Service Data (unlock event)")
    }

    /// Temporarily pause BLE scanning (duty cycle control)
    func pauseScanning() {
        guard isScanning, centralManager.state == .poweredOn else { return }
        centralManager.stopScan()
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
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        NSLog("[BluetoothManager] State restoration triggered")

        // Check if we were scanning when the app was terminated
        // Only set pendingAutoStart — don't set isScanning to true yet,
        // otherwise startScanning() guard will block the actual beginScan() call
        if let services = dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID],
           services.contains(beadServiceUUID) {
            pendingAutoStart = true
            NSLog("[BluetoothManager] Restored: was scanning for BEAD service UUID")
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
