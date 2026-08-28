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

    // MARK: - Window draining (an encounter must expire)

    private static let staleAfter: TimeInterval = 10 * 60

    /// Builds a peer whose window is `samples` readings ending at `lastSeen`.
    private func identifiedPeer(
        rpi: String,
        samples: [Int],
        firstSeen: Date,
        lastSeen: Date
    ) -> EncounterMeshManager.PeerAggregate {
        var peer = EncounterMeshManager.PeerAggregate()
        peer.rpi = rpi
        for (index, rssi) in samples.enumerated() {
            peer.addSample(rssi: rssi, now: index == samples.count - 1 ? lastSeen : firstSeen)
        }
        return peer
    }

    @Test("A peer seen once is reported once, not on every later sync")
    func peerSeenOnceIsNotReplayed() {
        let t0 = Date(timeIntervalSince1970: 100_000)
        let key = UUID()
        var peers = [key: identifiedPeer(rpi: "aa", samples: [-55, -57], firstSeen: t0, lastSeen: t0)]

        let first = EncounterMeshManager.drainWindows(
            from: &peers, now: t0.addingTimeInterval(30), staleAfter: Self.staleAfter)
        #expect(first.count == 1)
        #expect(first[0].sampleCount == 2)

        // Same peer, no new advertisement: every subsequent sync must carry nothing.
        let second = EncounterMeshManager.drainWindows(
            from: &peers, now: t0.addingTimeInterval(60), staleAfter: Self.staleAfter)
        #expect(second.isEmpty)

        let third = EncounterMeshManager.drainWindows(
            from: &peers, now: t0.addingTimeInterval(120), staleAfter: Self.staleAfter)
        #expect(third.isEmpty)
    }

    @Test("A peer unseen past the stale window stops occupying a slot")
    func stalePeerIsEvictedWithoutTheCapacityGuard() {
        let t0 = Date(timeIntervalSince1970: 100_000)
        let key = UUID()
        var peers = [key: identifiedPeer(rpi: "aa", samples: [-55], firstSeen: t0, lastSeen: t0)]

        _ = EncounterMeshManager.drainWindows(from: &peers, now: t0, staleAfter: Self.staleAfter)
        #expect(peers.count == 1)  // still fresh, kept for continuity

        // Far below maxTrackedPeers — the old code only ever expired at capacity, so this
        // entry lived forever.
        _ = EncounterMeshManager.drainWindows(
            from: &peers, now: t0.addingTimeInterval(Self.staleAfter + 1), staleAfter: Self.staleAfter)
        #expect(peers.isEmpty)
    }

    @Test("A peer still present keeps being reported, with a NEW window each time")
    func presentPeerKeepsBeingReportedWithFreshWindows() {
        let t0 = Date(timeIntervalSince1970: 100_000)
        let key = UUID()
        var peers = [key: identifiedPeer(rpi: "aa", samples: [-55, -65], firstSeen: t0, lastSeen: t0)]

        let first = EncounterMeshManager.drainWindows(
            from: &peers, now: t0.addingTimeInterval(1), staleAfter: Self.staleAfter)
        #expect(first.count == 1)
        #expect(first[0].firstSeen == Int(t0.timeIntervalSince1970 * 1000))

        // The encounter is still happening: new advertisements land after the drain.
        let t1 = t0.addingTimeInterval(60)
        peers[key]?.addSample(rssi: -70, now: t1)
        peers[key]?.addSample(rssi: -72, now: t1.addingTimeInterval(5))

        let second = EncounterMeshManager.drainWindows(
            from: &peers, now: t1.addingTimeInterval(10), staleAfter: Self.staleAfter)
        #expect(second.count == 1)
        #expect(second[0].rpi == "aa")
        // A NEW window: it starts when the peer was seen again, not at the first encounter.
        #expect(second[0].firstSeen == Int(t1.timeIntervalSince1970 * 1000))
        #expect(second[0].sampleCount == 2)
        #expect(second[0].rssiMin == -72)
        #expect(second[0].rssiMax == -70)
    }

    @Test("The reported window never grows without bound for a permanently present peer")
    func windowDoesNotGrowUnbounded() {
        let t0 = Date(timeIntervalSince1970: 100_000)
        let key = UUID()
        var peers = [key: EncounterMeshManager.PeerAggregate()]
        peers[key]?.rpi = "aa"

        // Two phones side by side for hours: 200 sync cycles, 3 samples each.
        var now = t0
        var lastReport: EncounterObservation?
        for _ in 0..<200 {
            for _ in 0..<3 {
                peers[key]?.addSample(rssi: -60, now: now)
                now = now.addingTimeInterval(10)
            }
            let out = EncounterMeshManager.drainWindows(
                from: &peers, now: now, staleAfter: Self.staleAfter)
            #expect(out.count == 1)
            // Every payload carries exactly ONE window — never the accumulation since boot.
            #expect(out[0].sampleCount == 3)
            lastReport = out[0]
        }

        guard let report = lastReport else { Issue.record("no window reported"); return }
        // ...and that window is recent, not anchored to the first sighting hours ago.
        #expect(report.firstSeen > Int(t0.timeIntervalSince1970 * 1000))
        #expect(report.lastSeen - report.firstSeen <= 30_000)
    }

    @Test("A peer whose identity was never read is withheld and not drained away")
    func unidentifiedPeerIsWithheld() {
        let t0 = Date(timeIntervalSince1970: 100_000)
        let key = UUID()
        var peers = [key: EncounterMeshManager.PeerAggregate()]
        peers[key]?.addSample(rssi: -55, now: t0)

        let out = EncounterMeshManager.drainWindows(from: &peers, now: t0, staleAfter: Self.staleAfter)
        #expect(out.isEmpty)
        // Its samples survive: the GATT read may still land and the window is then reportable.
        #expect(peers[key]?.sampleCount == 1)

        peers[key]?.rpi = "aa"
        let later = EncounterMeshManager.drainWindows(from: &peers, now: t0, staleAfter: Self.staleAfter)
        #expect(later.count == 1)
        #expect(later[0].sampleCount == 1)
    }

    @Test("resetWindow clears the accumulators but keeps identity and age")
    func resetWindowKeepsIdentityAndAge() {
        let t0 = Date(timeIntervalSince1970: 100_000)
        var peer = EncounterMeshManager.PeerAggregate()
        peer.rpi = "aa"
        peer.addSample(rssi: -50, now: t0)
        peer.addSample(rssi: -70, now: t0)
        peer.resetWindow()

        #expect(peer.sampleCount == 0)
        #expect(peer.rssiAvg == 0)
        #expect(peer.rpi == "aa")       // identity survives — same logical peer
        #expect(peer.lastSeen == t0)    // age survives — eviction reads it

        let t1 = t0.addingTimeInterval(120)
        peer.addSample(rssi: -80, now: t1)
        #expect(peer.firstSeen == t1)   // the next window starts now
        #expect(peer.rssiMin == -80)
        #expect(peer.rssiMax == -80)
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
