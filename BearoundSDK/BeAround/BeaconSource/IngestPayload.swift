//
//  IngestPayload.swift
//  beaconDetector
//
//  Created by Arthur Sousa on 08/12/25.
//

import Foundation

// MARK: - Ingest Payload Models

/// Representa um beacon individual no payload de ingest
public struct BeaconPayload: Codable {
    let uuid: String
    let name: String
    
    enum CodingKeys: String, CodingKey {
        case uuid
        case name
    }
}

/// Payload completo para envio ao endpoint de ingest
public struct IngestPayload: Codable {
    let beacons: [BeaconPayload]
    let sdk: SDKInfo
    let userDevice: UserDeviceInfo
    let scanContext: ScanContext
    
    enum CodingKeys: String, CodingKey {
        case beacons
        case sdk
        case userDevice
        case scanContext
    }
}

// MARK: - Beacon Extension

extension Beacon {
    /// Converte um Beacon para BeaconPayload
    /// O formato do name é: "B:FIRMWARE_MAJOR.MINOR_BATTERY_MOVEMENTS_TEMPERATURE"
    /// Por exemplo: "B:1.0_1000.2000_85_123_22"
    func toBeaconPayload(
        firmware: String = "1.0",
        battery: Int = 100,
        movements: Int = 0,
        temperature: Int = 20
    ) -> BeaconPayload {
        let name = "B:\(firmware)_\(major).\(minor)_\(battery)_\(movements)_\(temperature)"
        
        return BeaconPayload(
            uuid: uuid.uuidString,
            name: name
        )
    }
}
