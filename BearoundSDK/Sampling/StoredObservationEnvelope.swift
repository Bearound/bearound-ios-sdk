import CryptoKit
import Foundation

enum ObservationJSONValue: Codable, Equatable {
    case object([String: ObservationJSONValue]), array([ObservationJSONValue])
    case string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([ObservationJSONValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: ObservationJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }

    var object: [String: ObservationJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var array: [ObservationJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var foundationValue: Any {
        switch self {
        case .object(let value): return value.mapValues { $0.foundationValue }
        case .array(let value): return value.map { $0.foundationValue }
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        }
    }

    static func snapshot(_ dictionary: [String: Any]) throws -> [String: ObservationJSONValue] {
        let data = try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
        return try JSONDecoder().decode([String: ObservationJSONValue].self, from: data)
    }
}

enum SamplingTenantFingerprint {
    static func make(endpoint: String, appID: String, deviceID: String, businessToken: String) -> String {
        let values = [endpoint, appID, deviceID, businessToken]
        let data = (try? JSONEncoder().encode(values)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isValid(_ value: String?) -> Bool {
        guard let value, value.count == 64 else { return false }
        return value.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

struct SamplingEnvelopeClock: Codable, Equatable {
    let bootId: String
    let wallTimeMs: Int64
    let monotonicTimeMs: Int64
    var serverOffsetMs: Int64? = nil
    var offsetUncertaintyMs: Int64? = nil
    var synchronizedAtMonotonicMs: Int64? = nil

    enum CodingKeys: String, CodingKey {
        case bootId, wallTimeMs, monotonicTimeMs, serverOffsetMs, offsetUncertaintyMs, synchronizedAtMonotonicMs
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(bootId, forKey: .bootId)
        try fields.encode(wallTimeMs, forKey: .wallTimeMs)
        try fields.encode(monotonicTimeMs, forKey: .monotonicTimeMs)
        try fields.encode(serverOffsetMs, forKey: .serverOffsetMs)
        try fields.encode(offsetUncertaintyMs, forKey: .offsetUncertaintyMs)
        try fields.encode(synchronizedAtMonotonicMs, forKey: .synchronizedAtMonotonicMs)
    }
}

struct SamplingReplayManifest: Codable, Equatable {
    let drainId: String
    let batchIds: [String]
    let index: Int
    let count: Int
}

struct SamplingEnvelope: Codable, Equatable {
    enum Kind: String, Codable { case live, summary, transition }
    enum TransitionReason: String, Codable {
        case confirmedVisitArrival = "confirmed_visit_arrival"
        case confirmedVisitExit = "confirmed_visit_exit"
        case contextChanged = "context_changed"
    }

    let version: Int
    let kind: Kind
    let batchId: String
    let captureStreamId: String
    let windowId: String
    let observedFrom: Int64
    let observedTo: Int64
    var sentAt: Int64
    var motion: MotionEvidence
    let clock: SamplingEnvelopeClock
    var transitionReason: TransitionReason? = nil
    var replay: SamplingReplayManifest? = nil

    enum CodingKeys: String, CodingKey {
        case version, kind, batchId, captureStreamId, windowId, observedFrom, observedTo, sentAt
        case motion, clock, transitionReason, replay
    }
    private enum MotionKeys: String, CodingKey {
        case state, source, confidence, reason, observedAtMs, ageMs, contextStable
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(version, forKey: .version)
        try fields.encode(kind, forKey: .kind)
        try fields.encode(batchId, forKey: .batchId)
        try fields.encode(captureStreamId, forKey: .captureStreamId)
        try fields.encode(windowId, forKey: .windowId)
        try fields.encode(observedFrom, forKey: .observedFrom)
        try fields.encode(observedTo, forKey: .observedTo)
        try fields.encode(sentAt, forKey: .sentAt)
        try fields.encode(clock, forKey: .clock)
        try fields.encodeIfPresent(transitionReason, forKey: .transitionReason)
        try fields.encodeIfPresent(replay, forKey: .replay)
        var evidence = fields.nestedContainer(keyedBy: MotionKeys.self, forKey: .motion)
        try evidence.encode(motion.state, forKey: .state)
        try evidence.encode(motion.source, forKey: .source)
        try evidence.encode(motion.confidence, forKey: .confidence)
        try evidence.encode(motion.reason, forKey: .reason)
        try evidence.encode(motion.observedAtMs, forKey: .observedAtMs)
        try evidence.encode(motion.ageMs, forKey: .ageMs)
        try evidence.encode(motion.contextStable, forKey: .contextStable)
    }

    var hasValidIdentityAndWindow: Bool {
        version == 1 && [batchId, captureStreamId, windowId].allSatisfy { UUID(uuidString: $0) != nil }
            && observedFrom > 0 && observedTo >= observedFrom && observedTo - observedFrom <= 300_000
            && sentAt > 0 && (observedTo <= sentAt || observedTo - sentAt <= 120_000)
            && clock.wallTimeMs > 0 && abs(clock.wallTimeMs - sentAt) <= 120_000 && clock.monotonicTimeMs >= 0
            && !clock.bootId.isEmpty
    }
}

struct StoredObservationEnvelope: Codable, Equatable {
    enum DeliveryProtocol: String, Codable { case legacy, adaptive }
    struct CollectionSwitches: Codable, Equatable {
        var advertisingId: Bool
        var location: Bool
        var wifi: Bool
        var motionSensors: Bool? = nil

        var effectiveMotionSensors: Bool { motionSensors ?? (location || wifi) }
    }
    let version: Int
    let batchId: String
    let storedAtMs: Int64
    let tenantFingerprint: String?
    let contextID: String?
    let deliveryProtocol: DeliveryProtocol
    var capturedPolicy: CollectionSwitches
    var contextFingerprint: String?
    var originalPayload: [String: ObservationJSONValue]
    var sampling: SamplingEnvelope?
    var absentFields: [String]
    var replayManifest: SamplingReplayManifest? = nil
    let migratedFromVersion: Int?

    private init(
        batchId: String, storedAtMs: Int64, tenantFingerprint: String?,
        payload: [String: ObservationJSONValue], sampling: SamplingEnvelope?, migratedFromVersion: Int?, contextID: String?,
        deliveryProtocol: DeliveryProtocol?
    ) {
        version = 2
        self.batchId = batchId
        self.storedAtMs = storedAtMs
        self.tenantFingerprint = tenantFingerprint
        self.contextID = contextID
        self.deliveryProtocol = deliveryProtocol ?? (sampling == nil ? .legacy : .adaptive)
        capturedPolicy = CollectionSwitches(advertisingId: true, location: true, wifi: true)
        originalPayload = payload
        self.sampling = sampling
        self.migratedFromVersion = migratedFromVersion
        contextFingerprint = nil
        absentFields = []
    }

    init(
        batchId: String, storedAtMs: Int64, tenantFingerprint: String?,
        originalPayload: [String: Any], sampling: SamplingEnvelope?,
        policy: DataCollectionPolicy = .allEnabled, migratedFromVersion: Int? = nil, contextID: String? = nil,
        deliveryProtocol: DeliveryProtocol? = nil
    ) throws {
        var payload = try ObservationJSONValue.snapshot(originalPayload)
        payload.removeValue(forKey: "sampling")
        payload.removeValue(forKey: "businessToken")
        self = StoredObservationEnvelope(batchId: batchId, storedAtMs: storedAtMs,
            tenantFingerprint: tenantFingerprint, payload: payload, sampling: sampling,
            migratedFromVersion: migratedFromVersion, contextID: contextID, deliveryProtocol: deliveryProtocol).filtered(policy: policy)
    }

    var retentionStartMs: Int64 { min(storedAtMs, sampling?.observedFrom ?? storedAtMs) }

    var canReplay: Bool {
        version == 2 && UUID(uuidString: batchId) != nil && SamplingTenantFingerprint.isValid(tenantFingerprint)
            && SamplingTenantFingerprint.isValid(contextFingerprint)
            && (sampling == nil || sampling?.batchId == batchId)
            && (sampling == nil || sampling?.hasValidIdentityAndWindow == true)
            && (deliveryProtocol == .legacy ? migratedFromVersion == nil : sampling != nil)
            && originalPayload["sdk"]?.object != nil && originalPayload["device"]?.object != nil
    }

    func filtered(policy: DataCollectionPolicy) -> StoredObservationEnvelope {
        var result = self
        var payload = result.originalPayload
        var device = payload["device"]?.object
        if !policy.location {
            payload.removeValue(forKey: "location")
            // A visit says where the device was, whatever produced it.
            payload.removeValue(forKey: "visit")
            device?.removeValue(forKey: "deviceLocation")
            device?.removeValue(forKey: "location")
        }
        if !policy.wifi {
            payload.removeValue(forKey: "wifis")
            if payload["visit"]?.object?["source"] == .string(VisitEventSource.wifi.rawValue) {
                payload.removeValue(forKey: "visit")
            }
            for key in ["apId", "wifiSSID"] { payload.removeValue(forKey: key); device?.removeValue(forKey: key) }
            if var network = device?["network"]?.object {
                network.removeValue(forKey: "apId")
                network.removeValue(forKey: "wifiSSID")
                device?["network"] = .object(network)
            }
        }
        if !policy.advertisingId {
            for key in ["advertisingId", "trackingAuthorization"] {
                payload.removeValue(forKey: key)
                device?.removeValue(forKey: key)
            }
            if var permissions = device?["permissions"]?.object {
                permissions.removeValue(forKey: "advertisingId")
                permissions.removeValue(forKey: "trackingAuthorization")
                device?["permissions"] = .object(permissions)
            }
        }
        if let device { payload["device"] = .object(device) }
        if let motion = result.sampling?.motion { result.sampling?.motion = motion.filtered(policy: policy) }
        let sensors = result.capturedPolicy.effectiveMotionSensors && policy.motionSensors
        result.capturedPolicy.advertisingId = result.capturedPolicy.advertisingId && policy.advertisingId
        result.capturedPolicy.location = result.capturedPolicy.location && policy.location
        result.capturedPolicy.wifi = result.capturedPolicy.wifi && policy.wifi
        if result.capturedPolicy.motionSensors != nil || sensors != (result.capturedPolicy.location || result.capturedPolicy.wifi) {
            result.capturedPolicy.motionSensors = sensors
        }
        result.originalPayload = payload
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func canonicalOrder(_ values: [ObservationJSONValue]) -> [ObservationJSONValue] {
            values.sorted {
                let first = (try? encoder.encode($0)) ?? Data()
                let second = (try? encoder.encode($1)) ?? Data()
                return first.lexicographicallyPrecedes(second)
            }
        }
        var context: [String: ObservationJSONValue] = [:]
        if payload["device"]?.object != nil || payload["sdk"]?.object != nil {
            context["tenant"] = tenantFingerprint.map { .string($0) } ?? .null
            context["deviceId"] = payload["device"]?.object?["deviceId"] ?? .null
            context["appId"] = payload["sdk"]?.object?["appId"] ?? .null
            context["policy"] = .object(["advertisingId": .bool(result.capturedPolicy.advertisingId),
                                        "location": .bool(result.capturedPolicy.location), "wifi": .bool(result.capturedPolicy.wifi)])
            if let contextID {
                context["contextID"] = .string(contextID)
            } else {
                if let location = payload["location"]?.object {
                    context["location"] = .object(location.filter { ["latitude", "longitude"].contains($0.key) })
                }
                if let wifis = payload["wifis"]?.array {
                    context["wifis"] = .array(canonicalOrder(wifis.compactMap { $0.object }.map {
                        .object($0.filter { ["apId", "connected"].contains($0.key) })
                    }))
                }
                context["apId"] = payload["device"]?.object?["network"]?.object?["apId"] ?? .null
                context["beacons"] = .array(canonicalOrder((payload["beacons"]?.array ?? []).compactMap { $0.object }.map {
                    .object($0.filter { ["uuid", "major", "minor"].contains($0.key) })
                }))
            }
        }
        result.contextFingerprint = context.isEmpty ? nil : (try? encoder.encode(context)).map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        }
        var absent = Set(result.absentFields)
        for key in ["sdk", "device", "userProperties", "location", "wifis", "encounters", "encounterIds"] {
            if payload[key] == nil || payload[key] == .null { absent.insert(key) }
        }
        if !policy.location { absent.insert("location"); absent.insert("device.deviceLocation") }
        if !policy.wifi { absent.formUnion(["wifis", "device.network.apId", "device.network.wifiSSID"]) }
        if !policy.advertisingId { absent.formUnion(["device.permissions.advertisingId", "device.permissions.trackingAuthorization"]) }
        for (container, keys) in [("network", ["apId", "wifiSSID"]), ("permissions", ["advertisingId", "trackingAuthorization"])] {
            for key in keys where device?[container]?.object?[key] == nil {
                absent.insert("device.\(container).\(key)")
            }
        }
        if result.tenantFingerprint == nil { absent.insert("tenantFingerprint") }
        if result.contextFingerprint == nil { absent.insert("originalContext") }
        if result.sampling == nil { absent.formUnion(["sampling", "clock", "motion"]) }
        result.absentFields = absent.sorted()
        return result
    }

    func replayPayload(manifest: SamplingReplayManifest) throws -> [String: Any]? {
        guard canReplay, manifest.batchIds.count <= 128, manifest.count == manifest.batchIds.count,
              manifest.index >= 0, manifest.index < manifest.count,
              manifest.batchIds[manifest.index] == batchId,
              manifest.batchIds.allSatisfy({ UUID(uuidString: $0) != nil }),
              Set(manifest.batchIds).count == manifest.batchIds.count,
              UUID(uuidString: manifest.drainId) != nil else { return nil }
        var payload = originalPayload.mapValues { $0.foundationValue }
        if deliveryProtocol == .legacy { return payload }
        var wire = sampling!
        wire.replay = manifest
        payload["sampling"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(wire))
        return payload
    }
}
