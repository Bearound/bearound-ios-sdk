//
//  BeaconScanner.swift
//  beaconDetector
//
//  Created by Arthur Sousa on 15/06/25.
//

import Foundation
import CoreBluetooth

class BeaconScanner: NSObject, CBCentralManagerDelegate {
    
    //-------------------------------
    // MARK: - Initial config
    //-------------------------------
    
    //Internal variables
    private var isScanning: Bool
    private var cbManager: CBCentralManager!
    private var delegate: BeaconActionsDelegate
    
    init(delegate: BeaconActionsDelegate) {
        self.isScanning = false
        self.delegate = delegate
        super.init()
        self.cbManager = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.bearound.bluetoothCentral"
        ])
    }
    
    deinit {
        self.stopScanning()
    }
    
    //-------------------------------
    // MARK: - Access Functions
    //-------------------------------
    
    func startScanning() {
        self.isScanning = true
    }
    
    func stopScanning() {
        self.isScanning = false
    }
    
    //-------------------------------
    // MARK: - Bluetooth Central Manager
    //-------------------------------
    
    func getCBManagerState() -> CBManagerState {
        return cbManager.state
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        self.cbManager = central
        switch cbManager.state {
        case .poweredOn:
            self.cbManager.scanForPeripherals(
                withServices: nil,
                options: [
                    CBCentralManagerScanOptionAllowDuplicatesKey: true
                ]
            )
            print("[BeAroundSDK]: Bluetooth permission allowed")
        case .unauthorized:
            print("[BeAroundSDK]: Bluetooth permission denied")
        case .poweredOff:
            print("[BeAroundSDK]: Bluetooth is powered off")
        case .unsupported:
            print("[BeAroundSDK]: Decice does not support Bluetooth")
        default:
            break
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if let name = peripheral.name, name.hasPrefix("B:") {
            guard let major = BeaconParser().getMajor(name) else { return }
            guard let minor = BeaconParser().getMinor(name) else { return }
            let address = peripheral.identifier.uuidString
            let distance = BeaconParser().getDistanceInMeters(rssi: Float(truncating: RSSI))
            
            let beacon = Beacon(
                major: major,
                minor: minor,
                rssi: Int(truncating: RSSI),
                bluetoothName: name,
                bluetoothAddress: address,
                distanceMeters: distance,
                lastSeen: Date()
            )
            Task { @MainActor in
                self.delegate.updateBeaconList(beacon)
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        self.cbManager.scanForPeripherals(
            withServices: nil,
            options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: true
            ]
        )
    }
}
