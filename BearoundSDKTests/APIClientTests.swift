//
//  APIClientTests.swift
//  BearoundSDKTests
//
//  Tests for API communication
//

import CoreLocation
import Foundation
import Testing

@testable import BearoundSDK

@Suite("APIClient Tests", .serialized)
struct APIClientTests {

    private func immutableEnvelope(protocol delivery: StoredObservationEnvelope.DeliveryProtocol = .adaptive) throws -> StoredObservationEnvelope {
        let id = UUID().uuidString
        let timestamp: Int64 = 1_791_907_200_000
        let sampling = SamplingEnvelope(version: 1, kind: .live, batchId: id, captureStreamId: UUID().uuidString,
            windowId: UUID().uuidString, observedFrom: timestamp, observedTo: timestamp, sentAt: timestamp,
            motion: MotionEvidence(state: .unknown, source: .none, confidence: .none, reason: "no_evidence",
                observedAtMs: nil, ageMs: nil, contextStable: false),
            clock: SamplingEnvelopeClock(bootId: UUID().uuidString, wallTimeMs: timestamp, monotonicTimeMs: 1_000_000))
        return try StoredObservationEnvelope(batchId: id, storedAtMs: timestamp, tenantFingerprint: String(repeating: "a", count: 64),
            originalPayload: ["sdk": ["version": "test", "platform": "ios", "appId": "original.app", "build": 1],
                "device": ["deviceId": "original.device", "timestamp": timestamp], "syncTrigger": "original-trigger",
                "beacons": [["uuid": UUID().uuidString, "major": 1, "minor": 2, "rssi": -70, "accuracy": -1,
                    "timestamp": timestamp, "sampleId": UUID().uuidString, "bucketId": UUID().uuidString, "sampleOrdinal": 1]]],
            sampling: sampling, contextID: "original", deliveryProtocol: delivery)
    }

    @Test("Replay serializer preserves original clock sentAt IDs trigger context and explicit absence")
    func immutableReplaySerialization() throws {
        let envelope = try immutableEnvelope()
        let manifest = SamplingReplayManifest(drainId: UUID().uuidString, batchIds: [envelope.batchId], index: 0, count: 1)
        let body = try APIClient.observationPayload(envelope, manifest: manifest)
        let wire = try #require(body["sampling"] as? [String: Any])
        let decoded = try JSONDecoder().decode(SamplingEnvelope.self, from: JSONSerialization.data(withJSONObject: wire))
        #expect(decoded.sentAt == envelope.sampling?.sentAt && decoded.clock == envelope.sampling?.clock)
        #expect(decoded.batchId == envelope.batchId && decoded.replay == manifest)
        #expect(body["location"] == nil && body["wifis"] == nil && body["userProperties"] == nil)
        #expect(body["syncTrigger"] as? String == "original-trigger")
        #expect((body["device"] as? [String: Any])?["deviceId"] as? String == "original.device")
    }

    @Test("Captured legacy retry remains legacy and cannot acquire new sampling context")
    func legacySerializer() throws {
        let envelope = try immutableEnvelope(protocol: .legacy)
        let body = try APIClient.observationPayload(envelope,
            manifest: SamplingReplayManifest(drainId: UUID().uuidString, batchIds: [envelope.batchId], index: 0, count: 1))
        #expect(body["sampling"] == nil && body["location"] == nil)
        #expect(((body["beacons"] as? [[String: Any]])?.first?["timestamp"] as? NSNumber)?.int64Value == envelope.sampling?.observedFrom)
    }

    @Test("Relaunched background ACK removes only the exact durable batch and captured tenant")
    func exactBackgroundAck() throws {
        let storage = OfflineBatchStorage(directoryName: "com.bearound.sdk.api.test.\(UUID().uuidString)")
        defer { storage.clearAllBatches() }
        let envelope = try immutableEnvelope()
        let unrelated = try immutableEnvelope()
        #expect(storage.saveObservation(envelope) != nil && storage.saveObservation(unrelated) != nil)
        let descriptor = ObservationDeliveryReconciliation(storageIds: [], tenantFingerprint: envelope.tenantFingerprint,
            adaptiveBatchId: envelope.batchId)
        let description = String(data: try JSONEncoder().encode(descriptor), encoding: .utf8)!
        func ack(_ id: String, durable: Bool = true) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["samplingAck": ["batchId": id,
                "archive": durable ? "durable" : "pending", "projection": "archive_only",
                "reason": "historical_already_closed", "fallback": "keep", "invalidateCapability": false]])
        }
        #expect(BackgroundSessionManager.reconcileObservation(description: description, responseBody: try ack(unrelated.batchId), successful: true, storage: storage) == 0)
        #expect(BackgroundSessionManager.reconcileObservation(description: description, responseBody: try ack(envelope.batchId, durable: false), successful: true, storage: storage) == 0)
        #expect(BackgroundSessionManager.reconcileObservation(description: description, responseBody: try ack(envelope.batchId), successful: false, storage: storage) == 0)
        #expect(BackgroundSessionManager.reconcileObservation(description: description, responseBody: try ack(envelope.batchId), successful: true, storage: storage) == 1)
        #expect(storage.observationRecords().map { $0.envelope.batchId } == [unrelated.batchId])
    }

    @Test("APIError descriptions")
    func apiErrorDescriptions() {
        let invalidURLError = APIError.invalidURL
        #expect(invalidURLError.errorDescription == "Invalid API URL")

        let invalidResponseError = APIError.invalidResponse
        #expect(invalidResponseError.errorDescription == "Invalid server response")

        let httpError = APIError.httpError(statusCode: 404)
        #expect(httpError.errorDescription == "HTTP error: 404")
    }

    @Test("APIError different status codes")
    func apiErrorStatusCodes() {
        let error400 = APIError.httpError(statusCode: 400)
        let error401 = APIError.httpError(statusCode: 401)
        let error500 = APIError.httpError(statusCode: 500)

        #expect(error400.errorDescription?.contains("400") == true)
        #expect(error401.errorDescription?.contains("401") == true)
        #expect(error500.errorDescription?.contains("500") == true)
    }

    @Test("APIClient initialization with configuration")
    func apiClientInitialization() {
        let config = SDKConfiguration(
            businessToken: "test-business-token-123",
            scanPrecision: .high
        )

        let apiClient = APIClient(configuration: config)

        // Verify client initializes without crashing
        #expect(apiClient != nil)
    }

    @Test("API payload structure validation")
    func apiPayloadStructure() {
        // Test that we can create the models needed for API payload
        let sdkInfo = SDKInfo(
            appId: "test-app",
            build: 100
        )

        #expect(sdkInfo.appId == "test-app")
        #expect(sdkInfo.build == 100)
        // version now tracks the real SDK version (no stale "2.2.1" default on the wire)
        #expect(sdkInfo.version == BeAroundSDK.version)
        #expect(sdkInfo.platform == "ios")
        #expect(sdkInfo.technology == "ios-native")
    }

    @Test("BeAroundSDK.version reads from the framework bundle, not a Swift literal")
    func versionFromBundle() {
        let bundleVersion = Bundle(for: BeAroundSDK.self).infoDictionary?["CFBundleShortVersionString"] as? String
        #expect(BeAroundSDK.version == bundleVersion)
        #expect(BeAroundSDK.version != "2.2.1") // the old stale-default bug must never come back
        #expect(!BeAroundSDK.version.isEmpty)
    }

    @Test("sdk wire payload carries the real version + ios-native technology")
    func sdkWirePayload() throws {
        let sdkInfo = SDKInfo(appId: "com.test.app", build: 210)
        let dict = APIClient.makeSdkPayload(sdkInfo)
        let data = try JSONSerialization.data(withJSONObject: dict)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["version"] as? String == BeAroundSDK.version) // wire == bundle version
        #expect(json["version"] as? String != "2.2.1")
        #expect(json["technology"] as? String == "ios-native")
        #expect(json["platform"] as? String == "ios")
        #expect(json["build"] as? Int == 210)
    }

    @Test("Beacon model creation")
    func beaconModelCreation() {
        let uuid = UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!
        
        let beacon = Beacon(
            uuid: uuid,
            major: 1000,
            minor: 2000,
            rssi: -65,
            proximity: .near,
            accuracy: 2.5,
            timestamp: Date(),
            metadata: nil,
            txPower: -59
        )
        
        #expect(beacon.uuid == uuid)
        #expect(beacon.major == 1000)
        #expect(beacon.minor == 2000)
        #expect(beacon.rssi == -65)
        #expect(beacon.accuracy == 2.5)
        #expect(beacon.txPower == -59)
    }
    
    @Test("Beacon with metadata")
    func beaconWithMetadata() {
        let metadata = BeaconMetadata(
            firmwareVersion: "2.1.0",
            batteryLevel: 87,
            movements: 42,
            temperature: 24,
            txPower: -59,
            rssiFromBLE: -63,
            isConnectable: true
        )
        
        let beacon = Beacon(
            uuid: UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!,
            major: 1000,
            minor: 2000,
            rssi: -65,
            proximity: .near,
            accuracy: 2.5,
            timestamp: Date(),
            metadata: metadata,
            txPower: -59
        )
        
        #expect(beacon.metadata != nil)
        #expect(beacon.metadata?.firmwareVersion == "2.1.0")
        #expect(beacon.metadata?.batteryLevel == 87)
        #expect(beacon.metadata?.movements == 42)
        #expect(beacon.metadata?.temperature == 24)
        #expect(beacon.metadata?.isConnectable == true)
    }
    
    // `collectDeviceInfo` reads notification/app state (UNUserNotificationCenter /
    // UIApplication), which throws `bundleProxyForCurrentProcess is nil` in a
    // host-less unit-test bundle (as in CI). Run it only where there's an app host.
    @Test("UserDevice model is collected", .enabled(if: Bundle.main.bundlePath.hasSuffix(".app")))
    func userDeviceModelCollected() {
        // Test that DeviceInfoCollector can create UserDevice
        let collector = DeviceInfoCollector()
        
        let device = collector.collectDeviceInfo(
            locationPermission: .authorizedAlways,
            bluetoothState: "powered_on",
            appInForeground: true
        )
        
        // Verify basic fields are populated
        #expect(!device.manufacturer.isEmpty)
        #expect(!device.model.isEmpty)
        #expect(!device.osVersion.isEmpty)
        // Battery is a fraction in [0, 1], or the -1 sentinel when it can't be read
        // (battery monitoring off / the Simulator, which reports -1).
        #expect(device.batteryLevel == -1 || (device.batteryLevel >= 0 && device.batteryLevel <= 1))
        #expect(device.locationPermission == "authorized_always")
        #expect(device.appInForeground == true)
    }
    
    @Test("Lista de beacons vazia só sobe quando há o que arquivar")
    func emptyBeaconsRule() {
        // register: registra o aparelho antes de ele ter visto qualquer beacon.
        #expect(APIClient.acceptsEmptyBeacons(syncTrigger: "register", hasEncounters: false))

        // Encontros: viu outros aparelhos, nenhum beacon no alcance. Há o que arquivar.
        #expect(APIClient.acceptsEmptyBeacons(syncTrigger: "encounter_mesh", hasEncounters: true))
        #expect(APIClient.acceptsEmptyBeacons(syncTrigger: "ble_detection", hasEncounters: true))

        // Scan que não achou nada: onde o aparelho estava, e o Wi-Fi ao redor, É o dado.
        #expect(
            APIClient.acceptsEmptyBeacons(
                syncTrigger: "presence_heartbeat", hasEncounters: false, hasLocation: true
            )
        )
        #expect(
            APIClient.acceptsEmptyBeacons(
                syncTrigger: "presence_heartbeat", hasEncounters: false, hasWifis: true
            )
        )

        // Sem beacon, sem encontro, sem localização e sem Wi-Fi não há nada a registrar — o
        // ingest responde 400 "Missing beacons in payload", então isso não pode virar requisição.
        for trigger in [
            "encounter_mesh", "ble_detection", "precision_high_timer", "presence_heartbeat",
            "bluetooth_zone_enter", "background_fetch", "unknown", "", "Register", "register ",
        ] {
            #expect(
                !APIClient.acceptsEmptyBeacons(syncTrigger: trigger, hasEncounters: false),
                "aceitou \(trigger) sem nada para enviar"
            )
        }
    }

    @Test("o motivo do envio sobrevive ao motivo que agendou o sync")
    func composedSyncTrigger() {
        // A regressão que isto tranca: o carimbo só acontecia enquanto o trigger ainda era
        // "unknown", mas o coordenador SEMPRE escreve o motivo do agendamento antes. Resultado:
        // nem encounter_mesh nem presence_heartbeat chegavam ao payload — todo reporte de scan
        // vazio subia como "precision_high_timer", indistinguível de um sync comum.
        #expect(
            BeAroundSDK.composedTrigger(current: "precision_high_timer", adding: "presence_heartbeat")
                == "precision_high_timer+presence_heartbeat"
        )
        #expect(
            BeAroundSDK.composedTrigger(current: "ble_detection+precision_high_timer", adding: "encounter_mesh")
                == "ble_detection+encounter_mesh+precision_high_timer"
        )

        // Sem motivo prévio, o motivo do envio é o trigger inteiro.
        #expect(BeAroundSDK.composedTrigger(current: "unknown", adding: "presence_heartbeat") == "presence_heartbeat")
        #expect(BeAroundSDK.composedTrigger(current: "", adding: "encounter_mesh") == "encounter_mesh")

        // Idempotente: reentrar no mesmo caminho não duplica a razão.
        #expect(
            BeAroundSDK.composedTrigger(current: "presence_heartbeat", adding: "presence_heartbeat")
                == "presence_heartbeat"
        )
    }

    @Test("Beacon metadata model")
    func beaconMetadataModel() {
        let metadata = BeaconMetadata(
            firmwareVersion: "v1.2.3",
            batteryLevel: 95,
            movements: 12,
            temperature: 25,
            txPower: -59,
            rssiFromBLE: -62,
            isConnectable: true
        )
        
        #expect(metadata.firmwareVersion == "v1.2.3")
        #expect(metadata.batteryLevel == 95)
        #expect(metadata.movements == 12)
        #expect(metadata.temperature == 25)
        #expect(metadata.txPower == -59)
        #expect(metadata.rssiFromBLE == -62)
        #expect(metadata.isConnectable == true)
    }
    
    @Test("UserProperties model")
    func userPropertiesModel() {
        let properties = UserProperties(
            internalId: "user-123",
            email: "user@example.com",
            name: "John Doe",
            customProperties: ["tier": "premium", "region": "US"]
        )
        
        #expect(properties.internalId == "user-123")
        #expect(properties.email == "user@example.com")
        #expect(properties.name == "John Doe")
        #expect(properties.customProperties["tier"] == "premium")
        #expect(properties.customProperties["region"] == "US")
    }

    @Test("merging keeps existing internalId when the update omits it")
    func mergingPreservesInternalId() {
        let base = UserProperties(internalId: "user-123")
        let update = UserProperties(email: "user@example.com")

        let merged = base.merging(update)

        #expect(merged.internalId == "user-123")
        #expect(merged.email == "user@example.com")
    }

    @Test("merging overrides provided fields and merges custom keys")
    func mergingOverridesAndMergesCustom() {
        let base = UserProperties(internalId: "old", name: "Old", customProperties: ["a": "1", "b": "2"])
        let update = UserProperties(internalId: "new", customProperties: ["b": "9", "c": "3"])

        let merged = base.merging(update)

        #expect(merged.internalId == "new")
        #expect(merged.name == "Old")
        #expect(merged.customProperties["a"] == "1")
        #expect(merged.customProperties["b"] == "9")
        #expect(merged.customProperties["c"] == "3")
    }
    
    @Test("APIClient base URL validation")
    func apiClientBaseURLValidation() {
        let config = SDKConfiguration(
            businessToken: "test-token",
            scanPrecision: .high
        )
        
        #expect(config.apiBaseURL == "https://ingest.bearound.io")
    }
    private func encodingFixture() throws -> (APIClient, StoredObservationEnvelope, SamplingClock, RequestEncodingLease) {
        let configuration = SDKConfiguration(businessToken: "fixture-token-gzip")
        let original = try immutableEnvelope()
        var payload = original.originalPayload.mapValues { $0.foundationValue }
        payload["location"] = ["latitude": -23.5, "longitude": -46.6, "accuracy": 10]
        payload["wifis"] = [["apId": "fixture-ap", "timestamp": original.storedAtMs]]
        payload["userProperties"] = ["internalId": "fixture-person", "padding": String(repeating: "café / ☃", count: 300)]
        let tenant = SamplingTenantFingerprint.make(endpoint: configuration.apiBaseURL, appID: configuration.appId,
            deviceID: "original.device", businessToken: configuration.businessToken)
        let envelope = try StoredObservationEnvelope(batchId: original.batchId, storedAtMs: original.storedAtMs,
            tenantFingerprint: tenant, originalPayload: payload, sampling: original.sampling, contextID: "original")
        let clock = SamplingClock(wallTimeMs: original.storedAtMs, monotonicTimeMs: 1_000_000,
            bootIdentifier: original.sampling!.clock.bootId)
        let lease = RequestEncodingLease(bootIdentifier: clock.bootIdentifier, expiresAtMonotonicMs: 1_300_000)
        let client = APIClient(configuration: configuration)
        client.clockProvider = { clock }
        client.submissionContextProvider = { $0(RequestSubmissionContext(policy: .allEnabled, gzipLease: lease)) }
        return (client, envelope, clock, lease)
    }

    private func durableAck(_ envelope: StoredObservationEnvelope) -> Data {
        try! JSONSerialization.data(withJSONObject: ["samplingAck": ["batchId": envelope.batchId,
            "archive": "durable", "projection": "applied", "fallback": "keep", "invalidateCapability": false]])
    }

    private func deliver(_ client: APIClient, _ envelope: StoredObservationEnvelope,
                         path: DeliveryPath = .immediateFirst, logical: (() -> Void)? = nil) async -> Result<Data, Error> {
        await withCheckedContinuation { continuation in
            client.sendObservation(envelope, storageId: nil, delivery: path, attemptObserver: logical) {
                continuation.resume(returning: $0)
            }
        }
    }

    @Test("Negotiated request headers and submitted gzip preserve complete immutable original JSON")
    func gzipObservationRepresentation() async throws {
        let (client, envelope, _, _) = try encodingFixture()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let stored = try encoder.encode(envelope)
        var requests: [(URLRequest, Data)] = []
        var measured: [Int] = []
        client.bodyAttemptObserver = { measured.append($0) }
        client.transport = { request, data, _, descriptor, submit, finish in
            requests.append((request, data))
            #expect(descriptor.adaptiveBatchId == envelope.batchId && descriptor.requestContentEncoding == "gzip")
            submit(); finish(.success(durableAck(envelope)))
        }
        _ = try await deliver(client, envelope).get()
        let (request, compressed) = try #require(requests.first)
        #expect(request.value(forHTTPHeaderField: "Content-Encoding") == "gzip")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        let decoded = try JSONSerialization.jsonObject(with: RequestBodyEncodingTests.gunzip(compressed)) as! NSDictionary
        #expect(decoded == (try APIClient.observationPayload(envelope) as NSDictionary))
        let unchanged = try encoder.encode(envelope)
        #expect(measured == [compressed.count] && stored == unchanged)
    }

    @Test("Gzip 415 submits exactly one identity retry with original IDs and counts both actual bodies")
    func gzip415IdentityRetry() async throws {
        let (client, envelope, _, lease) = try encodingFixture()
        var requests: [(URLRequest, Data)] = []
        var measured: [Int] = []
        var rejected: [RequestEncodingLease] = []
        var logicalCount = 0
        client.bodyAttemptObserver = { measured.append($0) }
        client.gzipRejectionObserver = { rejected.append($0); $1() }
        client.transport = { request, data, _, _, submit, finish in
            requests.append((request, data)); submit()
            finish(requests.count == 1 ? .failure(APIError.httpError(statusCode: 415)) : .success(durableAck(envelope)))
        }
        _ = try await deliver(client, envelope, logical: { logicalCount += 1 }).get()
        #expect(requests.count == 2 && measured == requests.map { $0.1.count } && logicalCount == 1)
        #expect(rejected == [lease])
        #expect(requests[1].0.value(forHTTPHeaderField: "Content-Encoding") == nil)
        #expect(requests[1].0.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(requests[0].0.value(forHTTPHeaderField: "Authorization") == requests[1].0.value(forHTTPHeaderField: "Authorization"))
        #expect((try JSONSerialization.jsonObject(with: RequestBodyEncodingTests.gunzip(requests[0].1)) as! NSDictionary)
            == (try JSONSerialization.jsonObject(with: requests[1].1) as! NSDictionary))
    }

    @Test("Identity fallback reapplies revoked sources without collectors or mutation of offline original")
    func fallbackPolicyRevocation() async throws {
        let (client, envelope, _, lease) = try encodingFixture()
        var preparations = 0
        var bodies: [Data] = []
        client.submissionContextProvider = { prepare in
            preparations += 1
            prepare(RequestSubmissionContext(policy: preparations == 1 ? .allEnabled :
                DataCollectionPolicy(advertisingId: false, location: false, wifi: false), gzipLease: lease))
        }
        client.transport = { _, data, _, _, submit, finish in
            bodies.append(data); submit()
            finish(bodies.count == 1 ? .failure(APIError.httpError(statusCode: 415)) : .success(durableAck(envelope)))
        }
        _ = try await deliver(client, envelope).get()
        let first = try JSONSerialization.jsonObject(with: RequestBodyEncodingTests.gunzip(bodies[0])) as! [String: Any]
        let second = try JSONSerialization.jsonObject(with: bodies[1]) as! [String: Any]
        #expect(first["location"] != nil && first["wifis"] != nil)
        #expect(second["location"] == nil && second["wifis"] == nil)
        #expect((first["sampling"] as! NSDictionary) == (second["sampling"] as! NSDictionary))
        #expect(envelope.originalPayload["location"] != nil && envelope.originalPayload["wifis"] != nil && preparations == 2)
    }

    @Test("Generation invalidation between gzip and identity blocks another HTTP submission")
    func fallbackGenerationGate() async throws {
        let (client, envelope, _, lease) = try encodingFixture()
        var preparations = 0
        var measured: [Int] = []
        client.submissionContextProvider = { prepare in
            preparations += 1
            prepare(preparations == 1 ? RequestSubmissionContext(policy: .allEnabled, gzipLease: lease) : nil)
        }
        client.bodyAttemptObserver = { measured.append($0) }
        client.transport = { _, _, _, _, submit, finish in submit(); finish(.failure(APIError.httpError(statusCode: 415))) }
        let result = await deliver(client, envelope)
        if case .success = result { Issue.record("Invalid generation submitted identity retry") }
        #expect(preparations == 2 && measured.count == 1)
    }

    @Test("400 and 413 do not cause an identity or background retry", arguments: [400, 413])
    func rejectedBodyNoRetry(status: Int) async throws {
        let (client, envelope, _, _) = try encodingFixture()
        var attempts = 0
        client.transport = { _, _, _, _, submit, finish in
            attempts += 1; submit(); finish(.failure(APIError.httpError(statusCode: status)))
        }
        let result = await deliver(client, envelope)
        if case .success = result { Issue.record("Rejected body reported success") }
        #expect(attempts == 1)
    }

    @Test("Failed identity retry cannot create a third background attempt")
    func identityRetryBound() async throws {
        let (client, envelope, _, _) = try encodingFixture()
        var attempts = 0
        client.transport = { _, _, _, _, submit, finish in
            attempts += 1; submit()
            finish(attempts == 1 ? .failure(APIError.httpError(statusCode: 415)) : .failure(URLError(.timedOut)))
        }
        _ = await deliver(client, envelope)
        #expect(attempts == 2)
    }

    @Test("Network fallback rechecks lease at actual background submission and counts both representations")
    func backgroundSubmissionLeaseGate() async throws {
        let (client, envelope, clock, _) = try encodingFixture()
        var now = clock
        let expires = RequestEncodingLease(bootIdentifier: clock.bootIdentifier, expiresAtMonotonicMs: clock.monotonicTimeMs + 1)
        client.clockProvider = { now }
        client.submissionContextProvider = { $0(RequestSubmissionContext(policy: .allEnabled, gzipLease: expires)) }
        var paths: [DeliveryPath] = []
        var encodings: [String?] = []
        var sizes: [Int] = []
        var measured: [Int] = []
        client.bodyAttemptObserver = { measured.append($0) }
        client.transport = { request, data, path, _, submit, finish in
            paths.append(path); encodings.append(request.value(forHTTPHeaderField: "Content-Encoding")); sizes.append(data.count); submit()
            if paths.count == 1 {
                now = SamplingClock(wallTimeMs: clock.wallTimeMs + 2, monotonicTimeMs: clock.monotonicTimeMs + 2,
                    bootIdentifier: clock.bootIdentifier)
                finish(.failure(URLError(.networkConnectionLost)))
            } else { finish(.success(durableAck(envelope))) }
        }
        _ = try await deliver(client, envelope).get()
        #expect(paths == [.immediateFirst, .background] && encodings == ["gzip", nil])
        #expect(measured == sizes && measured.count == 2)
    }

    @Test("Budget and generation failures count no HTTP bodies and stage no background file")
    func nonSubmittedAttempts() async throws {
        for budgetFailure in [false, true] {
            let (client, envelope, _, lease) = try encodingFixture()
            client.submissionContextProvider = {
                $0(budgetFailure ? RequestSubmissionContext(policy: .allEnabled, gzipLease: lease, maximumJSONBytes: 100) : nil)
            }
            var attempts = 0
            var measured = 0
            client.bodyAttemptObserver = { measured += $0 }
            client.transport = { _, _, _, _, _, _ in attempts += 1 }
            _ = await deliver(client, envelope, path: .background)
            #expect(attempts == 0 && measured == 0)
        }
    }

    @Test("Background gzip file contains exact submitted bytes while orphan 415 retains original until exact ACK")
    func orphan415RetainsCanonicalOriginal() throws {
        let (_, envelope, _, _) = try encodingFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try JSONSerialization.data(withJSONObject: APIClient.observationPayload(envelope))
        let body = try RequestBodyEncoding.encode(original, gzipAllowed: true)
        let file = try BackgroundSessionManager.stageUploadBody(body.data, directory: directory)
        #expect(try Data(contentsOf: file) == body.data)
        #expect(try RequestBodyEncodingTests.gunzip(Data(contentsOf: file)) == original)
        let directoryName = "com.bearound.sdk.gzip.test.\(UUID().uuidString)"
        let storage = OfflineBatchStorage(directoryName: directoryName)
        defer { storage.clearAllBatches() }
        let id = try #require(storage.saveObservation(envelope))
        let canonicalFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(directoryName).appendingPathComponent(id)
        let canonical = try Data(contentsOf: canonicalFile)
        var descriptor = ObservationDeliveryReconciliation(storageIds: [id], tenantFingerprint: envelope.tenantFingerprint,
            adaptiveBatchId: envelope.batchId)
        descriptor.requestContentEncoding = "gzip"
        let description = String(data: try JSONEncoder().encode(descriptor), encoding: .utf8)!
        #expect(BackgroundSessionManager.reconcileObservation(description: description, responseBody: Data(),
            successful: false, statusCode: 415, storage: storage) == 0)
        #expect(BackgroundSessionManager.requiresIdentity(descriptor))
        #expect(try Data(contentsOf: canonicalFile) == canonical)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let unrelated = ObservationDeliveryReconciliation(storageIds: [], tenantFingerprint: String(repeating: "b", count: 64),
            adaptiveBatchId: envelope.batchId)
        #expect(!BackgroundSessionManager.requiresIdentity(unrelated))
        #expect(BackgroundSessionManager.reconcileObservation(description: description, responseBody: Data("{}".utf8),
            successful: true, storage: storage) == 0)
        #expect(BackgroundSessionManager.reconcileObservation(description: description, responseBody: durableAck(envelope),
            successful: true, storage: storage) == 1)
        #expect(storage.observationRecords().isEmpty && !BackgroundSessionManager.requiresIdentity(descriptor))
    }

    @Test("Initial register stays identity even with a negotiated lease and counts its actual body")
    func initialRegisterIdentity() async throws {
        let (client, _, _, _) = try encodingFixture()
        let device = UserDevice(deviceId: "fixture-device", pushToken: nil, apnsEnvironment: "sandbox",
            manufacturer: "Apple", model: "fixture", osVersion: "26.5", timestamp: 1_791_907_200_000,
            timezone: "UTC", batteryLevel: -1, isCharging: false, bluetoothState: "powered_on",
            locationPermission: "not_determined", notificationsPermission: "not_determined", networkType: "wifi",
            cellularGeneration: nil, ramTotalMb: 1, ramAvailableMb: 1, screenWidth: 1, screenHeight: 1,
            appInForeground: true, appUptimeMs: 0, coldStart: true, lowPowerMode: nil, locationAccuracy: nil,
            apId: nil, wifiSSID: nil, connectionMetered: nil, connectionExpensive: nil, os: "ios",
            deviceName: "fixture", carrierName: nil, availableStorageMb: nil, systemLanguage: "en",
            thermalState: "nominal", systemUptimeMs: 0)
        var measured: [Int] = []
        var sent: [Data] = []
        client.bodyAttemptObserver = { measured.append($0) }
        client.transport = { request, data, _, _, submit, finish in
            #expect(request.value(forHTTPHeaderField: "Content-Encoding") == nil)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            sent.append(data); submit(); finish(.success(Data("{}".utf8)))
        }
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            client.sendBeacons([], sdkInfo: SDKInfo(appId: "fixture-app", build: 1), userDevice: device,
                userProperties: nil, syncTrigger: "register", delivery: .immediateFirst) {
                continuation.resume(returning: $0)
            }
        }
        try result.get()
        #expect(measured == sent.map { $0.count } && sent.count == 1)
    }

    @Test("Expired physical live evidence cannot reach the background fallback")
    func backgroundPhysicalFreshnessGate() async throws {
        let (client, envelope, clock, _) = try encodingFixture()
        var now = clock
        client.clockProvider = { now }
        var attempts = 0
        var measured: [Int] = []
        client.bodyAttemptObserver = { measured.append($0) }
        client.transport = { _, _, _, _, submit, finish in
            attempts += 1; submit()
            now = SamplingClock(wallTimeMs: clock.wallTimeMs + 30_001, monotonicTimeMs: clock.monotonicTimeMs + 30_001,
                bootIdentifier: clock.bootIdentifier)
            finish(.failure(URLError(.timedOut)))
        }
        _ = await deliver(client, envelope)
        #expect(attempts == 1 && measured.count == 1)
    }

    @Test("Encoding expiry during staging uses one identity submission while generation and policy changes block resume")
    func stagedBackgroundResumeGate() async throws {
        for boundary in ["lease", "generation", "policy"] {
            let (client, envelope, clock, _) = try encodingFixture()
            var now = clock
            var generationCurrent = true
            var policy = DataCollectionPolicy.allEnabled
            let lease = RequestEncodingLease(bootIdentifier: clock.bootIdentifier, expiresAtMonotonicMs: clock.monotonicTimeMs + 1)
            client.clockProvider = { now }
            client.submissionContextProvider = { prepare in
                prepare(RequestSubmissionContext(policy: .allEnabled, gzipLease: lease,
                    isCurrent: { generationCurrent && policy == .allEnabled }))
            }
            var measured: [Int] = []
            var logical = 0
            var resumed = 0
            client.bodyAttemptObserver = { measured.append($0) }
            client.transport = { _, data, _, _, submit, finish in
                do {
                    let file = try BackgroundSessionManager.stageUploadBody(data)
                    defer { try? FileManager.default.removeItem(at: file) }
                    if boundary == "lease" {
                        now = SamplingClock(wallTimeMs: clock.wallTimeMs + 2, monotonicTimeMs: clock.monotonicTimeMs + 2,
                            bootIdentifier: clock.bootIdentifier)
                    } else if boundary == "generation" { generationCurrent = false }
                    else { policy = DataCollectionPolicy(location: false) }
                    if submit() { resumed += 1; finish(.success(durableAck(envelope))) }
                    else { finish(.failure(APIError.invalidResponse)) }
                } catch { finish(.failure(error)) }
            }
            _ = await deliver(client, envelope, path: .background, logical: { logical += 1 })
            if boundary == "lease" {
                #expect(resumed == 1 && measured.count == 1 && logical == 1)
                #expect(measured.first == (try JSONSerialization.data(withJSONObject: APIClient.observationPayload(envelope)).count))
            } else { #expect(resumed == 0 && measured.isEmpty && logical == 0) }
        }
    }

    @Test("Completed failed upload staging is deleted while canonical original remains until identity exact ACK")
    func completedTransportFileCleanup() async throws {
        for status in [415, 500, 0] {
            let (_, envelope, _, _) = try encodingFixture()
            let stagingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stagingDirectory) }
            let directoryName = "com.bearound.sdk.completed-upload.test.\(UUID().uuidString)"
            let storage = OfflineBatchStorage(directoryName: directoryName)
            defer { storage.clearAllBatches() }
            let id = try #require(storage.saveObservation(envelope))
            let canonicalFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent(directoryName).appendingPathComponent(id)
            let canonical = try Data(contentsOf: canonicalFile)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CompletedUploadFixtureProtocol.self]
            let manager = BackgroundSessionManager(ephemeralConfiguration: configuration)
            defer { manager.session.invalidateAndCancel() }
            let ack = durableAck(envelope)
            CompletedUploadFixtureProtocol.configure([(status, Data()), (200, ack)])
            var request = URLRequest(url: URL(string: "http://127.0.0.1:18783/ingest")!)
            request.httpMethod = "POST"
            guard request.url?.host == "127.0.0.1", request.url?.port == 18783 else {
                throw URLError(.unsupportedURL)
            }
            let original = try JSONSerialization.data(withJSONObject: APIClient.observationPayload(envelope))
            let gzip = try RequestBodyEncoding.encode(original, gzipAllowed: true)
            var descriptor = ObservationDeliveryReconciliation(storageIds: [id], tenantFingerprint: envelope.tenantFingerprint,
                adaptiveBatchId: envelope.batchId)
            descriptor.requestContentEncoding = "gzip"
            request.setValue(gzip.contentEncoding, forHTTPHeaderField: "Content-Encoding")
            request.setValue(gzip.contentType, forHTTPHeaderField: "Content-Type")
            let failed: Result<Data, Error> = await withCheckedContinuation { continuation in
                manager.uploadObservation(request: request, bodyData: gzip.data, reconciliation: descriptor,
                    stagingDirectory: stagingDirectory) { continuation.resume(returning: $0) }
            }
            if case .success = failed { Issue.record("Failed fixture upload reported success") }
            #expect(try FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path).isEmpty)
            #expect(try Data(contentsOf: canonicalFile) == canonical)
            let failedDescription = String(data: try JSONEncoder().encode(descriptor), encoding: .utf8)!
            #expect(BackgroundSessionManager.reconcileObservation(description: failedDescription, responseBody: Data(),
                successful: false, statusCode: status, storage: storage) == 0)
            if status == 415 { #expect(BackgroundSessionManager.requiresIdentity(descriptor)) }
            descriptor.requestContentEncoding = nil
            request.setValue(nil, forHTTPHeaderField: "Content-Encoding")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let successful: Result<Data, Error> = await withCheckedContinuation { continuation in
                manager.uploadObservation(request: request, bodyData: original, reconciliation: descriptor,
                    stagingDirectory: stagingDirectory) { continuation.resume(returning: $0) }
            }
            let response = try successful.get()
            #expect(try FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path).isEmpty)
            #expect(try Data(contentsOf: canonicalFile) == canonical)
            let identityDescription = String(data: try JSONEncoder().encode(descriptor), encoding: .utf8)!
            #expect(BackgroundSessionManager.reconcileObservation(description: identityDescription, responseBody: response,
                successful: true, statusCode: 200, storage: storage) == 1)
            #expect(!FileManager.default.fileExists(atPath: canonicalFile.path))
        }
    }

    @Test("Gzip 415 identity retry strips revoked sensor evidence with the original IDs clock and exact ACK")
    func motionPolicyIdentityRetry() async throws {
        let (client, original, _, lease) = try encodingFixture()
        for source in [MotionSource.nativeActivity, .contextFusion] {
            var envelope = original
            let observedAt = envelope.sampling?.observedTo
            envelope.sampling?.motion = MotionEvidence(state: source == .nativeActivity ? .movingConfirmed : .movingInferred,
                source: source, confidence: source == .nativeActivity ? .high : .low,
                reason: source == .nativeActivity ? "native_moving" : "context_changed",
                observedAtMs: observedAt, ageMs: 0, contextStable: false)
            var bodies: [Data] = []
            var preparations = 0
            client.submissionContextProvider = { prepare in
                preparations += 1
                prepare(RequestSubmissionContext(policy: DataCollectionPolicy(motionSensors: preparations == 1), gzipLease: lease))
            }
            client.transport = { request, bytes, _, _, submit, finish in
                #expect(request.httpMethod == "POST")
                #expect(submit())
                bodies.append(bytes)
                finish(bodies.count == 1 ? .failure(APIError.httpError(statusCode: 415)) : .success(durableAck(envelope)))
            }
            let ack = try await deliver(client, envelope).get()
            #expect(AdaptiveSamplingResponse.decode(ack)?.samplingAck?.confirms(envelope.batchId) == true)
            let first = try JSONSerialization.jsonObject(with: RequestBodyEncodingTests.gunzip(bodies[0])) as! [String: Any]
            let second = try JSONSerialization.jsonObject(with: bodies[1]) as! [String: Any]
            let a = first["sampling"] as! [String: Any]; let b = second["sampling"] as! [String: Any]
            #expect((a["motion"] as! [String: Any])["source"] as? String == source.rawValue)
            #expect((b["motion"] as! [String: Any])["reason"] as? String == "source_disabled")
            #expect(a["batchId"] as? String == b["batchId"] as? String)
            #expect((a["clock"] as! NSDictionary) == (b["clock"] as! NSDictionary))
            #expect(a["observedTo"] as? Double == b["observedTo"] as? Double)
            #expect(envelope.sampling?.motion.source == source && bodies.count == 2)
        }
    }

    @Test("A valid durable ACK survives malformed optional capability and missing ACK still fails")
    func independentAcknowledgmentDecode() async throws {
        let (client, envelope, _, _) = try encodingFixture()
        let valid = try #require(JSONSerialization.jsonObject(with: durableAck(envelope)) as? [String: Any])
        var malformed = valid
        malformed["capabilities"] = ["adaptiveSampling": ["version": 1]]
        for body in [valid, malformed] {
            client.transport = { _, _, _, _, submit, finish in
                #expect(submit())
                finish(.success(try! JSONSerialization.data(withJSONObject: body)))
            }
            _ = try await deliver(client, envelope).get()
        }
        client.transport = { _, _, _, _, submit, finish in #expect(submit()); finish(.success(Data("{}".utf8))) }
        let rejected = await deliver(client, envelope)
        guard case .failure(APIError.invalidSamplingAcknowledgment) = rejected else { Issue.record("Missing ACK must remain a typed failure"); return }
    }

    @Test("Observer callback publication tolerates concurrent replacement without exposing mutable storage")
    func observerPublication() {
        let client = APIClient(configuration: SDKConfiguration(businessToken: "fixture-token"))
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            client.responseObserver = { _, _, _ in }
            let callback = client.responseObserver
            callback?(Data(), SamplingClock.now(), SamplingClock.now())
            client.bodyAttemptObserver = { _ in }
            client.bodyAttemptObserver?(1)
        }
    }

    @Test("Legacy snapshots bypass negotiated adaptive budgets and retain identity support through one MiB", arguments: [4096, 600_000, 1_048_576])
    func legacyBudgetCompatibility(size: Int) async throws {
        let (client, original, _, lease) = try encodingFixture()
        var payload = original.originalPayload.mapValues { $0.foundationValue }
        payload["userProperties"] = ["internalId": "original-user", "padding": ""]
        let paddingCount = size == 1_048_576 ? size - (try JSONSerialization.data(withJSONObject: payload).count) : size
        payload["userProperties"] = ["internalId": "original-user", "padding": String(repeating: "x", count: paddingCount)]
        let legacy = try StoredObservationEnvelope(batchId: original.batchId, storedAtMs: original.storedAtMs,
            tenantFingerprint: original.tenantFingerprint, originalPayload: payload, sampling: nil, deliveryProtocol: .legacy)
        let storage = OfflineBatchStorage(directoryName: "com.bearound.sdk.test.legacy-budget.\(UUID().uuidString)")
        defer { storage.clearAllBatches() }
        let storageID = try #require(storage.saveObservation(legacy))
        let tenant = try #require(legacy.tenantFingerprint)
        let selected = try #require(storage.loadReplayGroup(tenantFingerprint: tenant,
            capabilityAvailable: false, maximumJSONBytes: 100).first)
        #expect(selected.storageId == storageID && selected.envelope.originalPayload == legacy.originalPayload)
        client.submissionContextProvider = {
            $0(RequestSubmissionContext(policy: .allEnabled, gzipLease: lease, maximumJSONBytes: 100, adaptiveAllowed: false))
        }
        var requests = 0
        client.transport = { request, data, _, descriptor, submit, finish in
            #expect(submit()); requests += 1
            #expect(descriptor.adaptiveBatchId == nil)
            let decoded: Data
            if size > 524_288 {
                #expect(request.value(forHTTPHeaderField: "Content-Encoding") == nil)
                #expect(data.count > 524_288 && data.count <= 1_048_576)
                if size == 1_048_576 { #expect(data.count == size) }
                decoded = data
            } else {
                decoded = request.value(forHTTPHeaderField: "Content-Encoding") == "gzip" ? try! RequestBodyEncodingTests.gunzip(data) : data
            }
            let body = try! JSONSerialization.jsonObject(with: decoded) as! [String: Any]
            #expect(body["sampling"] == nil && body["syncTrigger"] as? String == "original-trigger")
            #expect(((body["userProperties"] as! [String: Any])["padding"] as! String).count == paddingCount)
            #expect(((body["device"] as! [String: Any])["timestamp"] as! NSNumber).int64Value == original.storedAtMs)
            finish(.success(Data("{}".utf8)))
        }
        _ = try await deliver(client, selected.envelope).get()
        #expect(requests == 1 && storage.batchCount == 1)
    }

}

private final class CompletedUploadFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responses: [(Int, Data)] = []

    static func configure(_ values: [(Int, Data)]) {
        lock.lock(); responses = values; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && request.url?.port == 18783
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard request.url?.host == "127.0.0.1", request.url?.port == 18783 else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        Self.lock.lock()
        let next = Self.responses.isEmpty ? nil : Self.responses.removeFirst()
        Self.lock.unlock()
        guard let next else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        guard next.0 != 0 else { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: next.0, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}



}
