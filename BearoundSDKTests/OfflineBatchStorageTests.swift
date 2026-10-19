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


    @Test("Missing legacy motion switch decodes without changing original context fingerprints or queue bytes")
    func legacyMotionSwitchCompatibility() throws {
        let storage = makeStorage()
        let original = try makeEnvelope()
        let id = try #require(storage.saveObservation(original))
        let url = try #require(storage.observationRecords().first).storageId
        #expect(url == id)
        let before = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StoredObservationEnvelope.self, from: before)
        #expect(decoded.capturedPolicy.motionSensors == nil && decoded.capturedPolicy.effectiveMotionSensors)
        #expect(decoded.filtered(policy: .allEnabled) == original)
        storage.applyCollectionPolicy(.allEnabled)
        #expect(storage.observationRecords().first?.envelope == original)
        var allOff = original
        allOff.capturedPolicy.location = false; allOff.capturedPolicy.wifi = false
        let restored = try JSONDecoder().decode(StoredObservationEnvelope.self, from: JSONEncoder().encode(allOff))
        #expect(!restored.capturedPolicy.effectiveMotionSensors)
        #expect(restored.contextFingerprint == original.contextFingerprint)
    }

    @Test("Reserved inertial evidence survives explicit motion opt in without location or wifi and opt out filters replay")
    func motionQueuePolicy() throws {
        let storage = makeStorage()
        var envelope = try makeEnvelope()
        envelope.sampling?.motion = MotionEvidence(state: .movingInferred, source: .contextFusion, confidence: .low,
            reason: "context_changed", observedAtMs: captureTimeMs, ageMs: 0, contextStable: true)
        let onlyMotion = DataCollectionPolicy(location: false, wifi: false, motionSensors: true)
        let stored = envelope.filtered(policy: onlyMotion)
        #expect(stored.sampling?.motion.isInertialInference == true)
        #expect(stored.capturedPolicy.motionSensors == true)
        let id = try #require(storage.saveObservation(stored, policy: onlyMotion))
        let pending = try #require(storage.loadReplayGroup(tenantFingerprint: tenantA, policy: onlyMotion,
            capabilityAvailable: true).first)
        #expect(pending.envelope.sampling?.motion.isInertialInference == true)
        let denied = DataCollectionPolicy(location: false, wifi: false, motionSensors: false)
        let retry = try #require(storage.loadReplayGroup(tenantFingerprint: tenantA, policy: denied,
            capabilityAvailable: true).first)
        #expect(retry.envelope.sampling?.motion.state == .unknown)
        #expect(retry.envelope.batchId == envelope.batchId && retry.envelope.sampling?.clock == envelope.sampling?.clock)
        #expect(retry.envelope.contextFingerprint == stored.contextFingerprint)
        #expect(retry.envelope.sampling?.observedFrom == envelope.sampling?.observedFrom)
        #expect(storage.acknowledge(batchIds: [envelope.batchId], tenantFingerprint: tenantA) == 1)
        #expect(!storage.observationRecords().contains { $0.storageId == id })
    }


    @Test("Negotiated budget skips an oversized original without starving a later compatible replay")
    func replayBudgetForwardProgress() throws {
        let storage = makeStorage(); defer { storage.clearAllBatches() }
        var large = try makeEnvelope(contextLabel: "large")
        large.originalPayload["extra"] = .string(String(repeating: "x", count: 8_000))
        let small = try makeEnvelope(contextLabel: "small")
        #expect(storage.saveObservation(large) != nil && storage.saveObservation(small) != nil)
        let budget = try JSONSerialization.data(withJSONObject: APIClient.observationPayload(small,
            manifest: SamplingReplayManifest(drainId: UUID().uuidString, batchIds: [small.batchId], index: 0, count: 1))).count + 100
        let selected = try #require(storage.loadReplayGroup(tenantFingerprint: tenantA, capabilityAvailable: true,
            maximumJSONBytes: budget).first)
        #expect(selected.envelope.batchId == small.batchId)
        #expect(storage.observationRecords().first { $0.envelope.batchId == large.batchId }?.envelope.originalPayload == large.originalPayload)
        #expect(storage.acknowledge(batchIds: [small.batchId], tenantFingerprint: tenantA) == 1)
        #expect(storage.loadReplayGroup(tenantFingerprint: tenantA, capabilityAvailable: true).first?.envelope.batchId == large.batchId)
    }

    @Test("Rejected diagnostic files have a separate bounded capacity from pending snapshots")
    func rejectedCapacityIsIndependent() throws {
        let storage = makeStorage(); defer { storage.clearAllBatches() }; storage.maxBatchCount = 1
        let first = try makeEnvelope()
        let firstID = try #require(storage.saveObservation(first))
        #expect(storage.quarantineBatch(id: firstID))
        let second = try makeEnvelope()
        #expect(storage.saveObservation(second) != nil)
        #expect(storage.observationRecords().map { $0.envelope.batchId } == [second.batchId])
        #expect(storage.observationRecords(includeQuarantined: true).count == 2)
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

// MARK: - Captured context and retry drain

@Suite("OfflineBatchStorage captured context", .serialized)
struct OfflineBatchCapturedContextTests {

    private let testDirectory = "com.bearound.sdk.test.batches.\(UUID().uuidString)"

    private func makeStorage() -> OfflineBatchStorage {
        OfflineBatchStorage(directoryName: testDirectory)
    }

    /// Built by hand: `DeviceInfoCollector` touches `UNUserNotificationCenter`, which aborts
    /// in this host-less test bundle.
    private func makeDevice(latitude: Double, fixAt: Date) -> UserDevice {
        var device = UserDevice(
            deviceId: "device-1", pushToken: nil, apnsEnvironment: "production", manufacturer: "Apple",
            model: "iPhone17,1", osVersion: "26.0", timestamp: Int(fixAt.timeIntervalSince1970 * 1000),
            timezone: "America/Sao_Paulo", batteryLevel: 80, isCharging: false, bluetoothState: "powered_on",
            locationPermission: "authorized_always", notificationsPermission: "authorized", networkType: "wifi",
            cellularGeneration: nil, ramTotalMb: 8192, ramAvailableMb: 2048, screenWidth: 1206, screenHeight: 2622,
            appInForeground: false, appUptimeMs: 1000, coldStart: false, lowPowerMode: false,
            locationAccuracy: "full", apId: nil, wifiSSID: nil, connectionMetered: false,
            connectionExpensive: false, os: "iOS", deviceName: "iPhone", carrierName: nil,
            availableStorageMb: 10_000, systemLanguage: "pt-BR", thermalState: "nominal", systemUptimeMs: 5000
        )
        device.location = DeviceLocation(latitude: latitude, longitude: -46.6561, accuracy: 12,
                                          timestamp: fixAt, source: "gnss")
        return device
    }

    private func makeBeacons(major: Int) -> [Beacon] {
        [Beacon(uuid: UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!,
                major: major, minor: 1, rssi: -60, proximity: .near, accuracy: 1.5,
                timestamp: Date(), metadata: nil, txPower: -59)]
    }

    private func visitEvent(at date: Date) -> VisitEvent {
        VisitEvent(kind: .arrival, syncTrigger: VisitMonitor.syncTrigger, latitude: -23.5611,
                   longitude: -46.6561, accuracy: 25, timestamp: date, environmentId: nil, source: .clvisit)
    }

    private func storageDirectoryURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(testDirectory)
    }

    @Test("A context-less legacy batch is quarantined without changing a captured main batch")
    func legacyBatchWithoutContextRemainsFailClosed() throws {
        let storage = makeStorage()
        defer { storage.clearAllBatches() }
        let legacyId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        let legacyJSON = """
        {"id":"\(legacyId)","timestamp":"\(now)","beacons":[{"uuid":"E25B8D3C-947A-452F-A13F-589CB706D2E5",\
        "major":7,"minor":8,"rssi":-70,"proximity":2,"accuracy":2.5,"timestamp":"\(now)","txPower":-59}]}
        """
        let legacyName = "\(Int(Date().timeIntervalSince1970) - 10)_\(legacyId).json"
        try Data(legacyJSON.utf8).write(to: storageDirectoryURL().appendingPathComponent(legacyName))
        let captured = makeDevice(latitude: -23.1, fixAt: Date())
        #expect(storage.saveBatch(makeBeacons(major: 1), userDevice: captured, syncTrigger: "precision_high_timer"))

        let records = storage.loadOldestBatchesWithIds(5)
        #expect(records.count == 1)
        let modern = try #require(records.first)
        let modernContext = BeAroundSDK.retryContext(for: modern) {
            Issue.record("captured context must not be replaced at retry time")
            return makeDevice(latitude: -10, fixAt: Date())
        }
        #expect(modernContext.userDevice == captured)
        #expect(modernContext.syncTrigger == "precision_high_timer")
        #expect(storage.observationRecords(includeQuarantined: true).first?.storageId == "\(legacyName).rejected")
    }

    @Test("Draining N batches with different captured context yields N requests, each with its own context")
    func oneRequestPerBatchWithOwnContext() {
        let storage = makeStorage()
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let triggers = ["precision_high_timer", "display_on", "background_ranging_complete"]
        for (index, trigger) in triggers.enumerated() {
            let device = makeDevice(latitude: -23.0 - Double(index), fixAt: base.addingTimeInterval(Double(index) * 60))
            #expect(storage.saveBatch(makeBeacons(major: 100 + index), userDevice: device, syncTrigger: trigger))
        }

        var remaining = storage.loadOldestBatchesWithIds(5)
        var requests: [[OfflineBatchStorage.StoredBatchRecord]] = []
        while !remaining.isEmpty {
            let group = BeAroundSDK.retryGroup(from: remaining)
            requests.append(group)
            remaining.removeFirst(group.count)
        }

        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.count == 1 })
        let sent = requests.map { request in
            BeAroundSDK.retryContext(for: request[0]) {
                Issue.record("no fallback expected for a captured batch")
                return request[0].userDevice!
            }
        }
        #expect(Set(sent.map { $0.syncTrigger }) == Set(triggers))
        #expect(Set(sent.compactMap { $0.userDevice.location?.latitude }) == [-23.0, -24.0, -25.0])
        for (request, context) in zip(requests, sent) {
            #expect(context.syncTrigger == request[0].syncTrigger)
            #expect(context.userDevice == request[0].userDevice)
        }
    }

    @Test("A retried visit keeps syncTrigger visit and the captured fix, not a retry-time location")
    func retriedVisitKeepsTriggerAndLocation() throws {
        let storage = makeStorage()
        let fixAt = Date(timeIntervalSince1970: 1_790_000_000)
        let collected = makeDevice(latitude: -1.0, fixAt: Date())
        let visitDevice = BeAroundSDK.visitUserDevice(for: visitEvent(at: fixAt), collected: collected)
        let id = try #require(storage.saveBatchReturningId([], userDevice: visitDevice, syncTrigger: VisitMonitor.syncTrigger))
        #expect(id.hasSuffix(OfflineBatchStorage.evictionExemptSuffix))

        let record = try #require(storage.loadOldestBatchesWithIds(5).first)
        #expect(record.beacons.isEmpty)
        #expect(BeAroundSDK.retryGroupIsSendable([], head: record))
        let context = BeAroundSDK.retryContext(for: record) {
            Issue.record("a captured visit must not collect a retry-time context")
            return makeDevice(latitude: 50, fixAt: Date())
        }
        #expect(context.syncTrigger == "visit")
        #expect(context.userDevice.location?.latitude == -23.5611)
        #expect(context.userDevice.location?.timestamp == Int(fixAt.timeIntervalSince1970 * 1000))
        #expect(context.userDevice.location?.source == VisitMonitor.locationSource)
    }

    @Test("A visit batch is exempt from the max-count eviction")
    func visitNotEvicted() throws {
        let storage = makeStorage()
        storage.maxBatchCount = 2
        let visitDevice = BeAroundSDK.visitUserDevice(for: visitEvent(at: Date()),
                                                      collected: makeDevice(latitude: 0, fixAt: Date()))
        let visitId = try #require(storage.saveBatchReturningId([], userDevice: visitDevice, syncTrigger: VisitMonitor.syncTrigger))
        for major in 1...4 {
            #expect(storage.saveBatch(makeBeacons(major: major), userDevice: makeDevice(latitude: 1, fixAt: Date()),
                                      syncTrigger: "precision_high_timer"))
        }

        let records = storage.loadOldestBatchesWithIds(10)
        #expect(records.contains { $0.id == visitId && $0.syncTrigger == "visit" })
        #expect(records.filter { $0.id != visitId }.count == 2)
        #expect(storage.batchCount == 3)
    }
    @Test("Captured visits retain priority and context beside adaptive envelopes after relaunch")
    func capturedVisitAndAdaptiveQueueStaySeparate() async throws {
        let storage = makeStorage()
        defer { storage.clearAllBatches() }
        storage.maxBatchCount = 2
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let id = UUID().uuidString
        let clock = SamplingClock(wallTimeMs: now, monotonicTimeMs: 10_000, bootIdentifier: "fixture-boot")
        let sampling = SamplingEnvelope(version: 1, kind: .summary, batchId: id,
            captureStreamId: UUID().uuidString, windowId: UUID().uuidString,
            observedFrom: now, observedTo: now, sentAt: now,
            motion: MotionEvidence(state: .unknown, source: .none, confidence: .none,
                reason: "no_evidence", observedAtMs: nil, ageMs: nil, contextStable: false),
            clock: SamplingEnvelopeClock(bootId: clock.bootIdentifier, wallTimeMs: now, monotonicTimeMs: 10_000))
        let tenant = String(repeating: "a", count: 64)
        let envelope = try StoredObservationEnvelope(batchId: id, storedAtMs: now, tenantFingerprint: tenant,
            originalPayload: ["sdk": ["appId": "fixture-app"], "device": ["deviceId": "fixture-device"],
                "beacons": [["uuid": UUID().uuidString, "major": 1, "minor": 1, "timestamp": now]]], sampling: sampling)
        #expect(storage.saveObservation(envelope) != nil)
        let fix = Date().addingTimeInterval(-90)
        var visit = BeAroundSDK.visitUserDevice(for: visitEvent(at: fix), collected: makeDevice(latitude: 0, fixAt: Date()))
        visit.wifis = [WifiObservation(apId: "fixture-ap", ssid: "fixture-wifi", rssi: nil, connected: true,
            frequencyMhz: nil, timestamp: Int(fix.timeIntervalSince1970 * 1_000))]
        let visitId = try #require(storage.saveBatchReturningId([], userDevice: visit, syncTrigger: "visit"))
        let restored = makeStorage()
        let captured = try #require(restored.loadOldestBatchesWithIds(1).first)
        #expect(captured.id == visitId && captured.userDevice == visit && captured.syncTrigger == "visit")
        #expect(restored.observationRecords().map { $0.envelope.batchId } == [id])
        let replay = try #require(restored.loadReplayGroup(tenantFingerprint: tenant, capabilityAvailable: true).first)
        #expect(replay.envelope.batchId == id && replay.envelope.originalPayload == envelope.originalPayload)
        let context = BeAroundSDK.retryContext(for: captured) {
            Issue.record("a captured visit must never collect a replacement fix")
            return makeDevice(latitude: 80, fixAt: Date())
        }
        let client = APIClient(configuration: SDKConfiguration(businessToken: "fixture-captured-visit"))
        client.submissionContextProvider = { $0(RequestSubmissionContext(policy: .allEnabled)) }
        var submissions = 0
        var reconciliation: ObservationDeliveryReconciliation?
        client.transport = { _, data, path, descriptor, submit, finish in
            submissions += 1
            #expect(path == .immediateFirst)
            #expect(descriptor.adaptiveBatchId == nil && descriptor.tenantFingerprint == nil)
            #expect(descriptor.storageIds == [visitId])
            reconciliation = descriptor
            do {
                let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                #expect(payload["sampling"] == nil && payload["syncTrigger"] as? String == "visit")
                #expect((payload["beacons"] as? [Any])?.isEmpty == true)
                let location = try #require(payload["location"] as? [String: Any])
                #expect(location["latitude"] as? Double == -23.5611)
                #expect((location["timestamp"] as? NSNumber)?.intValue == Int(fix.timeIntervalSince1970 * 1_000))
                let wifi = try #require((payload["wifis"] as? [[String: Any]])?.first)
                #expect(wifi["apId"] as? String == "fixture-ap")
                #expect((wifi["timestamp"] as? NSNumber)?.intValue == Int(fix.timeIntervalSince1970 * 1_000))
            } catch { Issue.record(error) }
            #expect(submit())
            finish(.success(Data("{}".utf8)))
        }
        let delivered: Result<Void, Error> = await withCheckedContinuation { continuation in
            client.sendBeacons([], sdkInfo: SDKInfo(appId: "fixture-app", build: 1), userDevice: context.userDevice,
                userProperties: nil, syncTrigger: context.syncTrigger, delivery: .immediateFirst,
                persistedBatchIds: [visitId]) { continuation.resume(returning: $0) }
        }
        _ = try delivered.get()
        #expect(submissions == 1)
        let descriptor = try #require(reconciliation)
        let description = try #require(String(data: JSONEncoder().encode(descriptor), encoding: .utf8))
        #expect(BackgroundSessionManager.reconcileObservation(description: description, responseBody: Data("{}".utf8),
            successful: true, storage: restored) == 1)
        #expect(restored.loadOldestBatchesWithIds(1).isEmpty)
        #expect(restored.observationRecords().map { $0.envelope.batchId } == [id])
        #expect(restored.acknowledge(batchIds: [id], tenantFingerprint: tenant) == 1)
        #expect(restored.batchCount == 0)
    }




    #if DEBUG
    private final class SyncDelegate: BeAroundSDKDelegate {
        var starts = 0
        var completion: ((Bool, Error?) -> Void)?
        func didUpdateBeacons(_ beacons: [Beacon]) {}
        func willStartSync(beaconCount: Int) { starts += 1 }
        func didCompleteSync(beaconCount: Int, success: Bool, error: Error?) { completion?(success, error) }
    }

    @Test("A nil adaptive runtime still sends frozen legacy data and balances delegate terminals")
    func nilRuntimeLegacyTerminal() async throws {
        let storage = makeStorage(); defer { storage.clearAllBatches() }
        let configuration = SDKConfiguration(businessToken: "fixture-nil-runtime", adaptiveSamplingEnabled: false)
        let client = APIClient(configuration: configuration)
        let sdk = BeAroundSDK.samplingTransportFixture(configuration: configuration, client: client,
            storage: storage, withRuntime: false)
        let delegate = SyncDelegate(); sdk.delegate = delegate
        let now = Date(); let device = makeDevice(latitude: -23.1, fixAt: now)
        client.transport = { _, data, _, _, submit, finish in
            #expect(submit())
            let payload = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            #expect(payload["sampling"] == nil)
            #expect((payload["location"] as? [String: Any])?["latitude"] as? Double == -23.1)
            sdk.endSamplingFixture()
            finish(.success(Data("{}".utf8)))
        }
        let successful: Bool = await withCheckedContinuation { continuation in
            delegate.completion = { success, error in #expect(error == nil); continuation.resume(returning: success) }
            sdk.syncSamplingFixture(beacons: makeBeacons(major: 1), device: device)
        }
        #expect(successful && delegate.starts == 1)
        #expect(storage.batchCount == 0)
    }

    @Test("Foreground retains negotiated runtime and exact ownership of an in flight upload")
    func foregroundUploadOwnership() async throws {
        let storage = makeStorage(); defer { storage.clearAllBatches() }
        let configuration = SDKConfiguration(businessToken: "fixture-foreground")
        let client = APIClient(configuration: configuration)
        let sdk = BeAroundSDK.samplingTransportFixture(configuration: configuration, client: client, storage: storage)
        let now = SamplingClock.now()
        let device = makeDevice(latitude: -23.1, fixAt: Date())
        let beacon = makeBeacons(major: 1)[0]
        let payload = APIClient.makeObservationPayload([beacon], sdkInfo: SDKInfo(appId: configuration.appId, build: 1),
            userDevice: device, userProperties: nil, syncTrigger: "fixture-original")
        let original: (AdaptiveSamplingRuntime, StoredObservationEnvelope) = try await withCheckedThrowingContinuation { continuation in
            sdk.inspectSamplingFixture { runtime, _ in
                do {
                    let runtime = try #require(runtime)
                    let response: [String: Any] = ["capabilities": ["adaptiveSampling": ["version": 1,
                        "modes": ["live", "summary", "transition"], "leaseMs": 300000, "serverTimeMs": now.wallTimeMs,
                        "servicesCadenceMs": 5000, "mapTtlMs": 90000, "sessionTimeoutMs": 1800000,
                        "liveEvidenceMaxAgeMs": 30000, "clockSkewToleranceMs": 120000, "maxPayloadBytes": 524288]]]
                    runtime.acceptResponse(try JSONSerialization.data(withJSONObject: response), requestedAt: now,
                        receivedAt: now, generation: runtime.generation)
                    continuation.resume(returning: (runtime, try runtime.legacyEnvelope(beacons: [beacon], payload: payload, at: now)))
                } catch { continuation.resume(throwing: error) }
            }
        }
        let id = try #require(storage.saveObservation(original.1))
        var requests = 0
        let finish: (Result<Data, Error>) -> Void = await withCheckedContinuation { continuation in
            client.transport = { _, _, _, _, submit, finish in
                #expect(submit()); requests += 1; continuation.resume(returning: finish)
            }
            sdk.submitSamplingFixture(original.1, storageID: id)
        }
        sdk.foregroundSamplingFixture()
        await withCheckedContinuation { continuation in
            sdk.inspectSamplingFixture { runtime, syncing in
                #expect(runtime === original.0 && syncing && runtime?.hasCapability(at: SamplingClock.now()) == true)
                #expect(requests == 1); continuation.resume()
            }
        }
        let delegate = SyncDelegate(); sdk.delegate = delegate
        let completion: Bool = await withCheckedContinuation { continuation in
            delegate.completion = { success, error in
                guard let error = error as? APIError, case .httpError(let status, _) = error else { Issue.record("Original transport error must reach delegate"); continuation.resume(returning: false); return }
                #expect(status == 429); continuation.resume(returning: success)
            }
            sdk.endSamplingFixture(); finish(.failure(APIError.httpError(statusCode: 429)))
        }
        #expect(!completion && requests == 1 && storage.batchCount == 1)
    }


    @Test("SDK legacy capture retains the main grace window without adaptive capability", arguments: [false, true], [31, 60, 119])
    func legacySourceAgeSDK(enabled: Bool, age: Int) async throws {
        let storage = makeStorage(); defer { storage.clearAllBatches() }
        let configuration = SDKConfiguration(businessToken: "fixture-source-age", scanPrecision: .medium,
            adaptiveSamplingEnabled: enabled)
        let client = APIClient(configuration: configuration)
        let sdk = BeAroundSDK.samplingTransportFixture(configuration: configuration, client: client, storage: storage)
        let captured = Date().addingTimeInterval(-Double(age))
        let beacon = Beacon(uuid: BeaconConstants.uuid, major: 1, minor: 1, rssi: -60, proximity: .near,
            accuracy: 1, timestamp: captured)
        let delegate = SyncDelegate(); sdk.delegate = delegate
        client.transport = { _, data, _, _, submit, finish in
            #expect(submit())
            let body = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            #expect(body["sampling"] == nil)
            let beacons = body["beacons"] as! [[String: Any]]
            #expect(beacons.count == 1)
            #expect((beacons[0]["timestamp"] as! NSNumber).int64Value == Int64(captured.timeIntervalSince1970 * 1_000))
            sdk.endSamplingFixture(); finish(.success(Data("{}".utf8)))
        }
        let delivered: Bool = await withCheckedContinuation { continuation in
            delegate.completion = { success, error in #expect(error == nil); continuation.resume(returning: success) }
            sdk.syncSamplingFixture(beacons: [beacon], device: makeDevice(latitude: -23.1, fixAt: captured))
        }
        #expect(delivered && delegate.starts == 1 && storage.batchCount == 0)
    }

    @Test("SDK physical callback preserves legacy provenance before persistence capacity returns")
    func physicalCallbackAtPersistenceCapacity() async throws {
        let storage = makeStorage(); defer { storage.clearAllBatches() }
        let configuration = SDKConfiguration(businessToken: "fixture-capacity")
        let client = APIClient(configuration: configuration)
        let sdk = BeAroundSDK.samplingTransportFixture(configuration: configuration, client: client, storage: storage)
        let beacon = makeBeacons(major: 1)[0]
        let payload = APIClient.makeObservationPayload([beacon], sdkInfo: SDKInfo(appId: configuration.appId, build: 1),
            userDevice: makeDevice(latitude: -23.1, fixAt: Date()), userProperties: nil, syncTrigger: "fixture")
        let pending = try StoredObservationEnvelope(batchId: UUID().uuidString, storedAtMs: SamplingClock.now().wallTimeMs,
            tenantFingerprint: SamplingTenantFingerprint.make(endpoint: configuration.apiBaseURL, appID: configuration.appId,
                deviceID: "device-1", businessToken: configuration.businessToken), originalPayload: payload,
            sampling: nil, deliveryProtocol: .legacy)
        await withCheckedContinuation { continuation in
            sdk.captureAtCapacitySamplingFixture([beacon], pending: pending) { runtime in
                #expect(runtime?.legacyEvidenceIsSendable(beacon, at: SamplingClock.now()) == true)
                #expect(runtime?.diagnostics.uniqueSamples == 0)
                continuation.resume()
            }
        }
        sdk.endSamplingFixture()
    }

    @Test("SDK durable legacy drain delivers an original sixty second snapshot after relaunch without capability", arguments: [false, true])
    func durableLegacySDKDrain(enabled: Bool) async throws {
        let storage = makeStorage(); defer { storage.clearAllBatches() }
        let configuration = SDKConfiguration(businessToken: "fixture-old-legacy", adaptiveSamplingEnabled: enabled)
        let before = Date().addingTimeInterval(-60)
        let capturedClock = SamplingClock(wallTimeMs: Int64(before.timeIntervalSince1970 * 1_000),
            monotonicTimeMs: 1_000_000, bootIdentifier: UUID().uuidString)
        let device = makeDevice(latitude: -23.1, fixAt: before)
        let beacon = Beacon(uuid: BeaconConstants.uuid, major: 1, minor: 1, rssi: -60, proximity: .near,
            accuracy: 1, timestamp: before)
        let payload = APIClient.makeObservationPayload([beacon], sdkInfo: SDKInfo(appId: configuration.appId, build: 1),
            userDevice: device, userProperties: UserProperties(internalId: "original-user"), syncTrigger: "original-timer")
        let oldRuntime = AdaptiveSamplingRuntime(configuration: configuration, deviceID: device.deviceId)
        let envelope = try oldRuntime.legacyEnvelope(beacons: [beacon], payload: payload, at: capturedClock)
        #expect(storage.saveObservation(envelope) != nil)
        let restored = makeStorage()
        let client = APIClient(configuration: configuration)
        let sdk = BeAroundSDK.samplingTransportFixture(configuration: configuration, client: client, storage: restored)
        let delegate = SyncDelegate(); sdk.delegate = delegate
        client.transport = { _, data, _, descriptor, submit, finish in
            #expect(submit() && descriptor.adaptiveBatchId == nil)
            let body = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            #expect(body["sampling"] == nil && body["syncTrigger"] as? String == "original-timer")
            #expect((body["userProperties"] as? [String: Any])?["internalId"] as? String == "original-user")
            let seen = (body["beacons"] as! [[String: Any]])[0]["timestamp"] as! NSNumber
            #expect(seen.int64Value == capturedClock.wallTimeMs)
            #expect(((body["location"] as! [String: Any])["timestamp"] as! NSNumber).int64Value == capturedClock.wallTimeMs)
            sdk.endSamplingFixture(); finish(.success(Data("{}".utf8)))
        }
        let delivered: Bool = await withCheckedContinuation { continuation in
            delegate.completion = { success, error in #expect(error == nil); continuation.resume(returning: success) }
            sdk.replaySamplingFixture()
        }
        #expect(delivered && restored.batchCount == 0)
    }

    // MARK: Retry drain and an upload still in flight

    /// What the fixture transport saw, plus the background uploads it is still holding (an
    /// upload the OS deferred).
    private final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(path: DeliveryPath, ids: [String])] = []
        private var held: [(Result<Data, Error>) -> Void] = []

        func record(_ path: DeliveryPath, _ ids: [String]) {
            lock.lock(); calls.append((path, ids)); lock.unlock()
        }
        func hold(_ finish: @escaping (Result<Data, Error>) -> Void) {
            lock.lock(); held.append(finish); lock.unlock()
        }
        func count(_ path: DeliveryPath, _ id: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return calls.filter { $0.path == path && $0.ids.contains(id) }.count
        }
        var heldCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }
        func releaseHeld(_ result: Result<Data, Error>) {
            lock.lock(); let pending = held; held.removeAll(); lock.unlock()
            pending.forEach { $0(result) }
        }
    }

    private func eventually(_ condition: @escaping () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    private func isSyncing(_ sdk: BeAroundSDK) async -> Bool {
        await withCheckedContinuation { continuation in
            sdk.inspectSamplingFixture { _, syncing in continuation.resume(returning: syncing) }
        }
    }

    private func drain(_ sdk: BeAroundSDK, timeout: TimeInterval = 2) async -> Bool {
        await withCheckedContinuation { continuation in
            sdk.drainSamplingFixture(timeout: timeout) { continuation.resume(returning: $0) }
        }
    }

    /// A transport whose immediate attempt loses the response (the client then falls back to
    /// the background session) and whose background upload the OS holds until released.
    private func lossyTransport(_ wire: Wire) -> APIClient.Transport {
        { _, _, path, descriptor, submit, finish in
            guard submit() else { finish(.failure(APIError.invalidResponse)); return }
            wire.record(path, descriptor.storageIds)
            if path == .immediateFirst {
                finish(.failure(URLError(.networkConnectionLost)))
            } else {
                wire.hold(finish)
            }
        }
    }

    private func queuedDeparture(in storage: OfflineBatchStorage) throws -> String {
        let departure = BeAroundSDK.visitUserDevice(
            for: event(.departure, at: Date().addingTimeInterval(-30), environmentId: "env-1", source: .fence),
            collected: makeDevice(latitude: 0, fixAt: Date()))
        return try #require(storage.saveBatchReturningId([], userDevice: departure, syncTrigger: VisitMonitor.syncTrigger))
    }

    @Test("A visit whose upload is still pending is not submitted again once the drain is released",
          arguments: ["watchdog", "reconfigure"])
    func pendingUploadIsNotResubmitted(release: String) async throws {
        let storage = makeStorage(); defer { storage.clearAllBatches() }
        let configuration = SDKConfiguration(businessToken: "fixture-pending-upload-\(release)")
        let client = APIClient(configuration: configuration)
        let sdk = BeAroundSDK.samplingTransportFixture(configuration: configuration, client: client, storage: storage)
        defer { sdk.endSamplingFixture() }
        let visitId = try queuedDeparture(in: storage)
        let wire = Wire()
        client.transport = lossyTransport(wire)
        if release == "watchdog" { sdk.syncWatchdogTimeoutFixture(0.2) }

        sdk.replaySamplingFixture()
        #expect(await eventually { wire.heldCount == 1 })
        if release == "reconfigure" { sdk.reconfigureSamplingFixture() }
        #expect(await eventually { await !self.isSyncing(sdk) })

        // The next drain (any later sync tick) must leave the pending upload alone.
        #expect(await drain(sdk))
        #expect(wire.count(.immediateFirst, visitId) == 1)
        #expect(wire.count(.background, visitId) == 1)
        #expect(storage.batchCount == 1)

        // The deferred upload completes once the network is back: the batch is removed and
        // no later drain sends it.
        wire.releaseHeld(.success(Data("{}".utf8)))
        #expect(await eventually { storage.batchCount == 0 })
        #expect(await drain(sdk))
        #expect(wire.count(.immediateFirst, visitId) == 1)
        #expect(wire.count(.background, visitId) == 1)
    }

    @Test("An upload a previous process left in the background session holds its batch, not the ones behind it")
    func orphanedUploadHoldsOnlyItsBatch() async throws {
        let storage = makeStorage(); defer { storage.clearAllBatches() }
        let configuration = SDKConfiguration(businessToken: "fixture-orphaned-upload")
        let client = APIClient(configuration: configuration)
        let sdk = BeAroundSDK.samplingTransportFixture(configuration: configuration, client: client, storage: storage)
        defer { sdk.endSamplingFixture() }
        let orphanedId = try queuedDeparture(in: storage)
        let behindId = try queuedDeparture(in: storage)
        let wire = Wire()
        client.transport = { _, _, path, descriptor, submit, finish in
            #expect(submit())
            wire.record(path, descriptor.storageIds)
            finish(.success(Data("{}".utf8)))
        }
        client.outstandingUploads = { $0([orphanedId]) }

        #expect(await eventually { await self.drain(sdk) && storage.batchCount == 1 })
        #expect(wire.count(.immediateFirst, behindId) == 1)
        #expect(wire.count(.immediateFirst, orphanedId) == 0)
        #expect(await drain(sdk))
        #expect(wire.count(.immediateFirst, orphanedId) == 0)

        // The session no longer holds it (its upload failed): the batch drains again.
        client.outstandingUploads = { $0([]) }
        #expect(await eventually { await self.drain(sdk) && storage.batchCount == 0 })
        #expect(wire.count(.immediateFirst, orphanedId) == 1)
        #expect(wire.count(.immediateFirst, behindId) == 1)
    }

    // MARK: In-flight marks

    @Test("A submission marks its batch in flight until its final result, and a refused one releases it")
    func submissionMarksBatchInFlight() async throws {
        let device = BeAroundSDK.visitUserDevice(
            for: event(.departure, at: Date(), environmentId: "env-1", source: .fence),
            collected: makeDevice(latitude: 0, fixAt: Date()))
        let client = APIClient(configuration: SDKConfiguration(businessToken: "fixture-in-flight"))
        let send: (String) async -> Result<Void, Error> = { id in
            await withCheckedContinuation { continuation in
                client.sendBeacons([], sdkInfo: SDKInfo(appId: "fixture-app", build: 1), userDevice: device,
                    userProperties: nil, syncTrigger: VisitMonitor.syncTrigger, delivery: .immediateFirst,
                    persistedBatchIds: [id]) { continuation.resume(returning: $0) }
            }
        }

        let refusedId = UUID().uuidString
        client.submissionContextProvider = { $0(nil) }
        await #expect(throws: (any Error).self) { try await send(refusedId).get() }
        #expect(!InFlightDeliveries.shared.ids.contains(refusedId))

        let heldId = UUID().uuidString
        client.submissionContextProvider = { $0(RequestSubmissionContext(policy: .allEnabled)) }
        let wire = Wire()
        client.transport = lossyTransport(wire)
        let delivered = Task { await send(heldId) }
        #expect(await eventually { wire.heldCount == 1 })
        #expect(InFlightDeliveries.shared.ids.contains(heldId))
        wire.releaseHeld(.success(Data("{}".utf8)))
        _ = try await delivered.value.get()
        #expect(!InFlightDeliveries.shared.ids.contains(heldId))
    }

    @Test("Upload task descriptions name their persisted batches in both formats")
    func taskDescriptionStorageIds() throws {
        let descriptor = ObservationDeliveryReconciliation(storageIds: ["a.visit.json", "b.json"],
            tenantFingerprint: nil, adaptiveBatchId: nil)
        let json = try #require(String(data: JSONEncoder().encode(descriptor), encoding: .utf8))
        #expect(BackgroundSessionManager.storageIds(taskDescription: json) == ["a.visit.json", "b.json"])
        #expect(BackgroundSessionManager.storageIds(taskDescription: "a.json,b.json") == ["a.json", "b.json"])
        #expect(BackgroundSessionManager.storageIds(taskDescription: "{not json").isEmpty)
        #expect(BackgroundSessionManager.storageIds(taskDescription: nil).isEmpty)
    }

    @Test("A background session that never answers does not stall the drain")
    func pendingDeliveryIdsTimesOut() async {
        let client = APIClient(configuration: SDKConfiguration(businessToken: "fixture-silent-session"))
        client.outstandingUploads = { _ in }
        let id = UUID().uuidString
        InFlightDeliveries.shared.begin([id]); defer { InFlightDeliveries.shared.end([id]) }
        let pending: Set<String> = await withCheckedContinuation { continuation in
            client.pendingDeliveryIds(timeout: 0.1) { continuation.resume(returning: $0) }
        }
        #expect(pending.contains(id))
    }

    #endif


    // MARK: Visit block (kind, environmentId, source, at)

    private func event(_ kind: VisitEventKind, at date: Date, environmentId: String?, source: VisitEventSource,
                       accuracy: Double? = 12) -> VisitEvent {
        VisitEvent(kind: kind, syncTrigger: VisitMonitor.syncTrigger, latitude: -23.5621, longitude: -46.6571,
                   accuracy: accuracy, timestamp: date, environmentId: environmentId, source: source)
    }

    /// The body the ingest receives for one visit event, through the same envelope and policy
    /// filter the send path uses.
    private func wireBody(_ event: VisitEvent, policy: DataCollectionPolicy = .allEnabled) throws -> [String: Any] {
        let device = BeAroundSDK.visitUserDevice(for: event, collected: makeDevice(latitude: 0, fixAt: Date()))
        let payload = APIClient.makeObservationPayload([], sdkInfo: SDKInfo(appId: "fixture-app", build: 1),
            userDevice: device, userProperties: nil, syncTrigger: VisitMonitor.syncTrigger)
        let envelope = try StoredObservationEnvelope(batchId: UUID().uuidString, storedAtMs: 1_790_000_000_000,
            tenantFingerprint: nil, originalPayload: payload, sampling: nil, deliveryProtocol: .legacy)
        let data = try JSONSerialization.data(withJSONObject: APIClient.observationPayload(envelope, policy: policy))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("A fence arrival and its departure carry kind, environmentId, source and the fix time on the wire")
    func fenceVisitBlockOnWire() throws {
        let arrivalAt = Date(timeIntervalSince1970: 1_790_000_000)
        let departureAt = arrivalAt.addingTimeInterval(12 * 60)

        let arrival = try wireBody(event(.arrival, at: arrivalAt, environmentId: "env-1", source: .fence))
        let arrivalVisit = try #require(arrival["visit"] as? [String: Any])
        #expect(arrivalVisit["kind"] as? String == "arrival")
        #expect(arrivalVisit["environmentId"] as? String == "env-1")
        #expect(arrivalVisit["source"] as? String == "fence")
        #expect((arrivalVisit["at"] as? NSNumber)?.int64Value == 1_790_000_000_000)
        #expect(arrival["syncTrigger"] as? String == "visit")
        // The block rides at the top, never inside `device`.
        #expect((arrival["device"] as? [String: Any])?["visit"] == nil)

        let departure = try wireBody(event(.departure, at: departureAt, environmentId: "env-1", source: .fence))
        let departureVisit = try #require(departure["visit"] as? [String: Any])
        #expect(departureVisit["kind"] as? String == "departure")
        #expect(departureVisit["environmentId"] as? String == "env-1")
        #expect(departureVisit["source"] as? String == "fence")
        let location = try #require(departure["location"] as? [String: Any])
        #expect((location["accuracy"] as? NSNumber)?.doubleValue == 12)
        #expect((location["timestamp"] as? NSNumber)?.int64Value == (departureVisit["at"] as? NSNumber)?.int64Value)
        #expect(Set(departure.keys) == ["beacons", "device", "location", "sdk", "syncTrigger", "visit"])
    }

    @Test("A CLVisit stop sends environmentId as an explicit null")
    func clvisitVisitBlockHasNullEnvironment() throws {
        let body = try wireBody(event(.arrival, at: Date(timeIntervalSince1970: 1_790_000_000),
                                      environmentId: nil, source: .clvisit, accuracy: 25))
        let visit = try #require(body["visit"] as? [String: Any])
        #expect(visit["source"] as? String == "clvisit")
        #expect(visit["kind"] as? String == "arrival")
        #expect(visit.keys.contains("environmentId"))
        #expect(visit["environmentId"] is NSNull)
    }

    @Test("The visit block survives the offline batch and is replayed as captured")
    func visitBlockSurvivesPersistence() throws {
        let storage = makeStorage()
        defer { storage.clearAllBatches() }
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let arrival = event(.arrival, at: at, environmentId: "env-1", source: .fence)
        let departure = event(.departure, at: at.addingTimeInterval(600), environmentId: "env-1", source: .fence)
        let collected = makeDevice(latitude: 0, fixAt: Date())
        for visitEvent in [arrival, departure] {
            let device = BeAroundSDK.visitUserDevice(for: visitEvent, collected: collected)
            #expect(storage.saveBatchReturningId([], userDevice: device, syncTrigger: VisitMonitor.syncTrigger) != nil)
        }

        let records = makeStorage().loadOldestBatchesWithIds(5)
        #expect(records.compactMap { $0.userDevice?.visit } == [VisitPayload(arrival), VisitPayload(departure)])
        // Two events never share a retry request, so each keeps its own block.
        #expect(BeAroundSDK.retryGroup(from: records).count == 1)
        let context = BeAroundSDK.retryContext(for: records[0]) {
            Issue.record("a captured visit must not collect a retry-time context")
            return collected
        }
        #expect(context.userDevice.visit == VisitPayload(arrival))
    }

    @Test("A batch persisted before the visit block decodes with none")
    func legacyVisitBatchHasNoBlock() throws {
        var device = makeDevice(latitude: -23.1, fixAt: Date())
        let encoded = try JSONEncoder().encode(device)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["visit"] == nil)
        object.removeValue(forKey: "visit")
        device = try JSONDecoder().decode(UserDevice.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(device.visit == nil)
    }

    @Test("Location off strips the visit block; Wi-Fi off strips only a Wi-Fi visit")
    func policyStripsVisitBlock() throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let noLocation = DataCollectionPolicy(advertisingId: true, location: false, wifi: true)
        let noWifi = DataCollectionPolicy(wifi: false)

        #expect(try wireBody(event(.arrival, at: at, environmentId: "env-1", source: .fence), policy: noLocation)["visit"] == nil)
        #expect(try wireBody(event(.arrival, at: at, environmentId: "env-1", source: .fence), policy: noWifi)["visit"] != nil)
        let wifiEvent = VisitEvent(kind: .arrival, syncTrigger: VisitMonitor.syncTrigger, latitude: nil, longitude: nil,
                                   accuracy: nil, timestamp: at, environmentId: "env-wifi", source: .wifi)
        #expect(try wireBody(wifiEvent)["visit"] != nil)
        #expect(try wireBody(wifiEvent, policy: noWifi)["visit"] == nil)
    }
}
