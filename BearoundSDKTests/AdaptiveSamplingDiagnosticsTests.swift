import Foundation
import Testing
@testable import BearoundSDK

@Suite("Adaptive Sampling Diagnostics Tests", .serialized)
struct AdaptiveSamplingDiagnosticsTests {
    private let base: Int64 = 1_791_907_200_000
    private let boot = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    private func clock(_ offset: Int64 = 0, boot: String? = nil) -> SamplingClock {
        SamplingClock(wallTimeMs: base + offset, monotonicTimeMs: 1_000_000 + offset, bootIdentifier: boot ?? self.boot)
    }
    private func beacon(_ offset: Int64 = 0, minor: Int = 1, major: Int = 1, rssi: Int = -70) -> Beacon {
        Beacon(uuid: BeaconConstants.uuid, major: major, minor: minor, rssi: rssi, proximity: .bt,
            accuracy: -1, timestamp: Date(timeIntervalSince1970: Double(base + offset) / 1_000))
    }
    private func body(_ label: String = "original") -> [String: Any] {
        ["sdk": ["version": "test", "platform": "ios", "appId": "test.app", "build": 1],
         "device": ["deviceId": "device", "timestamp": base, "pushToken": label,
                    "network": ["type": "wifi", "apId": "stable-ap"]],
         "userProperties": ["internalId": label], "syncTrigger": "adaptive_physical"]
    }
    private func runtime(enabled: Bool = true, generation: UInt64 = 1) -> AdaptiveSamplingRuntime {
        AdaptiveSamplingRuntime(configuration: SDKConfiguration(businessToken: "test-token",
            adaptiveSamplingEnabled: enabled), deviceID: "device", generation: generation)
    }
    private func response(lease: Int64 = 300_000, version: Int = 1, modes: [String] = ["live", "summary", "transition"],
                          serverOffset: Int64 = 0) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["capabilities": ["adaptiveSampling": [
            "version": version, "modes": modes, "leaseMs": lease, "serverTimeMs": base + serverOffset,
            "servicesCadenceMs": 60_000, "mapTtlMs": 300_000, "sessionTimeoutMs": 1_800_000,
            "liveEvidenceMaxAgeMs": 30_000, "clockSkewToleranceMs": 120_000, "maxPayloadBytes": 524_288]]])
    }
    private func negotiate(_ runtime: AdaptiveSamplingRuntime, at offset: Int64 = 0) throws {
        runtime.acceptResponse(try response(serverOffset: offset), requestedAt: clock(offset), receivedAt: clock(offset), generation: runtime.generation)
    }
    private func observe(_ runtime: AdaptiveSamplingRuntime, _ offset: Int64 = 0, label: String = "original",
                         beacons: [Beacon]? = nil, physical: Bool = true) {
        runtime.observePhysical(beacons ?? [beacon(offset)], callbackID: UUID().uuidString,
            at: clock(offset), isPhysical: physical) { body(label) }
    }

    @Test("Capability starts legacy and binds the current generation with a monotonic lease")
    func generationAndLease() throws {
        let runtime = runtime()
        #expect(runtime.samplingPlan(at: clock()).mode == .legacy)
        runtime.acceptResponse(try response(), requestedAt: clock(), receivedAt: clock(), generation: 0)
        #expect(!runtime.hasCapability(at: clock()))
        try negotiate(runtime)
        #expect(runtime.hasCapability(at: clock(299_999)))
        #expect(!runtime.hasCapability(at: clock(300_000)))
        #expect(!runtime.hasCapability(at: clock(1, boot: UUID().uuidString)))
        #expect(!runtime.hasCapability(at: SamplingClock(wallTimeMs: base + 10_000,
            monotonicTimeMs: 1_000_001, bootIdentifier: boot)))
    }

    @Test("Unsupported capability limits and locally disabled adaptive sampling stay legacy")
    func incompatibleAndRollback() throws {
        for data in [try response(version: 2), try response(lease: 300_001), try response(modes: ["live"])] {
            let runtime = runtime()
            runtime.acceptResponse(data, requestedAt: clock(), receivedAt: clock(), generation: 1)
            #expect(!runtime.hasCapability(at: clock()))
        }
        let disabled = runtime(enabled: false)
        try negotiate(disabled)
        observe(disabled)
        disabled.close(at: clock())
        #expect(disabled.takePending(at: clock()).isEmpty)
        #expect(disabled.samplingPlan(at: clock()).mode == .legacy)
    }

    @Test("Degraded durable ACK immediately closes v1 history and falls back without waiting for lease")
    func degradedAck() throws {
        let runtime = runtime()
        try negotiate(runtime)
        observe(runtime)
        _ = runtime.takePending(at: clock())
        let data = try JSONSerialization.data(withJSONObject: ["samplingAck": ["batchId": UUID().uuidString,
            "archive": "durable", "projection": "archive_only", "reason": "ledger_unavailable",
            "fallback": "legacy_now", "invalidateCapability": true]])
        runtime.acceptResponse(data, requestedAt: clock(), receivedAt: clock(1_000), generation: 1)
        #expect(!runtime.hasCapability(at: clock(1_000)))
        #expect(runtime.samplingPlan(at: clock(1_000)).mode == .legacy)
        #expect(runtime.takePending(at: clock(1_000)).contains { $0.deliveryProtocol == .adaptive && $0.sampling?.kind == .summary })
    }

    @Test("Cache stale and repeated source callbacks never create samples or read complementary sources")
    func physicalProvenance() throws {
        let runtime = runtime()
        try negotiate(runtime)
        var reads = 0
        runtime.observePhysical([beacon()], callbackID: "cache", at: clock(), isPhysical: false) { reads += 1; return body() }
        runtime.observePhysical([beacon(-30_001)], callbackID: "stale", at: clock()) { reads += 1; return body() }
        #expect(runtime.diagnostics.uniqueSamples == 0 && reads == 0)
        runtime.observePhysical([beacon()], callbackID: "physical", at: clock()) { reads += 1; return body() }
        let first = runtime.takePending(at: clock())
        runtime.observePhysical([beacon()], callbackID: "new-cache-id", at: clock(1_000)) { reads += 1; return body("wrong") }
        #expect(runtime.diagnostics.uniqueSamples == 1 && reads == 1)
        #expect(first.count == 1 && runtime.takePending(at: clock(1_000)).isEmpty)
        #expect(runtime.diagnostics.cachedCallbacks == 3)
    }

    @Test("Metadata mutation closes frozen history and the next live body uses current identity and push")
    func immediateMetadataRefresh() throws {
        let runtime = runtime()
        try negotiate(runtime)
        observe(runtime)
        let originalID = runtime.contextID
        _ = runtime.takePending(at: clock())
        runtime.invalidateContextMetadata(at: clock(1_000))
        let old = try #require(runtime.takePending(at: clock(1_000)).first)
        observe(runtime, 15_000, label: "current")
        let current = try #require(runtime.takePending(at: clock(15_000)).first { $0.sampling?.kind == .live })
        #expect(old.contextID == originalID && current.contextID != originalID)
        #expect(old.originalPayload["userProperties"]?.object?["internalId"] == .string("original"))
        #expect(old.originalPayload["device"]?.object?["pushToken"] == .string("original"))
        #expect(current.originalPayload["userProperties"]?.object?["internalId"] == .string("current"))
        #expect(current.originalPayload["device"]?.object?["pushToken"] == .string("current"))
        #expect(old.sampling?.sentAt == old.sampling?.clock.wallTimeMs)
    }

    @Test("Stable physical evidence reduces complementary reads while preserving live cadence and observation count")
    func stableEconomy() throws {
        let runtime = runtime()
        try negotiate(runtime)
        var reads = 0
        var live = 0
        for offset in stride(from: Int64(0), through: 280_000, by: 20_000) {
            runtime.observePhysical([beacon(offset)], callbackID: String(offset), at: clock(offset)) { reads += 1; return body() }
            live += runtime.takePending(at: clock(offset)).filter { $0.sampling?.kind == .live }.count
        }
        #expect(runtime.diagnostics.uniqueSamples == 15 && live == 15)
        #expect(reads <= 6 && runtime.diagnostics.complementaryCacheReads >= 9)
        #expect(runtime.samplingPlan(at: clock(280_000)).mode == .stable)
        #expect(runtime.samplingPlan(at: clock(280_000)).liveIntervalMs <= 15_000)
    }

    @Test("Reserved peer beacons stay in the encounter path and cannot become venue observations")
    func peerIsNotMotionCue() throws {
        let runtime = runtime()
        try negotiate(runtime)
        var contextID: String?
        for offset in stride(from: Int64(0), through: 120_000, by: 20_000) {
            observe(runtime, offset, beacons: [beacon(offset, major: Int(EncounterMeshManager.virtualBeaconMajor))])
            _ = runtime.takePending(at: clock(offset))
            if contextID == nil { contextID = runtime.contextID }
        }
        #expect(runtime.diagnostics.uniqueSamples == 0)
        #expect(runtime.policy.evidence(at: clock(120_000)).state == .unknown)
        #expect(!runtime.policy.evidence(at: clock(120_000)).contextStable)
        #expect(runtime.contextID == contextID)
    }

    @Test("Pre-capability physical readings are never promoted into adaptive historical windows")
    func legacyBoundary() throws {
        let runtime = runtime()
        observe(runtime)
        runtime.close(at: clock(1_000))
        #expect(runtime.takePending(at: clock(1_000)).isEmpty)
        try negotiate(runtime, at: 15_000)
        observe(runtime, 15_000)
        runtime.close(at: clock(16_000))
        let pending = runtime.takePending(at: clock(16_000))
        #expect(pending.allSatisfy { $0.sampling!.observedFrom >= base + 15_000 })
        #expect(pending.contains { $0.sampling?.kind == .summary })
    }

    @Test("Original legacy clock allows fresh compatibility retry and rejects stale rebooted or missing provenance")
    func legacyReplayFreshness() throws {
        let runtime = runtime()
        observe(runtime)
        var payload = body()
        payload["beacons"] = [["uuid": BeaconConstants.uuid.uuidString, "major": 1, "minor": 1,
            "rssi": -70, "timestamp": base, "accuracy": -1, "proximity": "bt"]]
        let envelope = try runtime.legacyEnvelope(beacons: [beacon()], payload: payload, at: clock())
        #expect(AdaptiveSamplingRuntime.canDeliver(envelope, at: clock(30_000), capabilityAvailable: false))
        #expect(!AdaptiveSamplingRuntime.canDeliver(envelope, at: clock(30_001), capabilityAvailable: false))
        #expect(!AdaptiveSamplingRuntime.canDeliver(envelope, at: clock(1, boot: UUID().uuidString), capabilityAvailable: true))
        let missing = try StoredObservationEnvelope(batchId: UUID().uuidString, storedAtMs: base,
            tenantFingerprint: runtime.tenantFingerprint, originalPayload: payload, sampling: nil, deliveryProtocol: .legacy)
        #expect(!AdaptiveSamplingRuntime.canDeliver(missing, at: clock(), capabilityAvailable: false))
    }

    @Test("Clock discontinuity closes original history and invalidates capability without new stale samples")
    func clockSafety() throws {
        let runtime = runtime()
        try negotiate(runtime)
        observe(runtime)
        _ = runtime.takePending(at: clock())
        runtime.observePhysical([beacon()], callbackID: "reboot", at: clock(1_000, boot: UUID().uuidString)) { body("new") }
        #expect(!runtime.hasCapability(at: clock(1_000)))
        #expect(runtime.diagnostics.clockUncertainties == 1)
        let saved = runtime.takePending(at: clock(1_000))
        #expect(saved.allSatisfy { $0.sampling?.clock.bootId == boot })
        #expect(saved.allSatisfy { $0.originalPayload["userProperties"]?.object?["internalId"] == .string("original") })
    }

    @Test("Attempt counters distinguish live summary transition bytes and retry lag")
    func measurableDiagnostics() throws {
        let runtime = runtime()
        try negotiate(runtime)
        observe(runtime)
        let live = try #require(runtime.takePending(at: clock()).first)
        runtime.close(at: clock(5_000), kind: .transition)
        let transition = try #require(runtime.takePending(at: clock(5_000)).first)
        runtime.recordAttempt(live, bytes: 200, failed: false, at: clock(5_000))
        runtime.recordAttempt(transition, bytes: 400, failed: true, at: clock(10_000))
        #expect(runtime.diagnostics.liveAttempts == 1 && runtime.diagnostics.transitionAttempts == 1)
        #expect(runtime.diagnostics.serializedBytes == 600 && runtime.diagnostics.failures == 1)
        #expect(runtime.diagnostics.retryLagMs == 10_000)
    }

    @Test("Context and native boundaries flush un-emitted fresh rows with original window and sample identity")
    func boundaryLiveProvenance() throws {
        for native in [false, true] {
            let runtime = runtime()
            try negotiate(runtime)
            observe(runtime)
            let first = try #require(runtime.takePending(at: clock()).first)
            observe(runtime, 5_000)
            #expect(runtime.takePending(at: clock(5_000)).isEmpty)
            if native {
                runtime.observeNative(NativeActivityObservation(observedAtMs: base + 6_000, walking: true, confidence: .high),
                    at: clock(6_000), generation: 1)
            } else { runtime.invalidateContextMetadata(at: clock(6_000)) }
            let closed = runtime.takePending(at: clock(6_000))
            let live = try #require(closed.first { $0.sampling?.kind == .live })
            let archive = try #require(closed.first { $0.sampling?.kind != .live })
            #expect(closed.first?.batchId == live.batchId)
            #expect(live.sampling?.windowId == first.sampling?.windowId && archive.sampling?.windowId == live.sampling?.windowId)
            #expect(live.contextID == first.contextID && archive.contextID == first.contextID)
            #expect(live.sampling?.observedFrom == base + 5_000 && live.sampling?.observedTo == base + 5_000)
            let row = try #require(live.originalPayload["beacons"]?.array?.first?.object)
            let bucket = try #require(archive.originalPayload["beacons"]?.array?.first?.object?["temporalBuckets"]?.array?.first?.object)
            #expect(row["sampleId"] == bucket["lastSampleId"] && row["bucketId"] == bucket["bucketId"])
            #expect(runtime.diagnostics.uniqueSamples == 2)
            #expect(AdaptiveSamplingRuntime.isCurrentLive(live, at: clock(30_000)))
            #expect(!AdaptiveSamplingRuntime.isCurrentLive(live, at: clock(35_001)))
        }
    }

    @Test("An automatic beacon-capacity close preserves the original fresh live page before archive")
    func capacityBoundaryLive() throws {
        let runtime = runtime()
        try negotiate(runtime)
        observe(runtime)
        _ = runtime.takePending(at: clock())
        // Reserved peer majors are absent. A physical roster is limited only at the wire window boundary.
        let roster = (1 ... 101).map { beacon(5_000, minor: $0) }
        observe(runtime, 5_000, beacons: roster)
        let pending = runtime.takePending(at: clock(5_000))
        #expect(runtime.diagnostics.uniqueSamples == 102)
        #expect(roster.allSatisfy { runtime.physicalEvidenceIsFresh($0, at: clock(5_000)) })
        #expect(pending.contains { $0.sampling?.kind == .live && $0.originalPayload["beacons"]?.array?.count == 100 })
        #expect(pending.allSatisfy { ($0.originalPayload["beacons"]?.array?.count ?? 0) <= 100 })
        for live in pending where live.sampling?.kind == .live {
            #expect(AdaptiveSamplingRuntime.isCurrentLive(live, at: clock(5_000)))
        }
    }

    @Test("Current encounters ride new live frames without extra complementary reads or rewriting original summaries")
    func currentEncountersPreserved() throws {
        let runtime = runtime()
        try negotiate(runtime)
        var reads = 0
        func fields(_ offset: Int64) -> [String: Any] {
            ["encounters": [EncounterObservation(rpi: String(repeating: "a", count: 32), rssi: -65,
                sampleCount: 1, rssiMin: -65, rssiMax: -65, rssiAvg: -65,
                firstSeen: Int(base + offset), lastSeen: Int(base + offset)).toDictionary()],
             "encounterIds": [String(repeating: "b", count: 32)]]
        }
        runtime.observePhysical([beacon()], callbackID: "first", at: clock(), existingEncounterFieldsProvider: { fields(0) }) {
            reads += 1; return body()
        }
        _ = runtime.takePending(at: clock())
        runtime.observePhysical([beacon(15_000)], callbackID: "next", at: clock(15_000), existingEncounterFieldsProvider: { fields(15_000) }) {
            reads += 1; return body()
        }
        let prepared = runtime.takePending(at: clock(15_000))
        let current = try #require(prepared.first { $0.sampling?.kind == .live })
        #expect(current.originalPayload["encounters"]?.array?.first?.object?["lastSeen"] == .number(Double(base + 15_000)))
        let original = try #require(prepared.first { $0.sampling?.kind == .summary })
        #expect(original.originalPayload["encounters"]?.array?.first?.object?["lastSeen"] == .number(Double(base)))
        #expect(reads == 1 && runtime.diagnostics.uniqueSamples == 2)
    }

    @Test("Fresh motion shortens a stable complementary deadline without an extra periodic wakeup")
    func motionShortensDeadline() throws {
        let runtime = runtime()
        try negotiate(runtime)
        var reads = 0
        for offset in stride(from: Int64(0), through: 180_000, by: 20_000) {
            runtime.observePhysical([beacon(offset)], callbackID: String(offset), at: clock(offset)) { reads += 1; return body() }
            _ = runtime.takePending(at: clock(offset))
        }
        #expect(runtime.samplingPlan(at: clock(180_000)).mode == .stable)
        #expect(runtime.diagnostics.nextContextDeadlineMonotonicMs == 1_480_000)
        runtime.observeNative(NativeActivityObservation(observedAtMs: base + 181_000, walking: true, confidence: .high),
            at: clock(181_000), generation: 1)
        #expect(runtime.samplingPlan(at: clock(181_000)).mode == .novelty)
        #expect(runtime.diagnostics.nextContextDeadlineMonotonicMs == 1_211_000)
        let before = reads
        runtime.observePhysical([beacon(211_000)], callbackID: "next", at: clock(211_000)) { reads += 1; return body() }
        #expect(reads == before + 1)
    }

    @Test("Fresh material location changes rotate context while GPS jitter and native moving state preserve generation")
    func materialLocationContext() throws {
        let runtime = runtime()
        try negotiate(runtime)
        runtime.observeNative(NativeActivityObservation(observedAtMs: base, walking: true, confidence: .high), at: clock(), generation: 1)
        func locationBody(_ offset: Int64, _ latitude: Double) -> [String: Any] {
            var payload = body()
            payload["location"] = ["latitude": latitude, "longitude": 1.0, "accuracy": 5.0,
                "timestamp": base + offset, "source": "ios"]
            return payload
        }
        runtime.observePhysical([beacon()], callbackID: "origin", at: clock()) { locationBody(0, 1) }
        _ = runtime.takePending(at: clock())
        let origin = runtime.contextID
        runtime.observePhysical([beacon(30_000)], callbackID: "jitter", at: clock(30_000)) { locationBody(30_000, 1.000001) }
        let history = try #require(runtime.takePending(at: clock(30_000)).first { $0.sampling?.kind == .summary })
        #expect(runtime.contextID == origin)
        runtime.observePhysical([beacon(60_000)], callbackID: "displaced", at: clock(60_000)) { locationBody(60_000, 1.001) }
        let pending = runtime.takePending(at: clock(60_000))
        #expect(runtime.policy.evidence(at: clock(60_000)).state == .movingConfirmed)
        #expect(runtime.contextID != origin)
        #expect(history.contextID == origin)
        #expect(history.originalPayload["location"]?.object?["latitude"] == .number(1))
        let live = try #require(pending.last { $0.sampling?.kind == .live })
        #expect(live.contextID == runtime.contextID && live.originalPayload["location"]?.object?["latitude"] == .number(1.001))
    }

    @Test("Fresh CL-only zero RSSI preserves physical readings without renewing an old RSSI motion cue")
    func clZeroDoesNotRenewCachedRssi() throws {
        let runtime = runtime()
        try negotiate(runtime)
        observe(runtime)
        _ = runtime.takePending(at: clock())
        for offset in stride(from: Int64(20_000), through: 160_000, by: 20_000) {
            observe(runtime, offset, beacons: [beacon(offset, rssi: 0)])
            let pending = runtime.takePending(at: clock(offset))
            #expect(pending.contains { $0.sampling?.kind == .live })
        }
        #expect(runtime.diagnostics.uniqueSamples == 9)
        #expect(!runtime.policy.evidence(at: clock(160_000)).contextStable)
        #expect(runtime.policy.evidence(at: clock(160_000)).state == .unknown)
    }

    @Test("Sampling counters survive generation reset without double counting or accepting stale callback snapshots")
    func generationCounterTotals() {
        let store = DiagnosticsStore()
        store.recordComplementaryRead(fresh: true)
        var first = BeAroundSamplingDiagnostics()
        first.generation = 1
        first.uniqueSamples = 2
        first.liveAttempts = 1
        first.serializedBytes = 100
        first.cachedCallbacks = 3
        first.buckets = 2
        store.recordSampling(first)
        store.recordSampling(first)
        #expect(store.samplingSnapshot.uniqueSamples == 2 && store.samplingSnapshot.serializedBytes == 100)
        var second = BeAroundSamplingDiagnostics()
        second.generation = 2
        store.recordSampling(second)
        second.uniqueSamples = 1
        second.liveAttempts = 1
        second.serializedBytes = 50
        second.cachedCallbacks = 1
        second.buckets = 1
        store.recordSampling(second)
        store.recordSampling(first)
        let result = store.samplingSnapshot
        #expect(result.generation == 2 && result.uniqueSamples == 3 && result.liveAttempts == 2)
        #expect(result.serializedBytes == 150 && result.cachedCallbacks == 4 && result.buckets == 3)
        #expect(result.complementaryReads == 1)
    }

    #if DEBUG
    @Test("Debug bench is disabled without the explicit host opt-in")
    func benchHostGuard() {
        #expect(!AdaptiveSamplingBench.isEnabled)
        #expect(AdaptiveSamplingBench.endpoint == nil)
    }
    #endif
}
