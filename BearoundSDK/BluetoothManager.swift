//
//  BluetoothManager.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import CoreBluetooth
import Foundation

protocol BluetoothManagerDelegate: AnyObject {
    func didDiscoverBeacon(
        uuid: UUID,
        major: Int,
        minor: Int,
        rssi: Int,
        txPower: Int,
        metadata: BeaconMetadata?,
        isConnectable: Bool
    )
    func didUpdateBluetoothState(isPoweredOn: Bool)
}

class BluetoothManager: NSObject {
    weak var delegate: BluetoothManagerDelegate?

    private lazy var centralManager: CBCentralManager = {
        CBCentralManager(delegate: self, queue: nil)
    }()

    private let targetUUID = UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!
    private var isScanning = false

    private var lastSeenBeacons: [String: Date] = [:]
    private let deduplicationInterval: TimeInterval = 1.0

    /// track if we should auto start scanning when bluetooth is on
    private var pendingAutoStart = false

    var isPoweredOn: Bool {
        centralManager.state == .poweredOn
    }

    override init() {
        super.init()
        _ = centralManager
    }

    // MARK: - Public Methods

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            print("[BluetoothManager] Cannot start scanning - Bluetooth not powered on")
            return
        }

        guard !isScanning else {
            print("[BluetoothManager] Already scanning")
            return
        }

        isScanning = true

        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )

        print("[BluetoothManager] Started BLE scanning")
    }

    func stopScanning() {
        guard isScanning else { return }

        isScanning = false
        pendingAutoStart = false
        centralManager.stopScan()
        lastSeenBeacons.removeAll()

        print("[BluetoothManager] Stopped BLE scanning")
    }

    // MARK: - Auto-Enable

    /// Auto-starts Bluetooth scanning if permission is already granted
    /// This eliminates the need to manually call setBluetoothScanning(enabled: true)
    func autoStartIfAuthorized() {
        // Check Bluetooth authorization status (iOS 13.1+)
        if #available(iOS 13.1, *) {
            switch CBCentralManager.authorization {
            case .allowedAlways:
                // Permission granted, check if Bluetooth is powered on
                if centralManager.state == .poweredOn {
                    startScanning()
                } else {
                    // Will start when Bluetooth powers on
                    pendingAutoStart = true
                    print("[BluetoothManager] Auto-start pending - waiting for Bluetooth to power on")
                }
            case .notDetermined:
                // Triggering the centralManager above will prompt for permission
                // Set flag to auto-start once authorized
                pendingAutoStart = true
                print("[BluetoothManager] Bluetooth authorization not determined - waiting for user decision")
            case .denied, .restricted:
                print("[BluetoothManager] Bluetooth permission denied or restricted")
                pendingAutoStart = false
            @unknown default:
                print("[BluetoothManager] Unknown Bluetooth authorization status")
                pendingAutoStart = false
            }
        } else {
            // iOS 12 - just check if Bluetooth is powered on
            if centralManager.state == .poweredOn {
                startScanning()
            } else {
                pendingAutoStart = true
                print("[BluetoothManager] Auto-start pending - waiting for Bluetooth to power on (iOS 12)")
            }
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

    private func parseBeaconMetadata(from name: String) -> BeaconMetadata? {
        guard name.hasPrefix("B:") else { return nil }

        let components = name.dropFirst(2).split(separator: "_")
        guard components.count >= 5 else { return nil }

        let firmware = String(components[0])
        guard let battery = Int(components[2]),
            let movements = Int(components[3]),
            let temperature = Int(components[4])
        else {
            return nil
        }

        return BeaconMetadata(
            firmwareVersion: firmware,
            batteryLevel: battery,
            movements: movements,
            temperature: temperature
        )
    }

    private func shouldProcessBeacon(uuid: UUID, major: Int, minor: Int) -> Bool {
        let key = "\(uuid.uuidString)-\(major)-\(minor)"

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
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let isPoweredOn = central.state == .poweredOn

        print("[BluetoothManager] Bluetooth state: \(central.state.rawValue)")
        delegate?.didUpdateBluetoothState(isPoweredOn: isPoweredOn)

        if isPoweredOn {
            if pendingAutoStart {
                pendingAutoStart = false

                // recheck for ios 13+
                if #available(iOS 13.1, *) {
                    if CBCentralManager.authorization == .allowedAlways {
                        startScanning()
                    }
                } else {
                    // ios 12
                    startScanning()
                }
            } else if isScanning {
                // this is to restart
                startScanning()
            }
        } else if !isPoweredOn, isScanning {
            isScanning = false
        }
    }

    func centralManager(
        _: CBCentralManager,
        didDiscover _: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard RSSI.intValue != 127, RSSI.intValue != 0 else { return }

        guard
            let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey]
                as? Data
        else {
            return
        }

        guard let beaconData = parseIBeaconData(from: manufacturerData) else {
            return
        }

        guard beaconData.uuid == targetUUID else {
            return
        }

        guard
            shouldProcessBeacon(
                uuid: beaconData.uuid, major: beaconData.major, minor: beaconData.minor)
        else {
            return
        }

        let isConnectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool ?? false

        var metadata: BeaconMetadata?
        if let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            if let parsedMetadata = parseBeaconMetadata(from: name) {
                metadata = BeaconMetadata(
                    firmwareVersion: parsedMetadata.firmwareVersion,
                    batteryLevel: parsedMetadata.batteryLevel,
                    movements: parsedMetadata.movements,
                    temperature: parsedMetadata.temperature,
                    txPower: beaconData.txPower,
                    rssiFromBLE: RSSI.intValue,
                    isConnectable: isConnectable
                )
            }
        }

        delegate?.didDiscoverBeacon(
            uuid: beaconData.uuid,
            major: beaconData.major,
            minor: beaconData.minor,
            rssi: RSSI.intValue,
            txPower: beaconData.txPower,
            metadata: metadata,
            isConnectable: isConnectable
        )
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
