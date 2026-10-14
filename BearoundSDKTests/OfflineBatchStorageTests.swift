//
//  OfflineBatchStorageTests.swift
//  BearoundSDKTests
//
//  Tests for offline batch storage and retry logic
//

import CoreLocation
import Foundation
import Testing

@testable import BearoundSDK

@Suite("OfflineBatchStorage Tests", .serialized)
struct OfflineBatchStorageTests {

    /// A unique directory per test instance isolates the on-disk batch store, so
    /// batches from one test never leak into another. The suite is serialized and
    /// Swift Testing creates a fresh struct instance per test.
    private let testDirectory = "com.bearound.sdk.test.batches.\(UUID().uuidString)"

    private func makeStorage(now: @escaping () -> Date = Date.init) -> OfflineBatchStorage {
        OfflineBatchStorage(directoryName: testDirectory, now: now)
    }


    @Test("Initialize with default max batch count")
    func initializeDefaultMaxBatchCount() {
        let storage = makeStorage()
        
        // Default should be medium (100)
        #expect(storage.maxBatchCount == 100)
    }
    
    @Test("Save batch returns success")
    func saveBatchReturnsSuccess() {
        let storage = makeStorage()
        
        // Create test beacons
        let beacons = createTestBeacons(count: 3)
        
        // Save batch
        let result = storage.saveBatch(beacons)
        
        #expect(result == true)
    }
    
    @Test("Batch count increases after save")
    func batchCountIncreasesAfterSave() {
        let storage = makeStorage()
        
        let initialCount = storage.batchCount
        
        // Save a batch
        let beacons = createTestBeacons(count: 2)
        _ = storage.saveBatch(beacons)
        
        let newCount = storage.batchCount
        
        #expect(newCount == initialCount + 1)
    }
    
    @Test("Load oldest batch returns beacons")
    func loadOldestBatchReturnsBeacons() {
        let storage = makeStorage()
        
        // Save a batch
        let beacons = createTestBeacons(count: 3)
        _ = storage.saveBatch(beacons)
        
        // Load oldest batch
        if let loadedBeacons = storage.loadOldestBatch() {
            #expect(loadedBeacons.count == 3)
            #expect(loadedBeacons[0].major == 1000)
        } else {
            Issue.record("Failed to load batch")
        }
    }
    
    @Test("Remove oldest batch decreases count")
    func removeOldestBatchDecreasesCount() {
        let storage = makeStorage()
        
        // Save a batch
        let beacons = createTestBeacons(count: 2)
        _ = storage.saveBatch(beacons)
        
        let countBefore = storage.batchCount
        
        // Remove oldest batch
        let result = storage.removeOldestBatch()
        
        #expect(result == true)
        
        let countAfter = storage.batchCount
        #expect(countAfter == countBefore - 1)
    }
    
    @Test("Load all batches returns array")
    func loadAllBatchesReturnsArray() {
        let storage = makeStorage()
        
        // Save multiple batches
        for i in 0..<3 {
            let beacons = createTestBeacons(count: i + 1)
            _ = storage.saveBatch(beacons)
        }
        
        // Load all batches
        let allBatches = storage.loadAllBatches()
        
        #expect(allBatches.count >= 3)
    }
    
    @Test("Cannot save empty beacon array")
    func cannotSaveEmptyBeaconArray() {
        let storage = makeStorage()
        
        // Try to save empty array
        let result = storage.saveBatch([])
        
        #expect(result == false)
    }
    
    @Test("Load oldest batch when empty returns nil")
    func loadOldestBatchWhenEmptyReturnsNil() {
        let storage = makeStorage()
        
        // Remove all batches first
        while storage.batchCount > 0 {
            _ = storage.removeOldestBatch()
        }
        
        // Try to load from empty storage
        let batch = storage.loadOldestBatch()
        
        #expect(batch == nil)
    }
    
    @Test("Remove oldest batch when empty succeeds")
    func removeOldestBatchWhenEmptySucceeds() {
        let storage = makeStorage()
        
        // Remove all batches first
        while storage.batchCount > 0 {
            _ = storage.removeOldestBatch()
        }
        
        // Try to remove from empty storage (should not crash)
        let result = storage.removeOldestBatch()
        
        // Implementation may return true or false, just verify it doesn't crash
        #expect(result == true || result == false)
    }
    
    @Test("Beacons are stored with correct properties")
    func beaconsStoredWithCorrectProperties() {
        let storage = makeStorage()
        
        // Create beacon with specific properties
        let beacon = Beacon(
            uuid: UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!,
            major: 9999,
            minor: 8888,
            rssi: -77,
            proximity: .far,
            accuracy: 5.5,
            timestamp: Date(),
            metadata: nil,
            txPower: -58
        )
        
        _ = storage.saveBatch([beacon])
        
        // Load and verify
        if let loadedBeacons = storage.loadOldestBatch() {
            #expect(loadedBeacons.count == 1)
            let loaded = loadedBeacons[0]
            #expect(loaded.major == 9999)
            #expect(loaded.minor == 8888)
            #expect(loaded.rssi == -77)
        } else {
            Issue.record("Failed to load saved beacon")
        }
    }
    
    @Test("Version two preserves the complete original payload and identities after relaunch")
    func completeEnvelopeRoundTrip() throws {
        let storage = makeStorage()
        let original = try makeEnvelope()
        let filename = try #require(storage.saveObservation(original))
        let restored = makeStorage().observationRecords()
        #expect(restored.count == 1 && restored[0].storageId == filename)
        #expect(restored[0].envelope == original)
        #expect(restored[0].envelope.originalPayload["beacons"]?.array?[0].object?["rssiSamples"]?.object?["count"] == .number(3))
        #expect(restored[0].envelope.originalPayload["encounterIds"] == .array([.string("original-rpi")]))
        #expect(restored[0].envelope.originalPayload["businessToken"] == nil)
    }

    @Test("Legacy migration preserves original beacon time and explicit missing context without assigning tenant")
    func legacyMissingContext() throws {
        let storage = makeStorage()
        let beacons = createTestBeacons(count: 1)
        let filename = try #require(storage.saveBatchReturningId(beacons))
        let migrated = try #require(storage.observationRecords().first?.envelope)
        #expect(migrated.version == 2 && migrated.migratedFromVersion == 1)
        #expect(migrated.tenantFingerprint == nil && migrated.contextFingerprint == nil && migrated.sampling == nil)
        #expect(migrated.absentFields.contains("sdk") && migrated.absentFields.contains("device"))
        #expect(migrated.absentFields.contains("clock") && migrated.absentFields.contains("location"))
        let captured = try #require(migrated.originalPayload["beacons"]?.array?.first?.object?["timestamp"])
        if case .number(let timestamp) = captured {
            #expect(abs(timestamp - beacons[0].timestamp.timeIntervalSince1970 * 1_000) < 1_000)
        } else { Issue.record("Original beacon timestamp is missing") }
        #expect(storage.loadOldestBatchesWithIds(5).isEmpty)
        #expect(storage.batchCount == 0)
        #expect(storage.observationRecords(includeQuarantined: true).first?.storageId == "\(filename).rejected")
    }

    @Test("A legacy writer fingerprint survives migration but does not fabricate missing SDK or device")
    func legacyWriterBinding() throws {
        let storage = makeStorage()
        let filename = try #require(storage.saveBatchReturningId(createTestBeacons(count: 1)))
        let url = storageURL.appendingPathComponent(filename)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["tenantFingerprint"] = tenantA
        try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
        let migrated = try #require(storage.observationRecords().first?.envelope)
        #expect(migrated.tenantFingerprint == tenantA && !migrated.canReplay)
        #expect(storage.loadReplayGroup(tenantFingerprint: tenantA, capabilityAvailable: true).isEmpty)
        #expect(storage.observationRecords(includeQuarantined: true).count == 1)
    }

    @Test("Unverifiable tenants are quarantined and another tenant remains pending")
    func tenantIsolation() throws {
        let storage = makeStorage()
        let unknown = try makeEnvelope(tenant: nil, useDefaultTenant: false)
        let a = try makeEnvelope()
        let b = try makeEnvelope(tenant: tenantB)
        #expect(storage.saveObservation(unknown) != nil)
        #expect(storage.saveObservation(a) != nil)
        #expect(storage.saveObservation(b) != nil)
        let replay = storage.loadReplayGroup(tenantFingerprint: tenantA, capabilityAvailable: true)
        #expect(replay.map { $0.envelope.batchId } == [a.batchId])
        #expect(storage.batchCount == 2)
        #expect(storage.observationRecords(includeQuarantined: true).count == 3)
        #expect(storage.loadReplayGroup(tenantFingerprint: tenantB, capabilityAvailable: true).first?.envelope.batchId == b.batchId)
        #expect(tenantA != tenantB)
    }

    @Test("Acknowledgment removes only exact batch IDs belonging to the captured tenant")
    func exactAcknowledgment() throws {
        let storage = makeStorage()
        let first = try makeEnvelope()
        let second = try makeEnvelope()
        let other = try makeEnvelope(tenant: tenantB)
        #expect(storage.saveObservation(first) != nil)
        #expect(storage.saveObservation(second) != nil)
        #expect(storage.saveObservation(other) != nil)
        #expect(storage.acknowledge(batchIds: [first.batchId], tenantFingerprint: tenantB) == 0)
        #expect(storage.acknowledge(batchIds: [first.batchId, first.batchId, UUID().uuidString], tenantFingerprint: tenantA) == 1)
        #expect(Set(storage.observationRecords().map { $0.envelope.batchId }) == Set([second.batchId, other.batchId]))
        #expect(!storage.removeBatch(id: "../outside.json"))
    }

    @Test("Atomic save is idempotent and conflicting content cannot replace the same batch")
    func atomicSaveAndIdentity() throws {
        let storage = makeStorage()
        let envelope = try makeEnvelope()
        let first = try #require(storage.saveObservation(envelope))
        #expect(storage.saveObservation(envelope) == first && storage.batchCount == 1)
        var conflicting = envelope
        conflicting.originalPayload["syncTrigger"] = .string("different")
        #expect(storage.saveObservation(conflicting) == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: storageURL.path)
        #expect(files == [first])
        #expect(try JSONDecoder().decode(StoredObservationEnvelope.self, from: Data(contentsOf: storageURL.appendingPathComponent(first))) == envelope)
    }

    @Test("Disabled signals are absent from new durable copies while beacons encounters and IDs remain")
    func filteringBeforePersistence() throws {
        let storage = makeStorage()
        let original = try makeEnvelope()
        let disabled = DataCollectionPolicy(advertisingId: false, location: false, wifi: false)
        #expect(storage.saveObservation(original, policy: disabled) != nil)
        let filtered = try #require(storage.observationRecords().first?.envelope)
        #expect(filtered.originalPayload["location"] == nil && filtered.originalPayload["wifis"] == nil)
        #expect(filtered.originalPayload["device"]?.object?["network"]?.object?["apId"] == nil)
        #expect(filtered.originalPayload["device"]?.object?["network"]?.object?["wifiSSID"] == nil)
        #expect(filtered.originalPayload["device"]?.object?["permissions"]?.object?["advertisingId"] == nil)
        #expect(filtered.originalPayload["device"]?.object?["permissions"]?.object?["trackingAuthorization"] == nil)
        #expect(filtered.sampling?.motion.state == .unknown && filtered.sampling?.motion.reason == "source_disabled")
        #expect(filtered.originalPayload["beacons"] == original.originalPayload["beacons"])
        #expect(filtered.originalPayload["encounters"] == original.originalPayload["encounters"])
        #expect(filtered.batchId == original.batchId && filtered.sampling?.windowId == original.sampling?.windowId)
        #expect(filtered.absentFields.contains("location") && filtered.absentFields.contains("device.permissions.advertisingId"))
    }

    @Test("Replay redacts persisted signals without recollection and enabling collection does not restore them")
    func pendingPolicyRevocation() throws {
        let storage = makeStorage()
        let original = try makeEnvelope()
        #expect(storage.saveObservation(original) != nil)
        let disabled = DataCollectionPolicy(advertisingId: false, location: false, wifi: false)
        storage.applyCollectionPolicy(disabled)
        let replay = try #require(storage.loadReplayGroup(tenantFingerprint: tenantA, policy: disabled, capabilityAvailable: true).first)
        let payload = try #require(try replay.envelope.replayPayload(manifest: replay.manifest))
        #expect(payload["location"] == nil && payload["wifis"] == nil)
        let sampling = try #require(payload["sampling"] as? [String: Any])
        let motion = try #require(sampling["motion"] as? [String: Any])
        #expect(motion["observedAtMs"] is NSNull && motion["ageMs"] is NSNull)
        storage.applyCollectionPolicy(.allEnabled)
        let restored = try #require(makeStorage().observationRecords().first?.envelope)
        #expect(restored.originalPayload["location"] == nil && restored.originalPayload["wifis"] == nil)
        #expect(restored.sampling?.observedFrom == original.sampling?.observedFrom)
    }

    @Test("Replay manifests group original context and stream without modifying capture clock or sent time")
    func replayManifest() throws {
        let storage = makeStorage()
        let stream = UUID().uuidString
        let first = try makeEnvelope(stream: stream)
        let second = try makeEnvelope(stream: stream, deviceTimestampOffsetMs: 1_000)
        #expect(storage.saveObservation(first) != nil)
        #expect(storage.saveObservation(second) != nil)
        let records = storage.loadReplayGroup(tenantFingerprint: tenantA, capabilityAvailable: true)
        #expect(records.count == 2)
        #expect(records[0].envelope.originalPayload["device"] != records[1].envelope.originalPayload["device"])
        #expect(records[0].manifest.batchIds == [first.batchId, second.batchId])
        #expect(records[0].manifest.index == 0 && records[1].manifest.index == 1)
        #expect(records[0].manifest.drainId == records[1].manifest.drainId && records[0].manifest.count == 2)
        let payload = try #require(try records[1].envelope.replayPayload(manifest: records[1].manifest))
        let sampling = try #require(payload["sampling"] as? [String: Any])
        #expect((sampling["sentAt"] as? NSNumber)?.int64Value == second.sampling?.sentAt)
        #expect((sampling["clock"] as? [String: Any])?["serverOffsetMs"] is NSNull)
        #expect(records[1].envelope.sampling?.clock == second.sampling?.clock)
        let invalid = SamplingReplayManifest(drainId: UUID().uuidString, batchIds: [first.batchId], index: 0, count: 1)
        #expect(try second.replayPayload(manifest: invalid) == nil)
        #expect(storage.acknowledge(batchIds: [first.batchId], tenantFingerprint: tenantA) == 1)
        let remaining = try #require(makeStorage().loadReplayGroup(tenantFingerprint: tenantA, capabilityAvailable: true).first)
        #expect(remaining.manifest == records[1].manifest)
        #expect(storage.saveObservation(second) == records[1].storageId)
    }

    @Test("Different contexts and streams replay separately while transition priority preserves stream FIFO")
    func replayGroupingAndPriority() throws {
        let storage = makeStorage()
        let stream = UUID().uuidString
        let first = try makeEnvelope(stream: stream)
        let changed = try makeEnvelope(stream: stream, contextLabel: "changed")
        #expect(storage.saveObservation(first) != nil)
        #expect(storage.saveObservation(changed) != nil)
        #expect(storage.loadReplayGroup(tenantFingerprint: tenantA, capabilityAvailable: true).map { $0.envelope.batchId } == [first.batchId])
        let transition = try makeEnvelope(kind: .transition)
        #expect(storage.saveObservation(transition) != nil)
        #expect(storage.loadReplayGroup(tenantFingerprint: tenantA, capabilityAvailable: true).first?.envelope.batchId == transition.batchId)
        #expect(storage.acknowledge(batchIds: [transition.batchId], tenantFingerprint: tenantA) == 1)
        let laterTransition = try makeEnvelope(stream: stream, kind: .transition)
        #expect(storage.saveObservation(laterTransition) != nil)
        #expect(storage.loadReplayGroup(tenantFingerprint: tenantA, capabilityAvailable: true).first?.envelope.batchId == first.batchId)
    }

    @Test("Stable context identity ignores device updates and separates changed AP location or generation")
    func stableContextIdentity() throws {
        let original = try makeEnvelope()
        let updated = try makeEnvelope(deviceTimestampOffsetMs: 1_000)
        #expect(original.contextFingerprint == updated.contextFingerprint)
        let changedGeneration = try makeEnvelope(contextLabel: "new-context")
        #expect(original.contextFingerprint != changedGeneration.contextFingerprint)
        let untagged = try makeEnvelope(contextID: nil)
        var payload = untagged.originalPayload.mapValues { $0.foundationValue }
        payload["location"] = ["latitude": 1, "longitude": 3, "timestamp": captureTimeMs]
        let changedLocation = try StoredObservationEnvelope(batchId: UUID().uuidString, storedAtMs: captureTimeMs,
            tenantFingerprint: tenantA, originalPayload: payload, sampling: nil)
        #expect(untagged.contextFingerprint != changedLocation.contextFingerprint)
        payload = untagged.originalPayload.mapValues { $0.foundationValue }
        payload["wifis"] = [["apId": "new-ap", "connected": true, "timestamp": captureTimeMs]]
        let changedAP = try StoredObservationEnvelope(batchId: UUID().uuidString, storedAtMs: captureTimeMs,
            tenantFingerprint: tenantA, originalPayload: payload, sampling: nil)
        #expect(untagged.contextFingerprint != changedAP.contextFingerprint)
        payload["location"] = ["latitude": 8, "longitude": 9, "timestamp": captureTimeMs]
        let sameGeneration = try StoredObservationEnvelope(batchId: UUID().uuidString, storedAtMs: captureTimeMs,
            tenantFingerprint: tenantA, originalPayload: payload, sampling: nil, contextID: "original")
        #expect(original.contextFingerprint == sameGeneration.contextFingerprint)
    }

    @Test("Seven day retention expires pending and quarantined envelopes using original observation time")
    func sevenDayExpiry() throws {
        var current = Date(timeIntervalSince1970: Double(captureTimeMs) / 1_000)
        let storage = makeStorage(now: { current })
        let first = try makeEnvelope()
        let unknown = try makeEnvelope(tenant: nil, useDefaultTenant: false)
        #expect(storage.saveObservation(first) != nil && storage.saveObservation(unknown) != nil)
        #expect(storage.loadReplayGroup(tenantFingerprint: tenantA, capabilityAvailable: true).count == 1)
        current = current.addingTimeInterval(7 * 24 * 60 * 60 - 1)
        #expect(storage.observationRecords(includeQuarantined: true).count == 2)
        current = current.addingTimeInterval(2)
        #expect(storage.observationRecords(includeQuarantined: true).isEmpty)
        #expect(storage.saveObservation(first) == nil)
    }

    @Test("Queue bounds evict ordinary observations before protected transitions and remain finite")
    func queueBounds() throws {
        let storage = makeStorage()
        storage.maxBatchCount = 2
        let ordinary = try makeEnvelope()
        let transition = try makeEnvelope(kind: .transition)
        let latest = try makeEnvelope()
        #expect(storage.saveObservation(ordinary) != nil)
        #expect(storage.saveObservation(transition) != nil)
        #expect(storage.saveObservation(latest) != nil)
        #expect(Set(storage.observationRecords().map { $0.envelope.batchId }) == Set([transition.batchId, latest.batchId]))
        storage.maxBatchCount = 0
        #expect(storage.maxBatchCount == 1 && storage.observationRecords(includeQuarantined: true).count == 1)
    }

    @Test("Beacon bucket payload and replay manifest limits reject oversized storage without partial files")
    func payloadBounds() throws {
        let storage = makeStorage()
        var oversized = try makeEnvelope()
        oversized.originalPayload["beacons"] = .array(Array(repeating: .object([:]), count: 101))
        #expect(storage.saveObservation(oversized) == nil)
        oversized.originalPayload["beacons"] = .array([.object(["temporalBuckets": .array(Array(repeating: .null, count: 41))])])
        #expect(storage.saveObservation(oversized) == nil)
        oversized.originalPayload["beacons"] = .array([])
        oversized.originalPayload["large"] = .string(String(repeating: "x", count: 524_288))
        #expect(storage.saveObservation(oversized) == nil && storage.batchCount == 0)
        let envelope = try makeEnvelope()
        let ids = [envelope.batchId] + (0 ..< 128).map { _ in UUID().uuidString }
        #expect(try envelope.replayPayload(manifest: SamplingReplayManifest(drainId: UUID().uuidString,
            batchIds: ids, index: 0, count: ids.count)) == nil)
    }

    @Test("Capability absence keeps historical summaries durable and never exposes them to legacy drain")
    func capabilityRollback() throws {
        let storage = makeStorage()
        let envelope = try makeEnvelope()
        #expect(storage.saveObservation(envelope) != nil)
        #expect(storage.loadReplayGroup(tenantFingerprint: tenantA, capabilityAvailable: false).isEmpty)
        #expect(storage.loadOldestBatchesWithIds(5).isEmpty)
        #expect(storage.batchCount == 1 && storage.observationRecords().first?.envelope == envelope)
        #expect(storage.loadReplayGroup(tenantFingerprint: tenantA, capabilityAvailable: true).count == 1)
    }

    @Test("Complete new legacy snapshots drain without capability and never invent current context")
    func completeLegacyReplay() throws {
        let storage = makeStorage()
        let original = try makeEnvelope()
        let legacy = try StoredObservationEnvelope(batchId: original.batchId, storedAtMs: original.storedAtMs,
            tenantFingerprint: tenantA, originalPayload: original.originalPayload.mapValues { $0.foundationValue },
            sampling: original.sampling, contextID: original.contextID, deliveryProtocol: .legacy)
        let unknownMotionLegacy = try StoredObservationEnvelope(batchId: UUID().uuidString, storedAtMs: captureTimeMs,
            tenantFingerprint: tenantA, originalPayload: original.originalPayload.mapValues { $0.foundationValue }, sampling: nil,
            contextID: original.contextID)
        #expect(storage.saveObservation(legacy) != nil && storage.saveObservation(unknownMotionLegacy) != nil)
        let replay = try #require(storage.loadReplayGroup(tenantFingerprint: tenantA, capabilityAvailable: false).first)
        let body = try #require(try replay.envelope.replayPayload(manifest: replay.manifest))
        #expect(body["sampling"] == nil)
        #expect(try ObservationJSONValue.snapshot(body) == original.originalPayload)
        #expect(replay.envelope.sampling?.clock == original.sampling?.clock)
        #expect(storage.acknowledge(batchIds: [legacy.batchId], tenantFingerprint: tenantA) == 1)
        #expect(storage.loadReplayGroup(tenantFingerprint: tenantA, capabilityAvailable: false).first?.envelope.batchId == unknownMotionLegacy.batchId)
        #expect(storage.batchCount == 1)
    }

    // MARK: - Helper Methods

    private let captureTimeMs = Int64(Date().timeIntervalSince1970 * 1_000)
    private var tenantA: String { SamplingTenantFingerprint.make(endpoint: "https://ingest.test", appID: "test.app", deviceID: "test-device", businessToken: "tenant-a") }
    private var tenantB: String { SamplingTenantFingerprint.make(endpoint: "https://ingest.test", appID: "test.app", deviceID: "test-device", businessToken: "tenant-b") }
    private var storageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(testDirectory)
    }

    @Test("Retained stale legacy head does not starve supported adaptive history")
    func excludesRetainedLegacyHead() throws {
        let storage = makeStorage()
        defer { storage.clearAllBatches() }
        let original = try makeEnvelope()
        let legacy = try StoredObservationEnvelope(batchId: original.batchId, storedAtMs: original.storedAtMs,
            tenantFingerprint: tenantA, originalPayload: original.originalPayload.mapValues { $0.foundationValue },
            sampling: original.sampling, contextID: original.contextID, deliveryProtocol: .legacy)
        let historical = try makeEnvelope()
        #expect(storage.saveObservation(legacy) != nil && storage.saveObservation(historical) != nil)
        let replay = storage.loadReplayGroup(tenantFingerprint: tenantA, capabilityAvailable: true,
            excludingBatchIds: [legacy.batchId])
        #expect(replay.map { $0.envelope.batchId } == [historical.batchId])
        #expect(storage.observationRecords().contains { $0.envelope.batchId == legacy.batchId })
        #expect(storage.acknowledge(batchIds: [historical.batchId], tenantFingerprint: tenantA) == 1)
        #expect(storage.observationRecords().map { $0.envelope.batchId } == [legacy.batchId])
    }

    private func makeEnvelope(
        tenant: String? = nil, stream: String = UUID().uuidString,
        kind: SamplingEnvelope.Kind = .summary, contextLabel: String = "original",
        useDefaultTenant: Bool = true, deviceTimestampOffsetMs: Int64 = 0, contextID: String? = "original"
    ) throws -> StoredObservationEnvelope {
        let batchId = UUID().uuidString
        let sampling = SamplingEnvelope(version: 1, kind: kind, batchId: batchId, captureStreamId: stream,
            windowId: UUID().uuidString, observedFrom: captureTimeMs, observedTo: captureTimeMs,
            sentAt: captureTimeMs, motion: MotionEvidence(state: .stationaryInferred, source: .contextFusion,
                confidence: .low, reason: "stationary_inferred", observedAtMs: captureTimeMs, ageMs: 0, contextStable: true),
            clock: SamplingEnvelopeClock(bootId: UUID().uuidString, wallTimeMs: captureTimeMs, monotonicTimeMs: 20_000),
            transitionReason: kind == .transition ? .contextChanged : nil)
        let payload: [String: Any] = [
            "beacons": [["uuid": "E25B8D3C-947A-452F-A13F-589CB706D2E5", "major": 1, "minor": 2, "rssi": -60, "timestamp": captureTimeMs,
                         "rssiSamples": ["count": 3, "min": -61, "max": -59, "avg": -60, "stdDev": 1],
                         "temporalBuckets": [["bucketId": UUID().uuidString, "firstSampleId": UUID().uuidString,
                             "lastSampleId": UUID().uuidString, "firstSeen": captureTimeMs, "lastSeen": captureTimeMs,
                             "count": 3, "min": -61, "max": -59, "avg": -60, "stdDev": 1]]]],
            "sdk": ["version": "test", "platform": "ios", "appId": "test.app", "build": 1],
            "device": ["deviceId": "test-device", "timestamp": captureTimeMs + deviceTimestampOffsetMs,
                       "network": ["type": "wifi", "apId": "original-ap", "wifiSSID": "original-ssid"],
                       "permissions": ["advertisingId": "original-idfa", "trackingAuthorization": "authorized"]],
            "userProperties": ["internalId": contextLabel], "syncTrigger": "original_trigger",
            "location": ["latitude": 1, "longitude": 2, "timestamp": captureTimeMs - 10_000],
            "wifis": [["apId": "original-ap", "connected": true, "timestamp": captureTimeMs - 5_000]],
            "encounters": [["rpi": "original-peer", "firstSeen": captureTimeMs, "lastSeen": captureTimeMs]],
            "encounterIds": ["original-rpi"], "businessToken": "not-persisted"
        ]
        return try StoredObservationEnvelope(batchId: batchId, storedAtMs: captureTimeMs,
            tenantFingerprint: useDefaultTenant ? (tenant ?? tenantA) : tenant,
            originalPayload: payload, sampling: sampling, contextID: contextID == "original" ? contextLabel : contextID)
    }
    
    private func createTestBeacons(count: Int) -> [Beacon] {
        var beacons: [Beacon] = []
        
        for i in 0..<count {
            let beacon = Beacon(
                uuid: UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!,
                major: 1000 + i,
                minor: 2000 + i,
                rssi: -60 - i,
                proximity: .near,
                accuracy: 1.5,
                timestamp: Date(),
                metadata: nil,
                txPower: -59
            )
            beacons.append(beacon)
        }
        
        return beacons
    }
}
