//
//  BeaconTests.swift
//  BearoundSDKTests
//
//  Tests for Beacon model
//

internal import CoreLocation
import Foundation
import Testing

@testable import BearoundSDK

@Suite("Beacon Model Tests")
struct BeaconTests {

    @Test("Beacon initialization with all properties")
    func beaconInitialization() {
        let uuid = UUID()
        let metadata = BeaconMetadata(
            firmwareVersion: "1.0.0",
            batteryLevel: 85,
            movements: 10,
            temperature: 25,
            txPower: -59,
            rssiFromBLE: -65,
            isConnectable: true
        )

        let beacon = Beacon(
            uuid: uuid,
            major: 100,
            minor: 200,
            rssi: -70,
            proximity: .near,
            accuracy: 2.5,
            timestamp: Date(),
            metadata: metadata,
            txPower: -59
        )

        #expect(beacon.uuid == uuid)
        #expect(beacon.major == 100)
        #expect(beacon.minor == 200)
        #expect(beacon.rssi == -70)
        #expect(beacon.proximity == .near)
        #expect(beacon.accuracy == 2.5)
        #expect(beacon.metadata != nil)
        #expect(beacon.txPower == -59)
    }

    @Test("Beacon without metadata")
    func beaconWithoutMetadata() {
        let beacon = Beacon(
            uuid: UUID(),
            major: 1,
            minor: 1,
            rssi: -50,
            proximity: .immediate,
            accuracy: 0.5,
            timestamp: Date()
        )

        #expect(beacon.metadata == nil)
        #expect(beacon.txPower == nil)
    }

    @Test("Beacon proximity values")
    func beaconProximityValues() {
        let proximities: [CLProximity] = [.unknown, .immediate, .near, .far]

        for proximity in proximities {
            let beacon = Beacon(
                uuid: UUID(),
                major: 1,
                minor: 1,
                rssi: -50,
                proximity: proximity,
                accuracy: 1.0,
                timestamp: Date()
            )

            #expect(beacon.proximity == proximity)
        }
    }

    @Test("Beacon with extreme RSSI values")
    func extremeRSSIValues() {
        let weakBeacon = Beacon(
            uuid: UUID(),
            major: 1,
            minor: 1,
            rssi: -100,
            proximity: .far,
            accuracy: 10.0,
            timestamp: Date()
        )

        let strongBeacon = Beacon(
            uuid: UUID(),
            major: 1,
            minor: 2,
            rssi: -30,
            proximity: .immediate,
            accuracy: 0.1,
            timestamp: Date()
        )

        #expect(weakBeacon.rssi == -100)
        #expect(strongBeacon.rssi == -30)
    }

    @Test("Multiple beacon creation")
    func multipleBeaconCreation() {
        var beacons: [Beacon] = []

        for i in 1...5 {
            let beacon = Beacon(
                uuid: UUID(),
                major: 100,
                minor: i,
                rssi: -60 - i,
                proximity: .near,
                accuracy: Double(i),
                timestamp: Date()
            )
            beacons.append(beacon)
        }

        #expect(beacons.count == 5)

        // Verify each beacon has unique minor
        let minors = beacons.map { $0.minor }
        let uniqueMinors = Set(minors)
        #expect(uniqueMinors.count == 5)
    }
}
