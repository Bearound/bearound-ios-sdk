import Foundation

struct AdaptiveSamplingResponse: Decodable {
    struct RequestEncodings: Decodable {
        let values: [String]
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let decoded = try? container.decode([String].self)
            values = decoded == ["gzip"] ? ["gzip"] : []
        }
    }
    struct Capability: Decodable {
        let version: Int
        let modes: [String]
        let leaseMs: Int64
        let serverTimeMs: Int64
        let servicesCadenceMs: Int64
        let mapTtlMs: Int64
        let sessionTimeoutMs: Int64
        let liveEvidenceMaxAgeMs: Int64
        let clockSkewToleranceMs: Int64
        let maxPayloadBytes: Int
        let requestContentEncodings: RequestEncodings?

        func isValid(baselineMs: Int64) -> Bool {
            version == 1 && Set(modes) == Set(["live", "summary", "transition"])
                && (1 ... 300_000).contains(leaseMs) && serverTimeMs > 0
                && servicesCadenceMs > 0 && mapTtlMs >= 3 && sessionTimeoutMs / 3 >= baselineMs
                && (1 ... 30_000).contains(liveEvidenceMaxAgeMs)
                && (1 ... 120_000).contains(clockSkewToleranceMs) && (1 ... 524_288).contains(maxPayloadBytes)
        }
    }
    struct Capabilities: Decodable { let adaptiveSampling: Capability? }
    struct Ack: Decodable {
        let batchId: String
        let archive: String
        let projection: String
        let reason: String?
        let fallback: String
        let invalidateCapability: Bool

        func confirms(_ id: String) -> Bool {
            batchId == id && archive == "durable"
                && ["applied", "duplicate", "archive_only", "pending_history"].contains(projection)
                && ["keep", "legacy_now"].contains(fallback)
                && (reason == nil || ["historical_already_closed", "time_uncertain", "history_incomplete",
                    "ledger_unavailable", "projection_capacity", "capability_disabled"].contains(reason!))
        }
    }
    let samplingAck: Ack?
    let capabilities: Capabilities?

    static func decode(_ data: Data) -> AdaptiveSamplingResponse? {
        try? JSONDecoder().decode(Self.self, from: data)
    }
}

final class AdaptiveSamplingRuntime {
    let configuration: SDKConfiguration
    let tenantFingerprint: String
    let generation: UInt64
    let policy: AdaptiveSamplingPolicy
    private(set) var diagnostics = BeAroundSamplingDiagnostics()
    private(set) var contextID = UUID().uuidString
    private var summary: ObservationSummary
    private var capability: AdaptiveSamplingResponse.Capability?
    private var leaseClock: SamplingClock?
    private var rejectedGzipLease: RequestEncodingLease?
    private(set) var httpAttempts: Int64 = 0
    private var serverOffsetMs: Int64?
    private var offsetUncertaintyMs: Int64?
    private var contextPayload: [String: ObservationJSONValue]?
    private var nextContextAtMs: Int64 = 0
    private var lastLiveAtMs: Int64?
    private var lastSummaryAtMs: Int64?
    private var lastClock: SamplingClock?
    private var freshSourceTimes: [String: Int64] = [:]
    private var sourceSet = Set<String>()
    private var venueRSSIs: [String: Int] = [:]
    private var previousState: MotionState?
    private var previousMode: SamplingPlan.Mode?
    private var contextLocation: SamplingLocationObservation?
    private var pending: [StoredObservationEnvelope] = []
    private var adaptiveWindowEligible = false
    private var minimumSourceTimestampMs: Int64 = 0

    init(configuration: SDKConfiguration, deviceID: String, generation: UInt64 = 0) {
        self.configuration = configuration
        self.generation = generation
        tenantFingerprint = SamplingTenantFingerprint.make(endpoint: configuration.apiBaseURL,
            appID: configuration.appId, deviceID: deviceID, businessToken: configuration.businessToken)
        policy = AdaptiveSamplingPolicy(generation: generation)
        summary = ObservationSummary()
        diagnostics.generation = generation
    }

    private var baselineMs: Int64 { Int64(configuration.syncInterval * 1_000) }

    func hasCapability(at now: SamplingClock) -> Bool {
        guard configuration.adaptiveSamplingEnabled, let capability, let leaseClock,
              now.isReliable, now.bootIdentifier == leaseClock.bootIdentifier,
              now.monotonicTimeMs >= leaseClock.monotonicTimeMs,
              now.monotonicTimeMs - leaseClock.monotonicTimeMs < capability.leaseMs,
              abs((now.wallTimeMs - leaseClock.wallTimeMs) - (now.monotonicTimeMs - leaseClock.monotonicTimeMs)) <= 5_000
        else { return false }
        return true
    }

    var liveEvidenceMaxAgeMs: Int64 { capability?.liveEvidenceMaxAgeMs ?? 30_000 }
    var maximumJSONBytes: Int { capability?.maxPayloadBytes ?? 524_288 }

    func requestEncodingLease(at now: SamplingClock) -> RequestEncodingLease? {
        guard hasCapability(at: now), capability?.requestContentEncodings?.values == ["gzip"],
              let capability, let leaseClock else { return nil }
        if let rejectedGzipLease, rejectedGzipLease.bootIdentifier == now.bootIdentifier,
           now.monotonicTimeMs < rejectedGzipLease.expiresAtMonotonicMs { return nil }
        let expiry = leaseClock.monotonicTimeMs.addingReportingOverflow(capability.leaseMs)
        guard !expiry.overflow else { return nil }
        return RequestEncodingLease(bootIdentifier: now.bootIdentifier, expiresAtMonotonicMs: expiry.partialValue)
    }

    func rejectRequestEncoding(_ lease: RequestEncodingLease) {
        if let previous = rejectedGzipLease, previous.bootIdentifier == lease.bootIdentifier,
           previous.expiresAtMonotonicMs >= lease.expiresAtMonotonicMs { return }
        rejectedGzipLease = lease
    }

    func recordHTTPAttempt(bytes: Int) {
        httpAttempts += 1
        diagnostics.serializedBytes += Int64(bytes)
    }

    func payloadFitsCapability(_ bytes: Int) -> Bool {
        guard bytes > 0, bytes <= (capability?.maxPayloadBytes ?? 524_288) else {
            invalidateCapability(reason: "capacity")
            diagnostics.policyDenials += 1
            return false
        }
        return true
    }

    func acceptResponse(_ data: Data, requestedAt: SamplingClock, receivedAt: SamplingClock, generation: UInt64) {
        guard generation == self.generation, let response = AdaptiveSamplingResponse.decode(data) else { return }
        if let ack = response.samplingAck, ack.confirms(ack.batchId) {
            if ack.projection == "archive_only" { diagnostics.archiveOnlyAcknowledgements += 1 }
            if ack.projection == "pending_history" { diagnostics.pendingHistoryAcknowledgements += 1 }
            if ack.reason == "history_incomplete" { diagnostics.manifestGaps += 1 }
        }
        if response.samplingAck?.invalidateCapability == true || response.samplingAck?.fallback == "legacy_now" {
            close(at: receivedAt)
            invalidateCapability(reason: "degraded")
            return
        }
        guard configuration.adaptiveSamplingEnabled, let advertised = response.capabilities?.adaptiveSampling,
              advertised.isValid(baselineMs: baselineMs), requestedAt.isReliable, receivedAt.isReliable,
              requestedAt.bootIdentifier == receivedAt.bootIdentifier,
              receivedAt.monotonicTimeMs >= requestedAt.monotonicTimeMs,
              abs((receivedAt.wallTimeMs - requestedAt.wallTimeMs) - (receivedAt.monotonicTimeMs - requestedAt.monotonicTimeMs)) <= 5_000 else {
            if response.capabilities?.adaptiveSampling != nil { invalidateCapability(reason: "incompatible") }
            return
        }
        let duration = receivedAt.monotonicTimeMs - requestedAt.monotonicTimeMs
        guard duration <= advertised.clockSkewToleranceMs else { invalidateCapability(reason: "clock_uncertain"); return }
        capability = advertised
        leaseClock = receivedAt
        serverOffsetMs = advertised.serverTimeMs - (requestedAt.wallTimeMs + duration / 2)
        offsetUncertaintyMs = duration / 2
        diagnostics.capability = "active"
    }

    func invalidateCapability(reason: String) {
        capability = nil
        leaseClock = nil
        serverOffsetMs = nil
        offsetUncertaintyMs = nil
        diagnostics.capability = reason
        diagnostics.capabilityInvalidations += 1
    }

    func invalidateContextMetadata(at now: SamplingClock) {
        close(at: now)
        contextPayload = nil
        nextContextAtMs = 0
        contextID = UUID().uuidString
    }

    func samplingPlan(at now: SamplingClock) -> SamplingPlan {
        let lease = hasCapability(at: now) ? capability : nil
        let plan = policy.plan(at: now, configuration: SamplingConfiguration(legacySyncIntervalMs: baselineMs,
            adaptiveSamplingEnabled: configuration.adaptiveSamplingEnabled,
            capability: lease.map { SamplingCapability(sessionTimeoutMs: $0.sessionTimeoutMs,
                advertisedServicesCadenceMs: $0.servicesCadenceMs, mapTTLms: $0.mapTtlMs) }),
            policy: configuration.dataCollectionPolicy)
        let evidence = policy.evidence(at: now, policy: configuration.dataCollectionPolicy)
        diagnostics.state = evidence.state.rawValue
        diagnostics.source = evidence.source.rawValue
        diagnostics.confidence = evidence.confidence.rawValue
        diagnostics.reason = evidence.reason
        diagnostics.evidenceAgeMs = evidence.ageMs
        diagnostics.contextStable = evidence.contextStable
        diagnostics.mode = plan.mode.rawValue
        diagnostics.contextIntervalMs = plan.contextIntervalMs ?? 60_000
        diagnostics.summaryIntervalMs = plan.summaryIntervalMs
        diagnostics.liveIntervalMs = plan.liveIntervalMs
        diagnostics.nextContextDeadlineMonotonicMs = contextPayload == nil ? nil : nextContextAtMs
        diagnostics.nextSummaryDeadlineMonotonicMs = lastSummaryAtMs.map { $0 + plan.summaryIntervalMs }
        diagnostics.nextLiveDeadlineMonotonicMs = lastLiveAtMs.map { $0 + plan.liveIntervalMs }
        if lease == nil, capability != nil { diagnostics.capability = "expired" }
        return plan
    }

    func observeNative(_ observation: NativeActivityObservation?, at now: SamplingClock, generation: UInt64) {
        guard generation == self.generation else { return }
        let previous = policy.evidence(at: now).state
        policy.observeNativeActivity(observation, at: now, generation: generation, policy: configuration.dataCollectionPolicy)
        if previous != policy.evidence(at: now).state {
            close(at: now, kind: .transition)
            contextID = UUID().uuidString
            previousState = policy.evidence(at: now).state
        }
        nextContextAtMs = min(nextContextAtMs, now.monotonicTimeMs + (samplingPlan(at: now).contextIntervalMs ?? 60_000))
    }

    func invalidateInertial(at now: SamplingClock) {
        policy.invalidateInertial()
        _ = samplingPlan(at: now)
    }

    func observeInertial(_ window: InertialWindow, at now: SamplingClock) {
        guard window.generation == generation else { return }
        let previous = policy.evidence(at: now, policy: configuration.dataCollectionPolicy).state
        policy.observeInertial(window, at: now, policy: configuration.dataCollectionPolicy)
        let current = policy.evidence(at: now, policy: configuration.dataCollectionPolicy).state
        if current != previous {
            close(at: now, kind: .transition)
            contextID = UUID().uuidString
            previousState = current
        }
        nextContextAtMs = min(nextContextAtMs, now.monotonicTimeMs + (samplingPlan(at: now).contextIntervalMs ?? 60_000))
    }

    func observePhysical(
        _ beacons: [Beacon], callbackID: String, at now: SamplingClock, isPhysical: Bool = true,
        existingEncounterFieldsProvider: () -> [String: Any] = { [:] },
        contextProvider: () -> [String: Any]
    ) {
        guard isPhysical else { diagnostics.cachedCallbacks += 1; return }
        guard pending.count < 32 else {
            invalidateCapability(reason: "capacity")
            diagnostics.policyDenials += 1
            return
        }
        guard now.isReliable else { diagnostics.clockUncertainties += 1; invalidateCapability(reason: "clock_uncertain"); return }
        if let lastClock, lastClock.bootIdentifier != now.bootIdentifier
            || now.monotonicTimeMs < lastClock.monotonicTimeMs
            || abs((now.wallTimeMs - lastClock.wallTimeMs) - (now.monotonicTimeMs - lastClock.monotonicTimeMs)) > 5_000 {
            close(at: lastClock)
            minimumSourceTimestampMs = lastClock.wallTimeMs
            summary.reset(captureStreamId: UUID().uuidString)
            policy.reset(generation: generation)
            invalidateCapability(reason: "clock_uncertain")
            freshSourceTimes.removeAll()
            venueRSSIs.removeAll()
            sourceSet.removeAll()
            contextPayload = nil
            contextLocation = nil
            diagnostics.clockUncertainties += 1
        }
        lastClock = now
        let adaptiveNow = hasCapability(at: now)
        if adaptiveNow != adaptiveWindowEligible {
            close(at: now)
            adaptiveWindowEligible = adaptiveNow
            contextID = UUID().uuidString
        }
        let fresh = beacons.filter {
            guard $0.major < Int(EncounterMeshManager.virtualBeaconMajorFloor) else { return false }
            let timestamp = Int64($0.timestamp.timeIntervalSince1970 * 1_000)
            return timestamp > minimumSourceTimestampMs && timestamp <= now.wallTimeMs && now.wallTimeMs - timestamp <= 30_000
                && timestamp > (freshSourceTimes[key($0)] ?? 0)
        }
        guard !fresh.isEmpty else { diagnostics.cachedCallbacks += 1; return }
        for beacon in fresh { freshSourceTimes[key(beacon)] = Int64(beacon.timestamp.timeIntervalSince1970 * 1_000) }
        freshSourceTimes = freshSourceTimes.filter { now.wallTimeMs - $0.value <= 30_000 }
        if freshSourceTimes.count > 4096 { freshSourceTimes = Dictionary(uniqueKeysWithValues: freshSourceTimes.sorted { $0.value > $1.value }.prefix(4096).map { ($0.key, $0.value) }) }
        let plan = samplingPlan(at: now)
        let previousPayload = contextPayload
        if contextPayload == nil || now.monotonicTimeMs >= nextContextAtMs {
            contextPayload = try? ObservationJSONValue.snapshot(contextProvider())
            nextContextAtMs = now.monotonicTimeMs + (plan.contextIntervalMs ?? 60_000)
        } else { diagnostics.complementaryCacheReads += 1 }
        guard var body = contextPayload else { return }
        if let encounterFields = try? ObservationJSONValue.snapshot(existingEncounterFieldsProvider()) {
            for name in ["encounters", "encounterIds"] where encounterFields[name] != nil {
                if encounterFields[name]?.array?.isEmpty == true { body.removeValue(forKey: name) }
                else { body[name] = encounterFields[name] }
            }
        }
        if var device = body["device"]?.object {
            device["timestamp"] = .number(Double(now.wallTimeMs))
            body["device"] = .object(device)
        }
        let venue = fresh.filter { $0.major < Int(EncounterMeshManager.virtualBeaconMajorFloor) }
        for beacon in venue {
            if (-127 ..< 0).contains(beacon.rssi) { venueRSSIs[key(beacon)] = beacon.rssi }
            else { venueRSSIs.removeValue(forKey: key(beacon)) }
        }
        venueRSSIs = venueRSSIs.filter { freshSourceTimes[$0.key] != nil }
        let newSet = Set(freshSourceTimes.keys)
        let union = sourceSet.union(newSet)
        let changed = !sourceSet.isEmpty && !union.isEmpty
            && Double(sourceSet.intersection(newSet).count) / Double(union.count) < 0.8
        let changedAP = previousPayload?["device"]?.object?["network"]?.object?["apId"] != body["device"]?.object?["network"]?.object?["apId"]
        if !venue.isEmpty && (changed || (previousPayload != nil && changedAP)) {
            close(at: now, kind: .transition)
            contextID = UUID().uuidString
        }
        if !venue.isEmpty { sourceSet = newSet }
        if !venue.isEmpty, configuration.dataCollectionPolicy.location,
           let location = body["location"]?.object,
           case .number(let timestamp) = location["timestamp"], case .number(let lat) = location["latitude"],
           case .number(let lon) = location["longitude"], case .number(let accuracy) = location["accuracy"],
           timestamp > Double(minimumSourceTimestampMs), timestamp <= Double(now.wallTimeMs),
           Double(now.wallTimeMs) - timestamp <= 60_000,
           lat.isFinite, (-90 ... 90).contains(lat), lon.isFinite, (-180 ... 180).contains(lon),
           accuracy.isFinite, accuracy > 0 {
            let fix = SamplingLocationObservation(observedAtMs: Int64(timestamp), provider: "existing_fix",
                latitude: lat, longitude: lon, accuracyMeters: accuracy)
            if let previous = contextLocation, fix.observedAtMs > previous.observedAtMs,
               hasMeaningfulDisplacement(previous, fix) {
                close(at: now, kind: .transition)
                contextID = UUID().uuidString
                contextLocation = fix
            } else if contextLocation == nil { contextLocation = fix }
            policy.observeLocation(fix, at: now, generation: generation, policy: configuration.dataCollectionPolicy)
        }
        let ap = body["device"]?.object?["network"]?.object?["apId"]?.foundationValue as? String
        if !venue.isEmpty, venueRSSIs.count == newSet.count {
            policy.observeContext(SamplingContextObservation(windowID: callbackID, observedAtMs: now.wallTimeMs,
                beaconRSSIs: venueRSSIs, connectedAP: ap),
                at: now, generation: generation, policy: configuration.dataCollectionPolicy)
        }
        let nextState = policy.evidence(at: now, policy: configuration.dataCollectionPolicy).state
        let nextMode = samplingPlan(at: now).mode
        if previousState.map({ $0 != nextState }) == true || previousMode.map({ $0 != nextMode }) == true {
            close(at: now, kind: .transition)
            contextID = UUID().uuidString
        }
        previousState = nextState
        previousMode = nextMode
        let context = ObservationSummary.Context(tenantFingerprint: tenantFingerprint, contextID: contextID,
            originalPayload: body, motion: policy.evidence(at: now, policy: configuration.dataCollectionPolicy),
            policy: configuration.dataCollectionPolicy)
        let capture = summary.observe(beacons: fresh, callbackID: callbackID, context: context, at: now, isPhysical: true)
        diagnostics.uniqueSamples += Int64(capture.acceptedSamples)
        diagnostics.cachedCallbacks += Int64(capture.duplicateSamples)
        for segment in capture.closedLiveSegments { enqueue(segment, at: now, kind: .live) }
        for segment in capture.closedSegments { enqueue(segment, at: now, kind: .summary) }
        let effective = samplingPlan(at: now)
        nextContextAtMs = min(nextContextAtMs, now.monotonicTimeMs + (effective.contextIntervalMs ?? 60_000))
        if hasCapability(at: now), !capture.liveBeacons.isEmpty,
           lastLiveAtMs.map({ now.monotonicTimeMs - $0 >= effective.liveIntervalMs }) ?? true {
            let eligible = summary.liveBeacons(at: now, maxAgeMs: capability?.liveEvidenceMaxAgeMs ?? 30_000, consume: true)
            if !eligible.isEmpty, let window = summary.activeWindowId {
                enqueue(body: body, beacons: eligible, windowId: window, from: eligible.compactMap { $0["timestamp"]?.foundationValue as? Double }.min().map(Int64.init) ?? now.wallTimeMs,
                    to: now.wallTimeMs, motion: context.motion, at: now, kind: .live)
                lastLiveAtMs = now.monotonicTimeMs
            }
        }
        if lastSummaryAtMs.map({ now.monotonicTimeMs - $0 >= effective.summaryIntervalMs }) ?? false {
            close(at: now)
        }
        if lastSummaryAtMs == nil { lastSummaryAtMs = now.monotonicTimeMs }
        if pending.count >= 32 { invalidateCapability(reason: "capacity"); diagnostics.policyDenials += 1 }
    }

    func close(at now: SamplingClock, kind: SamplingEnvelope.Kind = .summary) {
        if adaptiveWindowEligible,
           let live = summary.drainLiveSegment(at: now, maxAgeMs: capability?.liveEvidenceMaxAgeMs ?? 30_000) {
            enqueue(live, at: now, kind: .live)
        }
        if let segment = summary.close(at: now) { enqueue(segment, at: now, kind: kind) }
        lastSummaryAtMs = now.monotonicTimeMs
    }

    func takePending(at now: SamplingClock) -> [StoredObservationEnvelope] {
        if let deadline = lastSummaryAtMs, now.monotonicTimeMs - deadline >= samplingPlan(at: now).summaryIntervalMs { close(at: now) }
        let result = pending
        pending.removeAll()
        return result
    }

    func legacyEnvelope(beacons: [Beacon], payload: [String: Any], at now: SamplingClock) throws -> StoredObservationEnvelope {
        let id = UUID().uuidString
        let times = beacons.map { Int64($0.timestamp.timeIntervalSince1970 * 1_000) }
        let sampling = SamplingEnvelope(version: 1, kind: .live, batchId: id,
            captureStreamId: summary.captureStreamId, windowId: UUID().uuidString,
            observedFrom: times.min() ?? now.wallTimeMs, observedTo: times.max() ?? now.wallTimeMs,
            sentAt: now.wallTimeMs, motion: policy.evidence(at: now, policy: configuration.dataCollectionPolicy),
            clock: SamplingEnvelopeClock(bootId: now.bootIdentifier, wallTimeMs: now.wallTimeMs,
                monotonicTimeMs: now.monotonicTimeMs, serverOffsetMs: nil, offsetUncertaintyMs: nil,
                synchronizedAtMonotonicMs: nil), transitionReason: nil)
        return try StoredObservationEnvelope(batchId: id, storedAtMs: now.wallTimeMs,
            tenantFingerprint: tenantFingerprint, originalPayload: payload, sampling: sampling,
            policy: configuration.dataCollectionPolicy, contextID: contextID, deliveryProtocol: .legacy)
    }

    static func isCurrentLive(_ envelope: StoredObservationEnvelope, at now: SamplingClock, maxAgeMs: Int64 = 30_000) -> Bool {
        guard envelope.deliveryProtocol == .adaptive, let sampling = envelope.sampling, sampling.kind == .live,
              now.isReliable, sampling.clock.bootId == now.bootIdentifier,
              now.monotonicTimeMs >= sampling.clock.monotonicTimeMs,
              abs((now.wallTimeMs - sampling.clock.wallTimeMs) - (now.monotonicTimeMs - sampling.clock.monotonicTimeMs)) <= 5_000,
              sampling.observedTo <= now.wallTimeMs, now.wallTimeMs - sampling.observedFrom <= maxAgeMs else { return false }
        return true
    }

    static func canDeliver(_ envelope: StoredObservationEnvelope, at now: SamplingClock, capabilityAvailable: Bool) -> Bool {
        guard envelope.canReplay else { return false }
        if envelope.deliveryProtocol == .adaptive { return capabilityAvailable }
        guard let original = envelope.sampling, now.isReliable,
              original.clock.bootId == now.bootIdentifier,
              now.monotonicTimeMs >= original.clock.monotonicTimeMs,
              abs((now.wallTimeMs - original.clock.wallTimeMs) - (now.monotonicTimeMs - original.clock.monotonicTimeMs)) <= 5_000,
              original.observedTo <= now.wallTimeMs, now.wallTimeMs - original.observedFrom <= 30_000 else { return false }
        return true
    }

    func deliveryFailed(_ error: Error) {
        if case APIError.httpError(let status, _) = error, [400, 401, 413, 422, 503].contains(status) {
            invalidateCapability(reason: "rejected")
        }
    }

    func physicalEvidenceIsFresh(_ beacon: Beacon, at now: SamplingClock) -> Bool {
        let observed = Int64(beacon.timestamp.timeIntervalSince1970 * 1_000)
        return freshSourceTimes[key(beacon)] == observed && observed <= now.wallTimeMs && now.wallTimeMs - observed <= 30_000
    }

    func recordAttempt(_ envelope: StoredObservationEnvelope, bytes: Int, failed: Bool, at now: SamplingClock) {
        switch envelope.sampling?.kind {
        case .summary: diagnostics.summaryAttempts += 1
        case .transition: diagnostics.transitionAttempts += 1
        default: diagnostics.liveAttempts += 1
        }
        diagnostics.serializedBytes += Int64(bytes)
        if failed { diagnostics.failures += 1 }
        diagnostics.retryLagMs = max(0, now.wallTimeMs - (envelope.sampling?.observedTo ?? envelope.storedAtMs))
    }

    func recordDeliveryFailure() { diagnostics.failures += 1 }

    private func hasMeaningfulDisplacement(_ first: SamplingLocationObservation, _ second: SamplingLocationObservation) -> Bool {
        let radians = Double.pi / 180
        let lat = (second.latitude - first.latitude) * radians
        let lon = (second.longitude - first.longitude) * radians
        let h = pow(sin(lat / 2), 2) + cos(first.latitude * radians) * cos(second.latitude * radians) * pow(sin(lon / 2), 2)
        let meters = 6_371_000 * 2 * asin(sqrt(min(1, h)))
        return meters > max(25, first.accuracyMeters + second.accuracyMeters)
    }

    private func key(_ beacon: Beacon) -> String { "\(beacon.uuid.uuidString):\(beacon.major):\(beacon.minor)" }

    private func enqueue(_ segment: ObservationSummary.Segment, at now: SamplingClock, kind: SamplingEnvelope.Kind) {
        guard adaptiveWindowEligible else { return }
        if kind != .live {
            diagnostics.gaps += segment.gapCount
            diagnostics.buckets += segment.beacons.reduce(0) { $0 + ($1["temporalBuckets"]?.array?.count ?? 0) }
        }
        enqueue(body: segment.context.originalPayload, beacons: segment.beacons, windowId: segment.windowId,
            from: segment.observedFrom, to: segment.observedTo, motion: segment.context.motion, at: now, kind: kind, originalContextID: segment.context.contextID)
    }

    private func enqueue(
        body: [String: ObservationJSONValue], beacons: [[String: ObservationJSONValue]], windowId: String,
        from: Int64, to: Int64, motion: MotionEvidence, at now: SamplingClock, kind: SamplingEnvelope.Kind, originalContextID: String? = nil
    ) {
        guard configuration.adaptiveSamplingEnabled, !beacons.isEmpty else { return }
        var payload = body.mapValues { $0.foundationValue }
        payload["beacons"] = beacons.map { $0.mapValues { $0.foundationValue } }
        let batchId = UUID().uuidString
        let sampling = SamplingEnvelope(version: 1, kind: kind, batchId: batchId, captureStreamId: summary.captureStreamId,
            windowId: windowId, observedFrom: from, observedTo: to, sentAt: now.wallTimeMs, motion: motion,
            clock: SamplingEnvelopeClock(bootId: now.bootIdentifier, wallTimeMs: now.wallTimeMs, monotonicTimeMs: now.monotonicTimeMs,
                serverOffsetMs: serverOffsetMs, offsetUncertaintyMs: offsetUncertaintyMs,
                synchronizedAtMonotonicMs: leaseClock?.monotonicTimeMs), transitionReason: kind == .transition ? .contextChanged : nil)
        if let envelope = try? StoredObservationEnvelope(batchId: batchId, storedAtMs: now.wallTimeMs,
            tenantFingerprint: tenantFingerprint, originalPayload: payload, sampling: sampling,
            policy: configuration.dataCollectionPolicy, contextID: originalContextID ?? contextID, deliveryProtocol: .adaptive) {
            pending.append(envelope)
        }
    }
}
