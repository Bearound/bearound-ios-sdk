//
//  EncounterMeshTests.swift
//  BearoundSDKTests
//
//  Tests for the encounter-layer building blocks: rotating identifier store,
//  RSSI aggregation, and payload shape.
//
//  NOTE: Pure logic only (UserDefaults + structs) — no CoreBluetooth radio here.
//

import Foundation
import Testing

@testable import BearoundSDK

// .serialized: RpiStore tests share the same UserDefaults suite.
@Suite("EncounterMesh Tests", .serialized)
struct EncounterMeshTests {

    private static let suiteName = "io.bearound.sdk.tests.mesh"

    private func freshDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        return defaults
    }

    // MARK: - RpiStore

    @Test("RPI is 32 lowercase hex chars and stable inside a window")
    func rpiStableInsideWindow() {
        var store = EncounterMeshManager.RpiStore(defaults: freshDefaults(), rotationInterval: 900)
        let first = store.current()
        #expect(first.count == 32)
        #expect(first.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(store.current() == first)
    }

    @Test("RPI rotates after the interval and keeps the previous one")
    func rpiRotatesAfterInterval() {
        var store = EncounterMeshManager.RpiStore(defaults: freshDefaults(), rotationInterval: 900)
        let first = store.current(now: Date(timeIntervalSince1970: 1_000))
        let second = store.current(now: Date(timeIntervalSince1970: 1_000 + 901))
        #expect(second != first)
        #expect(store.previous() == first)
    }

    @Test("RPI survives a relaunch inside the same window (persistence)")
    func rpiPersistsAcrossInstances() {
        let defaults = freshDefaults()
        var storeA = EncounterMeshManager.RpiStore(defaults: defaults, rotationInterval: 900)
        let rpi = storeA.current()
        var storeB = EncounterMeshManager.RpiStore(defaults: defaults, rotationInterval: 900)
        #expect(storeB.current() == rpi)
    }

    // MARK: - PeerAggregate (running integers, no sample arrays)

    @Test("Aggregate tracks count/min/max/avg incrementally")
    func aggregateMath() {
        var peer = EncounterMeshManager.PeerAggregate()
        let now = Date()
        for rssi in [-50, -60, -70] { peer.addSample(rssi: rssi, now: now) }
        #expect(peer.sampleCount == 3)
        #expect(peer.rssiMin == -70)
        #expect(peer.rssiMax == -50)
        #expect(peer.rssiAvg == -60)
        #expect(peer.lastRssi == -70)
    }

    @Test("First sample initialises the window boundaries")
    func aggregateFirstSample() {
        var peer = EncounterMeshManager.PeerAggregate()
        let t0 = Date(timeIntervalSince1970: 5_000)
        peer.addSample(rssi: -42, now: t0)
        #expect(peer.firstSeen == t0)
        #expect(peer.lastSeen == t0)
        #expect(peer.rssiMin == -42)
        #expect(peer.rssiMax == -42)
    }

    // MARK: - Observation payload shape

    @Test("EncounterObservation serialises to the ingest contract")
    func observationDictionaryShape() {
        let observation = EncounterObservation(
            rpi: "aabbccddeeff00112233445566778899",
            rssi: -61, sampleCount: 12, rssiMin: -80, rssiMax: -50, rssiAvg: -63,
            firstSeen: 1_000, lastSeen: 2_000
        )
        let dict = observation.toDictionary()
        #expect(dict["rpi"] as? String == "aabbccddeeff00112233445566778899")
        #expect(dict["rssi"] as? Int == -61)
        #expect(dict["firstSeen"] as? Int == 1_000)
        #expect(dict["lastSeen"] as? Int == 2_000)
        let samples = dict["rssiSamples"] as? [String: Int]
        #expect(samples?["count"] == 12)
        #expect(samples?["min"] == -80)
        #expect(samples?["max"] == -50)
        #expect(samples?["avg"] == -63)
    }

}
