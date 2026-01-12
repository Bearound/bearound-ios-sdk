//
//  Beacon.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import CoreLocation
import Foundation

public struct Beacon {
    public let uuid: UUID

    public let major: Int

    public let minor: Int

    public let rssi: Int

    public let proximity: CLProximity

    public let accuracy: Double

    public let timestamp: Date

    public let metadata: BeaconMetadata?

    public let txPower: Int?

    public init(
        uuid: UUID,
        major: Int,
        minor: Int,
        rssi: Int,
        proximity: CLProximity,
        accuracy: Double,
        timestamp: Date = Date(),
        metadata: BeaconMetadata? = nil,
        txPower: Int? = nil
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
    }
}

