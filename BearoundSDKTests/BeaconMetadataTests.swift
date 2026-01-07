//
//  BeaconMetadataTests.swift
//  BearoundSDKTests
//
//  Tests for BeaconMetadata model
//

import Foundation
import Testing

@testable import BearoundSDK

@Suite("BeaconMetadata Tests")
struct BeaconMetadataTests {

    @Test("BeaconMetadata initialization with required fields")
    func metadataInitialization() {
        let metadata = BeaconMetadata(
            firmwareVersion: "2.1.0",
            batteryLevel: 90,
            movements: 5,
            temperature: 22
        )

        #expect(metadata.firmwareVersion == "2.1.0")
        #expect(metadata.batteryLevel == 90)
        #expect(metadata.movements == 5)
        #expect(metadata.temperature == 22)
        #expect(metadata.txPower == nil)
        #expect(metadata.rssiFromBLE == nil)
        #expect(metadata.isConnectable == nil)
    }

    @Test("BeaconMetadata with all optional fields")
    func metadataWithOptionalFields() {
        let metadata = BeaconMetadata(
            firmwareVersion: "3.0.0",
            batteryLevel: 75,
            movements: 100,
            temperature: 30,
            txPower: -60,
            rssiFromBLE: -70,
            isConnectable: false
        )

        #expect(metadata.txPower == -60)
        #expect(metadata.rssiFromBLE == -70)
        #expect(metadata.isConnectable == false)
    }

    @Test("BeaconMetadata equality")
    func metadataEquality() {
        let metadata1 = BeaconMetadata(
            firmwareVersion: "1.0.0",
            batteryLevel: 80,
            movements: 10,
            temperature: 25,
            txPower: -59
        )

        let metadata2 = BeaconMetadata(
            firmwareVersion: "1.0.0",
            batteryLevel: 80,
            movements: 10,
            temperature: 25,
            txPower: -59
        )

        let metadata3 = BeaconMetadata(
            firmwareVersion: "1.0.0",
            batteryLevel: 85,  // Different
            movements: 10,
            temperature: 25,
            txPower: -59
        )

        #expect(metadata1 == metadata2)
        #expect(metadata1 != metadata3)
    }

    @Test("BeaconMetadata with extreme values")
    func extremeMetadataValues() {
        let lowBattery = BeaconMetadata(
            firmwareVersion: "1.0.0",
            batteryLevel: 0,
            movements: 0,
            temperature: -10
        )

        let highValues = BeaconMetadata(
            firmwareVersion: "99.99.99",
            batteryLevel: 100,
            movements: 999999,
            temperature: 100
        )

        #expect(lowBattery.batteryLevel == 0)
        #expect(highValues.batteryLevel == 100)
        #expect(highValues.movements == 999999)
    }
}
