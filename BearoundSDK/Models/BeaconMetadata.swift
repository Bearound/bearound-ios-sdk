//
//  BeaconMetadata.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import Foundation

public struct BeaconMetadata: Equatable {
    public let firmwareVersion: String

    public let batteryLevel: Int

    public let movements: Int

    public let temperature: Int

    public let txPower: Int?

    public let rssiFromBLE: Int?

    public let isConnectable: Bool?

    public init(
        firmwareVersion: String,
        batteryLevel: Int,
        movements: Int,
        temperature: Int,
        txPower: Int? = nil,
        rssiFromBLE: Int? = nil,
        isConnectable: Bool? = nil
    ) {
        self.firmwareVersion = firmwareVersion
        self.batteryLevel = batteryLevel
        self.movements = movements
        self.temperature = temperature
        self.txPower = txPower
        self.rssiFromBLE = rssiFromBLE
        self.isConnectable = isConnectable
    }
}

