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
    private var debugger: DebuggerHelper
    
    init(delegate: BeaconActionsDelegate, debugger: DebuggerHelper) {
        self.isScanning = false
        self.delegate = delegate
        self.debugger = debugger
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
            debugger.defaultPrint("Bluetooth permission allowed")
        case .unauthorized:
            debugger.defaultPrint("Bluetooth permission denied")
        case .poweredOff:
            debugger.defaultPrint("Bluetooth is powered off")
        case .unsupported:
            debugger.defaultPrint("Device does not support Bluetooth")
        default:
            break
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard let name = peripheral.name, name.hasPrefix("B:") else { return }
        
        let rssiValue = Int(truncating: RSSI)
        guard rssiValue != 0 && rssiValue >= -120 && rssiValue <= -1 else {
            debugger.defaultPrint("Rejected beacon '\(name)' - Invalid RSSI: \(rssiValue)")
            return
        }
        
        guard let major = BeaconParser().getMajor(name) else {
            debugger.defaultPrint("Rejected beacon '\(name)' - Failed to parse major")
            return
        }
        
        guard let minor = BeaconParser().getMinor(name) else {
            debugger.defaultPrint("Rejected beacon '\(name)' - Failed to parse minor")
            return
        }
        
        let address = peripheral.identifier.uuidString
        let distance = BeaconParser().getDistanceInMeters(rssi: Float(rssiValue))
        
        let beacon = Beacon(
            major: major,
            minor: minor,
            rssi: rssiValue,
            bluetoothName: name,
            bluetoothAddress: address,
            distanceMeters: distance,
            lastSeen: Date()
        )
        
        Task { @MainActor in
            self.delegate.updateBeaconList(beacon)
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
