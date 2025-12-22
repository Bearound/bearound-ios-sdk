//
//  IngestPayload.swift
//  beaconDetector
//
//  Created by Felipe Costa Araujo on 08/12/25.
//

import Foundation

// MARK: - Ingest Payload Models

/// Representa um beacon individual no payload de ingest
public struct BeaconPayload: Codable {
    let uuid: String
    let name: String
    let rssi: Int
    let approxDistanceMeters: Float?
    let txPower: Int?
    
    enum CodingKeys: String, CodingKey {
        case uuid
        case name
        case rssi
        case approxDistanceMeters
        case txPower
    }
}

/// Payload completo para envio ao endpoint de ingest
public struct IngestPayload: Codable {
    let clientToken: String
    let beacons: [BeaconPayload]
    let sdk: SDKInfo
    let userDevice: UserDeviceInfo
    let scanContext: ScanContext
    
    enum CodingKeys: String, CodingKey {
        case clientToken
        case beacons
        case sdk
        case userDevice
        case scanContext
    }
}

// MARK: - Beacon Extension

extension Beacon {
    func toBeaconPayload(txPower: Int? = nil) -> BeaconPayload {
        return BeaconPayload(
            uuid: uuid.uuidString,
            name: bluetoothName,
            rssi: rssi,
            approxDistanceMeters: distanceMeters,
            txPower: txPower
        )
    }
}
