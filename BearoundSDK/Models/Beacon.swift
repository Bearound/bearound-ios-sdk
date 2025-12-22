//
//  Beacon.swift
//  beaconDetector
//
//  Created by Arthur Sousa on 16/06/25.
//

import Foundation
import CoreBluetooth

public struct Beacon: Codable, Equatable, Sendable {
    let uuid: UUID
    let major: String
    let minor: String
    var rssi: Int
    let bluetoothName: String
    var bluetoothAddress: String?
    var distanceMeters: Float?
    var lastSeen: Date
    
    init(uuid: UUID = UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!,
         major: String,
         minor: String,
         rssi: Int,
         bluetoothName: String,
         bluetoothAddress: String? = nil,
         distanceMeters: Float? = nil,
         lastSeen: Date = Date()) {
        self.uuid = uuid
        self.major = major
        self.minor = minor
        self.rssi = rssi
        self.bluetoothName = bluetoothName
        self.bluetoothAddress = bluetoothAddress
        self.distanceMeters = distanceMeters
        self.lastSeen = lastSeen
    }
    
    public static func ==(lhs: Beacon, rhs: Beacon) -> Bool {
        return lhs.bluetoothName == rhs.bluetoothName
    }
}
