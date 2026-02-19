//
//  Beacon.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import CoreLocation
import Foundation

public enum BeaconDiscoverySource: String, Codable {
    case serviceUUID = "Service UUID"
    case name = "Name"
    case coreLocation = "CoreLocation"
}

public enum BeaconProximity: Int, Codable {
    case unknown = 0
    case immediate = 1
    case near = 2
    case far = 3
    case bt = 4  // Detected via Bluetooth-only (no CoreLocation)

    init(fromCL clProximity: CLProximity) {
        switch clProximity {
        case .immediate: self = .immediate
        case .near: self = .near
        case .far: self = .far
        default: self = .unknown
        }
    }
}

public struct Beacon {
    public let uuid: UUID

    public let major: Int

    public let minor: Int

    public let rssi: Int

    public let proximity: BeaconProximity

    public let accuracy: Double

    public let timestamp: Date

    public let metadata: BeaconMetadata?

    public let txPower: Int?

    public let discoverySources: Set<BeaconDiscoverySource>

    /// Internal: indicates this beacon was already sent to Ingest
    public internal(set) var alreadySynced: Bool

    /// Internal: timestamp of the last successful sync for this beacon
    public internal(set) var syncedAt: Date?

    public init(
        uuid: UUID,
        major: Int,
        minor: Int,
        rssi: Int,
        proximity: BeaconProximity,
        accuracy: Double,
        timestamp: Date = Date(),
        metadata: BeaconMetadata? = nil,
        txPower: Int? = nil,
        discoverySources: Set<BeaconDiscoverySource> = [.coreLocation],
        alreadySynced: Bool = false,
        syncedAt: Date? = nil
    ) {
        self.uuid = uuid
        self.major = major
        self.minor = minor
        self.rssi = rssi
        self.proximity = proximity
        self.accuracy = accuracy
        self.timestamp = timestamp
        self.metadata = metadata
        self.txPower = txPower
        self.discoverySources = discoverySources
        self.alreadySynced = alreadySynced
        self.syncedAt = syncedAt
    }
}

