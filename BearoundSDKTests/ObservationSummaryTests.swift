import Foundation
import Testing
@testable import BearoundSDK

@Suite("Observation Summary Tests")
struct ObservationSummaryTests {
    private let base: Int64 = 1_791_907_200_000
    private let boot = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    private func clock(_ offset: Int64 = 0, boot: String? = nil) -> SamplingClock {
        SamplingClock(wallTimeMs: base + offset, monotonicTimeMs: 1_000_000 + offset, bootIdentifier: boot ?? self.boot)
    }

    private func context(_ id: String = "original", tenant: String = "a", policy: DataCollectionPolicy = .allEnabled,
                         body: [String: ObservationJSONValue]? = nil) -> ObservationSummary.Context {
        ObservationSummary.Context(tenantFingerprint: String(repeating: tenant, count: 64), contextID: id,
            originalPayload: body ?? ["sdk": .object(["platform": .string("ios")]), "device": .object(["battery": .number(50)]),
                "location": .object(["latitude": .number(1)]), "wifis": .array([.object(["ssid": .string("original")])]),
                "userProperties": .object(["segment": .string("original")])],
            motion: MotionEvidence(state: .unknown, source: .none, confidence: .none, reason: "no_evidence",
                observedAtMs: nil, ageMs: nil, contextStable: false), policy: policy)
    }

    private func beacon(_ offset: Int64 = 0, minor: Int = 1, uuid: String? = nil, rssi: Int = -70,
                        accuracy: Double = 2, metadata: BeaconMetadata? = nil) -> Beacon {
        Beacon(uuid: UUID(uuidString: uuid ?? boot)!, major: 1, minor: minor, rssi: rssi, proximity: .bt,
            accuracy: accuracy, timestamp: Date(timeIntervalSince1970: Double(base + offset) / 1000), metadata: metadata, txPower: -59)
    }

    @discardableResult
    private func observe(_ summary: ObservationSummary, _ offset: Int64 = 0, beacons: [Beacon]? = nil,
                         context: ObservationSummary.Context? = nil, callback: String? = nil) -> ObservationSummary.CaptureResult {
        summary.observe(beacons: beacons ?? [beacon(offset)], callbackID: callback ?? String(offset),
                        context: context ?? self.context(), at: clock(offset), isPhysical: true)
    }

    private func number(_ value: ObservationJSONValue?) -> Double? {
        guard case let .number(number) = value else { return nil }
        return number
    }

    private func string(_ value: ObservationJSONValue?) -> String? {
        guard case let .string(string) = value else { return nil }
        return string
    }

    private func buckets(_ beacon: [String: ObservationJSONValue]) -> [[String: ObservationJSONValue]] {
        beacon["temporalBuckets"]?.array?.compactMap(\.object) ?? []
    }

    @Test("Empty and cached callbacks cannot create an observation window")
    func nonPhysical() {
        let summary = ObservationSummary()
        #expect(summary.observe(beacons: [beacon()], callbackID: "cache", context: context(), at: clock(), isPhysical: false).acceptedSamples == 0)
        #expect(observe(summary, beacons: []).liveBeacons.isEmpty)
        #expect(summary.activeWindowId == nil && summary.close(at: clock()) == nil)
    }

    @Test("Live and summary share physical sample and occupied bucket identifiers")
    func sharedIdentifiers() throws {
        let summary = ObservationSummary()
        observe(summary)
        let first = try #require(summary.liveBeacons(at: clock(), maxAgeMs: 30_000).first)
        observe(summary, 5_000, beacons: [beacon(5_000, rssi: -60)])
        let last = try #require(summary.liveBeacons(at: clock(5_000), maxAgeMs: 30_000).first)
        let segment = try #require(summary.close(at: clock(5_000)))
        let bucket = try #require(buckets(segment.beacons[0]).first)
        #expect(first["bucketId"] == last["bucketId"] && first["sampleId"] != last["sampleId"])
        #expect(bucket["firstSampleId"] == first["sampleId"] && bucket["lastSampleId"] == last["sampleId"])
        #expect(first["sampleOrdinal"] == .number(1) && last["sampleOrdinal"] == .number(2))
        #expect(bucket["count"] == .number(2) && segment.sampleCount == 2)
        #expect(UUID(uuidString: try #require(string(first["sampleId"]))) != nil)
    }

    @Test("Welford statistics count distinct physical readings and sample variance")
    func statistics() throws {
        let summary = ObservationSummary()
        observe(summary)
        observe(summary, 5_000, beacons: [beacon(5_000, rssi: -60)])
        let segment = try #require(summary.close(at: clock(5_000)))
        let stats = try #require(segment.beacons[0]["rssiSamples"]?.object)
        #expect(stats["min"] == .number(-70) && stats["max"] == .number(-60) && stats["avg"] == .number(-65))
        #expect(abs(try #require(number(stats["stdDev"])) - sqrt(50)) < 0.000001)
        #expect(stats["firstSeen"] == .number(Double(base)) && stats["lastSeen"] == .number(Double(base + 5_000)))
    }

    @Test("Bucket ordinal resets only at a new occupied ten second bucket")
    func bucketOrdinal() throws {
        let summary = ObservationSummary()
        observe(summary)
        let first = summary.liveBeacons(at: clock(), maxAgeMs: 30_000)[0]
        observe(summary, 10_000)
        let second = summary.liveBeacons(at: clock(10_000), maxAgeMs: 30_000)[0]
        let segment = try #require(summary.close(at: clock(10_000)))
        #expect(first["bucketId"] != second["bucketId"] && second["sampleOrdinal"] == .number(1))
        #expect(buckets(segment.beacons[0]).count == 2)
    }

    @Test("Unobserved intervals do not create empty buckets or duplicate samples")
    func occupiedBuckets() throws {
        let summary = ObservationSummary()
        observe(summary)
        observe(summary, 25_000)
        let segment = try #require(summary.close(at: clock(25_000)))
        #expect(buckets(segment.beacons[0]).count == 2 && segment.sampleCount == 2 && segment.gapCount == 0)
        #expect(buckets(segment.beacons[0]).allSatisfy { $0["count"] == .number(1) })
    }

    @Test("Repeated callbacks cannot count a mutated cached frame as new physical evidence")
    func callbackDedupe() throws {
        let summary = ObservationSummary()
        observe(summary, callback: "source")
        let result = observe(summary, 5_000, beacons: [beacon(5_000)], callback: "source")
        #expect(result.acceptedSamples == 0 && result.duplicateSamples == 1)
        #expect(try #require(summary.close(at: clock(5_000))).sampleCount == 1)
    }

    @Test("Reused and out of order source timestamps remain duplicate after a window closes")
    func sourceDedupe() throws {
        let summary = ObservationSummary()
        observe(summary, 5_000)
        _ = summary.close(at: clock(5_000))
        let repeated = observe(summary, 6_000, beacons: [beacon(5_000)], callback: "repeat")
        let late = observe(summary, 7_000, beacons: [beacon(4_000)], callback: "late")
        #expect(repeated.acceptedSamples == 0 && late.acceptedSamples == 0 && summary.activeWindowId == nil)
    }

    @Test("Future and thirty one second old callbacks cannot renew presence")
    func invalidSourceAge() {
        let summary = ObservationSummary()
        let result = observe(summary, beacons: [beacon(1), beacon(-31_000, minor: 2)])
        #expect(result.acceptedSamples == 0 && result.duplicateSamples == 2)
        #expect(summary.liveBeacons(at: clock(), maxAgeMs: 30_000).isEmpty)
    }

    @Test("CoreLocation zero RSSI and unknown distance remain truthful physical evidence")
    func coreLocationSentinels() throws {
        let summary = ObservationSummary()
        observe(summary, beacons: [beacon(rssi: 0, accuracy: -1)])
        let live = try #require(summary.liveBeacons(at: clock(), maxAgeMs: 30_000).first)
        let row = try #require(summary.close(at: clock())?.beacons.first)
        #expect(live["rssi"] == .number(0) && live["accuracy"] == .number(-1))
        #expect(row["rssiSamples"]?.object?["count"] == .number(1))
        #expect(row["rssiSamples"]?.object?["avg"] == .number(0))
    }

    @Test("Invalid RSSI and distance values cannot increment sample statistics")
    func invalidSignalValues() {
        let summary = ObservationSummary()
        let frames = [beacon(rssi: 1), beacon(minor: 2, rssi: -128), beacon(minor: 3, accuracy: -2), beacon(minor: 4, accuracy: .infinity)]
        #expect(observe(summary, beacons: frames).acceptedSamples == 0)
        #expect(summary.close(at: clock()) == nil)
    }

    @Test("A new beacon emits the complete fresh roster with unchanged prior sample IDs")
    func completeFreshRoster() throws {
        let summary = ObservationSummary()
        observe(summary)
        let first = try #require(summary.liveBeacons(at: clock(), maxAgeMs: 30_000).first)
        observe(summary, 5_000, beacons: [beacon(5_000, minor: 2)])
        let roster = summary.liveBeacons(at: clock(5_000), maxAgeMs: 30_000)
        #expect(roster.count == 2 && roster[0]["sampleId"] == first["sampleId"])
        #expect(summary.liveBeacons(at: clock(5_000), maxAgeMs: 30_000).isEmpty)
    }

    @Test("Nonconsuming previews preserve emission while expired roster entries are excluded")
    func previewAndExpiry() {
        let summary = ObservationSummary()
        observe(summary)
        #expect(summary.liveBeacons(at: clock(), maxAgeMs: 30_000, consume: false).count == 1)
        #expect(summary.liveBeacons(at: clock(), maxAgeMs: 30_000).count == 1)
        observe(summary, 5_000, beacons: [beacon(5_000, minor: 2)])
        let fresh = summary.liveBeacons(at: clock(6_000), maxAgeMs: 5_000)
        #expect(fresh.count == 1 && fresh[0]["minor"] == .number(2))
        #expect(summary.liveBeacons(at: clock(40_000), maxAgeMs: 300_000).isEmpty)
    }

    @Test("Different UUIDs sharing major and minor retain separate signal statistics")
    func fullSignalIdentity() throws {
        let summary = ObservationSummary()
        observe(summary, beacons: [beacon(), beacon(uuid: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")])
        let segment = try #require(summary.close(at: clock()))
        #expect(segment.beacons.count == 2 && segment.sampleCount == 2)
        #expect(buckets(segment.beacons[0])[0]["bucketId"] != buckets(segment.beacons[1])[0]["bucketId"])
    }

    @Test("Source timestamp and original metadata survive aggregation without cache substitution")
    func originalRawFields() throws {
        let summary = ObservationSummary()
        let metadata = BeaconMetadata(firmwareVersion: "original", batteryLevel: 81, movements: 2, temperature: 21,
                                      txPower: -59, rssiFromBLE: -41, isConnectable: true)
        observe(summary, 5_000, beacons: [beacon(3_000, rssi: 0, accuracy: -1, metadata: metadata)])
        let row = try #require(summary.close(at: clock(5_000))?.beacons.first)
        #expect(row["timestamp"] == .number(Double(base + 3_000)) && row["txPower"] == .number(-59))
        #expect(row["metadata"]?.object?["rssiFromBLE"] == .number(-41))
        #expect(row["rssiSamples"]?.object?["avg"] == .number(0))
    }

    @Test("Ordinary battery and device time drift preserve the first complete context body")
    func freezeOriginalContext() throws {
        let summary = ObservationSummary()
        let original = context()
        observe(summary, context: original)
        var changed = original.originalPayload
        changed["device"] = .object(["battery": .number(1), "timestamp": .number(Double(base + 5_000))])
        #expect(observe(summary, 5_000, context: context(body: changed)).closedSegments.isEmpty)
        let segment = try #require(summary.close(at: clock(5_000)))
        #expect(segment.context.originalPayload == original.originalPayload && segment.sampleCount == 2)
    }

    @Test("Meaningful context changes seal the original window before new observations")
    func contextBoundary() throws {
        let summary = ObservationSummary()
        observe(summary)
        let result = observe(summary, 5_000, context: context("next"))
        let closed = try #require(result.closedSegments.first)
        #expect(closed.context.contextID == "original" && closed.sampleCount == 1)
        #expect(try #require(summary.close(at: clock(5_000))).context.contextID == "next")
    }

    @Test("Tenant changes never carry the prior roster into a new tenant")
    func tenantBoundary() throws {
        let summary = ObservationSummary()
        observe(summary)
        let result = observe(summary, 5_000, beacons: [beacon(5_000, minor: 2)], context: context(tenant: "b"))
        #expect(result.closedSegments.count == 1 && result.liveBeacons.count == 1)
        #expect(result.closedSegments[0].context.tenantFingerprint == String(repeating: "a", count: 64))
        #expect(try #require(summary.close(at: clock(5_000))).context.tenantFingerprint == String(repeating: "b", count: 64))
    }

    @Test("Collection policy boundaries preserve absent original fields without adding collectors")
    func policyBoundary() throws {
        let summary = ObservationSummary()
        observe(summary)
        let restricted = DataCollectionPolicy(advertisingId: false, location: false, wifi: false)
        let result = observe(summary, 5_000, context: context(policy: restricted, body: ["sdk": .object([:])]))
        #expect(result.closedSegments.count == 1)
        let segment = try #require(summary.close(at: clock(5_000)))
        #expect(segment.context.policy == restricted && segment.context.originalPayload["location"] == nil)
        #expect(segment.context.originalPayload["wifis"] == nil && segment.context.originalPayload["device"] == nil)
    }

    @Test("A context boundary without new samples closes only the original nonempty window")
    func emptyBoundary() {
        let summary = ObservationSummary()
        observe(summary)
        let result = observe(summary, 5_000, beacons: [], context: context("next"))
        #expect(result.closedSegments.count == 1 && summary.activeWindowId == nil)
        #expect(summary.close(at: clock(5_000)) == nil)
    }

    @Test("A collection gap closes observed coverage rather than filling unseen time")
    func gapBoundary() throws {
        let summary = ObservationSummary()
        observe(summary)
        let result = observe(summary, 31_000)
        let old = try #require(result.closedSegments.first)
        #expect(old.observedFrom == base && old.observedTo == base && old.gapCount == 1)
        #expect(old.sampleCount == 1 && buckets(old.beacons[0]).count == 1)
        #expect(try #require(summary.close(at: clock(31_000))).observedFrom == base + 31_000)
    }

    @Test("The gap threshold honors twice the original callback interval")
    func originalGapCadence() {
        let summary = ObservationSummary(baselineScanCallbackIntervalMs: 20_000)
        observe(summary)
        #expect(observe(summary, 35_000).closedSegments.isEmpty)
        #expect(observe(summary, 76_000).closedSegments.first?.gapCount == 1)
    }

    @Test("A returning beacon gap is detected despite callbacks from other beacons")
    func perSignalGap() {
        let summary = ObservationSummary()
        observe(summary)
        observe(summary, 20_000, beacons: [beacon(20_000, minor: 2)])
        #expect(observe(summary, 35_000).closedSegments.first?.gapCount == 1)
    }

    @Test("A continuous five minute window closes before admitting its boundary sample")
    func durationBound() throws {
        let summary = ObservationSummary()
        observe(summary)
        for offset in stride(from: Int64(10_000), to: 300_000, by: 10_000) { observe(summary, offset) }
        let result = observe(summary, 300_000)
        let closed = try #require(result.closedSegments.first)
        #expect(closed.sampleCount == 30 && closed.observedTo - closed.observedFrom == 290_000)
        #expect(buckets(closed.beacons[0]).count == 30)
        #expect(try #require(summary.close(at: clock(300_000))).sampleCount == 1)
    }

    @Test("The hundred beacon limit seals complete segments without losing the next signal")
    func beaconBound() throws {
        let summary = ObservationSummary()
        let result = observe(summary, beacons: (1...101).map { beacon(minor: $0) })
        let current = try #require(summary.close(at: clock()))
        #expect(result.acceptedSamples == 101 && result.closedSegments.count == 1)
        #expect(result.closedSegments[0].beacons.count == 100 && current.beacons.count == 1)
        #expect(result.closedSegments[0].sampleCount + current.sampleCount == 101)
    }

    @Test("Payload pressure splits before exceeding the summary plus replay header budget")
    func payloadBound() throws {
        let summary = ObservationSummary()
        let metadata = BeaconMetadata(firmwareVersion: String(repeating: "x", count: 8_000), batteryLevel: 50, movements: 0, temperature: 20)
        let result = observe(summary, beacons: (1...100).map { beacon(minor: $0, metadata: metadata) })
        let final = try #require(summary.close(at: clock()))
        let segments = result.closedSegments + [final]
        #expect(segments.count > 1 && result.acceptedSamples == 100)
        #expect(segments.reduce(0) { $0 + $1.sampleCount } == 100)
        for segment in segments {
            var payload = segment.context.originalPayload
            payload["beacons"] = .array(segment.beacons.map { .object($0) })
            #expect(try JSONEncoder().encode(payload).count + 8_192 <= 524_288)
        }
    }

    @Test("An oversized immutable context cannot start a partial observation window")
    func oversizedContext() {
        let summary = ObservationSummary()
        let result = observe(summary, context: context(body: ["userProperties": .string(String(repeating: "x", count: 524_288))]))
        #expect(result.acceptedSamples == 0 && summary.activeWindowId == nil)
    }

    @Test("Long callback streams retain bounded dedupe behavior and reject old source replay")
    func longRunningDedupe() throws {
        let summary = ObservationSummary()
        for offset in 0..<10_000 { observe(summary, Int64(offset)) }
        let replay = observe(summary, 10_000, beacons: [beacon()], callback: "0")
        #expect(replay.acceptedSamples == 0 && replay.duplicateSamples == 1)
        #expect(try #require(summary.close(at: clock(10_000))).sampleCount == 10_000)
    }

    @Test("A reset starts a new stream without reusing a sample identity")
    func streamReset() throws {
        let summary = ObservationSummary()
        observe(summary)
        let first = summary.liveBeacons(at: clock(), maxAgeMs: 30_000)[0]["sampleId"]
        _ = summary.close(at: clock())
        let stream = UUID().uuidString
        summary.reset(captureStreamId: stream)
        observe(summary)
        #expect(summary.captureStreamId == stream)
        #expect(summary.liveBeacons(at: clock(), maxAgeMs: 30_000)[0]["sampleId"] != first)
    }

    @Test("An unreliable clock cannot capture or expose live evidence")
    func unreliableClock() {
        let summary = ObservationSummary()
        observe(summary)
        var unreliable = clock(1)
        unreliable.isReliable = false
        #expect(summary.liveBeacons(at: unreliable, maxAgeMs: 30_000).isEmpty)
        #expect(summary.observe(beacons: [beacon(1)], callbackID: "uncertain", context: context(), at: unreliable, isPhysical: true).acceptedSamples == 0)
    }

    @Test("A reboot closes original coverage and cannot emit the previous boot roster")
    func reboot() {
        let summary = ObservationSummary()
        observe(summary)
        let next = clock(5_000, boot: UUID().uuidString)
        #expect(summary.liveBeacons(at: next, maxAgeMs: 30_000).isEmpty)
        let result = summary.observe(beacons: [beacon(5_000)], callbackID: "new-boot", context: context(), at: next, isPhysical: true)
        #expect(result.closedSegments.first?.observedTo == base && result.acceptedSamples == 1)
    }

    @Test("A wall clock jump seals original epochs and rejects pre-jump cached sources")
    func clockJump() {
        let summary = ObservationSummary()
        observe(summary)
        let shifted = SamplingClock(wallTimeMs: base - 200_000, monotonicTimeMs: 1_001_000, bootIdentifier: boot)
        let old = beacon(-201_000)
        let result = summary.observe(beacons: [old], callbackID: "jump", context: context(), at: shifted, isPhysical: true)
        #expect(result.closedSegments.first?.observedTo == base && result.acceptedSamples == 0)
        #expect(summary.activeWindowId == nil)
    }

    @Test("Summary epochs and explicit unknown clock fields survive complete wire encoding")
    func completeWireEnvelope() throws {
        let summary = ObservationSummary()
        observe(summary)
        let segment = try #require(summary.close(at: clock(300_000)))
        let envelope = SamplingEnvelope(version: 1, kind: .summary, batchId: UUID().uuidString,
            captureStreamId: summary.captureStreamId, windowId: segment.windowId, observedFrom: segment.observedFrom,
            observedTo: segment.observedTo, sentAt: base + 300_000, motion: segment.context.motion,
            clock: SamplingEnvelopeClock(bootId: boot, wallTimeMs: base + 300_000, monotonicTimeMs: 1_300_000))
        var payload = segment.context.originalPayload
        payload["beacons"] = .array(segment.beacons.map { .object($0) })
        payload["sampling"] = try JSONDecoder().decode(ObservationJSONValue.self, from: JSONEncoder().encode(envelope))
        let wire = try JSONDecoder().decode([String: ObservationJSONValue].self, from: JSONEncoder().encode(payload))
        let sampling = try #require(wire["sampling"]?.object)
        #expect(sampling["observedFrom"] == .number(Double(base)) && sampling["sentAt"] == .number(Double(base + 300_000)))
        #expect(sampling["clock"]?.object?["serverOffsetMs"] == .null)
        #expect(sampling["clock"]?.object?["offsetUncertaintyMs"] == .null && sampling["motion"]?.object?["observedAtMs"] == .null)
        #expect(wire["wifis"] == segment.context.originalPayload["wifis"])
    }

    @Test("Draining a live segment freezes the original window context and consumes only unseen IDs")
    func drainOriginalLiveSegment() throws {
        let summary = ObservationSummary()
        observe(summary)
        let old = try #require(summary.drainLiveSegment(at: clock(), maxAgeMs: 30_000))
        observe(summary, 5_000, beacons: [beacon(5_000, minor: 2)])
        let live = try #require(summary.drainLiveSegment(at: clock(5_000), maxAgeMs: 30_000))
        #expect(live.windowId == old.windowId && live.context.contextID == "original")
        #expect(live.beacons.count == 2 && live.sampleCount == 1 && live.beacons[0]["sampleId"] == old.beacons[0]["sampleId"])
        #expect(live.observedFrom == base && live.observedTo == base + 5_000)
        #expect(summary.drainLiveSegment(at: clock(5_000), maxAgeMs: 30_000) == nil)
        #expect(try #require(summary.close(at: clock(5_000))).sampleCount == 2)
    }

    @Test("Context closure returns fresh unseen rows under their original context before the summary")
    func closedContextLiveProvenance() throws {
        let summary = ObservationSummary()
        observe(summary)
        let originalWindow = summary.activeWindowId
        let result = observe(summary, 5_000, beacons: [beacon(5_000, minor: 2)], context: context("next"))
        let live = try #require(result.closedLiveSegments.first)
        #expect(live.windowId == originalWindow && live.windowId == result.closedSegments[0].windowId)
        #expect(live.context.contextID == "original" && live.observedFrom == base && live.observedTo == base)
        #expect(live.beacons.count == 1 && live.beacons[0]["minor"] == .number(1) && live.sampleCount == 1)
        #expect(result.liveBeacons.count == 1 && result.liveBeacons[0]["minor"] == .number(2))
    }

    @Test("Capacity closure preserves the full original live roster before the hundred first beacon")
    func closedCapacityLiveProvenance() throws {
        let summary = ObservationSummary()
        let result = observe(summary, beacons: (1...101).map { beacon(minor: $0) })
        let live = try #require(result.closedLiveSegments.first)
        #expect(live.beacons.count == 100 && live.sampleCount == 100 && live.windowId == result.closedSegments[0].windowId)
        #expect(live.beacons.allSatisfy { $0["sampleId"] != nil && $0["temporalBuckets"] == nil })
        #expect(result.liveBeacons.count == 1 && result.liveBeacons[0]["minor"] == .number(101))
    }

    @Test("Duration closure emits only fresh unseen original rows and preserves physical timestamps")
    func closedDurationLiveProvenance() throws {
        let summary = ObservationSummary()
        observe(summary)
        _ = summary.drainLiveSegment(at: clock(), maxAgeMs: 30_000)
        for offset in stride(from: Int64(10_000), to: 300_000, by: 10_000) { observe(summary, offset) }
        let result = observe(summary, 300_000)
        let live = try #require(result.closedLiveSegments.first)
        #expect(live.observedFrom == base + 290_000 && live.observedTo == base + 290_000)
        #expect(live.beacons[0]["timestamp"] == .number(Double(base + 290_000)))
        #expect(live.windowId == result.closedSegments[0].windowId && live.windowId != summary.activeWindowId)
    }

    @Test("Gap closure never revives expired original rows as current live observations")
    func expiredClosedLive() {
        let summary = ObservationSummary()
        observe(summary)
        let result = observe(summary, 31_000)
        #expect(result.closedSegments.count == 1 && result.closedLiveSegments.isEmpty)
        #expect(result.liveBeacons.count == 1 && result.liveBeacons[0]["timestamp"] == .number(Double(base + 31_000)))
    }

    @Test("A consumed roster and a new boot cannot produce a duplicate closed live segment")
    func noDuplicateClosedLive() {
        let summary = ObservationSummary()
        observe(summary)
        _ = summary.drainLiveSegment(at: clock(), maxAgeMs: 30_000)
        let result = observe(summary, 5_000, context: context("next"))
        #expect(result.closedLiveSegments.isEmpty)
        let reboot = clock(6_000, boot: UUID().uuidString)
        #expect(summary.drainLiveSegment(at: reboot, maxAgeMs: 30_000) == nil)
    }

}
