import Foundation

final class AdaptiveSamplingPolicy {
    private struct Timed<Value> {
        let value: Value
        let clock: SamplingClock
        let observedAtMs: Int64
        let initialAgeMs: Int64

        func age(at now: SamplingClock) -> Int64 {
            initialAgeMs + now.monotonicTimeMs - clock.monotonicTimeMs
        }
    }

    private(set) var generation: UInt64
    private var anchor: SamplingClock?
    private var native: Timed<NativeActivityObservation>?
    private var locations: [Timed<SamplingLocationObservation>] = []
    private var contexts: [Timed<SamplingContextObservation>] = []
    private var seenContextIDs = Set<String>()
    private var candidateStarted: SamplingClock?
    private var noveltyUntilMs: Int64?
    private var noveltySource: MotionSource = .none
    private var pendingTransition = false
    private var fallbackReason = "startup"
    private var collectionPolicy = DataCollectionPolicy.allEnabled

    init(generation: UInt64 = 0) {
        self.generation = generation
    }

    func reset(generation: UInt64) {
        self.generation = generation
        clearEvidence()
        anchor = nil
    }

    func invalidateNativeActivity(reason: String = "permission_unavailable") {
        native = nil
        candidateStarted = nil
        fallbackReason = reason
        removeNovelty(from: .nativeActivity)
    }

    func observeNativeActivity(
        _ activity: NativeActivityObservation?, at now: SamplingClock, generation: UInt64
    ) {
        guard generation == self.generation, prepare(at: now, policy: collectionPolicy) else { return }
        guard let activity else {
            invalidateNativeActivity()
            return
        }
        guard let timestamp = activity.observedAtMs,
              let observation = timed(activity, timestamp: timestamp, at: now, ttl: 120_000) else {
            invalidateNativeActivity(reason: "evidence_expired")
            return
        }
        if let previous = native, timestamp <= previous.observedAtMs { return }
        let wasMoving = native?.value.moving == true
        let wasStationary = native?.value.stationary == true
        native = observation
        if activity.moving, !wasMoving {
            markNovelty(at: now, source: .nativeActivity, ageMs: observation.initialAgeMs)
            locations.removeAll()
        }
        if activity.stationary, !activity.walking, !activity.running, !activity.cycling {
            if !wasStationary {
                // Dwell starts at this process observation, never at a historical activity date.
                candidateStarted = now
            }
        } else {
            candidateStarted = nil
        }
    }

    func observeLocation(
        _ fix: SamplingLocationObservation, at now: SamplingClock, generation: UInt64,
        policy: DataCollectionPolicy = .allEnabled
    ) {
        guard generation == self.generation, prepare(at: now, policy: policy), policy.location,
              valid(fix), let observation = timed(fix, timestamp: fix.observedAtMs, at: now, ttl: 60_000)
        else { return }
        guard !locations.contains(where: {
            $0.value.observedAtMs == fix.observedAtMs && $0.value.provider == fix.provider
        }), locations.last.map({ fix.observedAtMs > $0.observedAtMs }) ?? true else { return }
        if let previous = locations.last, resolvesMovement(previous.value, fix) {
            markNovelty(at: now, source: .freshLocation, ageMs: observation.initialAgeMs)
            candidateStarted = nil
            locations.removeAll()
            locations.append(previous)
        }
        locations.append(observation)
        locations = Array(locations.suffix(8))
    }

    func observeContext(
        _ context: SamplingContextObservation, at now: SamplingClock, generation: UInt64,
        policy: DataCollectionPolicy = .allEnabled
    ) {
        var filteredContext = context
        if !policy.wifi { filteredContext.connectedAP = nil }
        guard generation == self.generation, prepare(at: now, policy: policy),
              context.isFresh, !context.isCoalesced, !context.windowID.isEmpty,
              !seenContextIDs.contains(context.windowID), !context.beaconRSSIs.isEmpty,
              context.beaconRSSIs.values.allSatisfy({ (-127 ..< 0).contains($0) }),
              let observation = timed(filteredContext, timestamp: context.observedAtMs, at: now, ttl: 30_000)
        else { return }
        let previous = contexts.last
        guard previous.map({ context.observedAtMs > $0.observedAtMs }) ?? true else { return }
        seenContextIDs.insert(context.windowID)
        if let previous, !matchesContext(previous.value, context, wifiEnabled: policy.wifi) {
            contexts.removeAll()
            locations.removeAll()
            candidateStarted = native?.value.stationary == true ? now : nil
            markNovelty(at: now, source: .contextFusion, ageMs: observation.initialAgeMs)
        } else if previous == nil {
            markNovelty(at: now, source: .contextFusion, ageMs: observation.initialAgeMs)
        } else if let previous, context.observedAtMs - previous.observedAtMs < 20_000 {
            return
        }
        contexts.append(observation)
        contexts = Array(contexts.suffix(16))
        // IDs are retained across TTL expiry so replay cannot become a new window.
    }

    func evidence(
        at now: SamplingClock, policy: DataCollectionPolicy = .allEnabled
    ) -> MotionEvidence {
        guard prepare(at: now, policy: policy) else { return unknown("clock_uncertain") }
        let stable = contextIsStable(at: now)
        if let native, native.age(at: now) <= 120_000 {
            let activity = native.value
            if activity.automotive, activity.stationary {
                return evidence(.stationaryCandidate, .nativeActivity, activity.confidence,
                                "native_stationary_candidate", native, stable: stable, at: now)
            }
            if activity.moving {
                return evidence(.movingConfirmed, .nativeActivity, activity.confidence,
                                "native_moving", native, stable: stable, at: now)
            }
            if activity.stationary {
                if !locationShowsMovement(at: now), let started = candidateStarted,
                   now.monotonicTimeMs - started.monotonicTimeMs >= 60_000,
                   let context = contexts.last, context.age(at: now) <= 30_000,
                   context.clock.monotonicTimeMs > started.monotonicTimeMs {
                    return evidence(.stationaryConfirmed, .nativeActivity, activity.confidence,
                                    "native_stationary_confirmed", native, stable: stable, at: now)
                }
                return evidence(.stationaryCandidate, .nativeActivity, activity.confidence,
                                "native_stationary_candidate", native, stable: stable, at: now)
            }
        }
        if locationShowsMovement(at: now), let last = locations.last {
            return evidence(.movingInferred, .freshLocation, .low, "location_displacement",
                            last, stable: stable, at: now)
        }
        if stable, locationSupportsStationary(at: now), let last = locations.last {
            return evidence(.stationaryInferred, .contextFusion, .low, "stationary_inferred",
                            last, stable: true, at: now)
        }
        return unknown(stable ? "context_stable" : fallbackReason, stable: stable)
    }

    func plan(
        at now: SamplingClock, configuration: SamplingConfiguration,
        policy: DataCollectionPolicy = .allEnabled
    ) -> SamplingPlan {
        let motion = evidence(at: now, policy: policy)
        let baseline = max(1, configuration.legacySyncIntervalMs)
        guard configuration.adaptiveSamplingEnabled, let capability = configuration.capability,
              min(300_000, capability.sessionTimeoutMs / 3) >= baseline,
              capability.advertisedServicesCadenceMs > 0, capability.mapTTLms >= 3 else {
            return SamplingPlan(mode: .legacy, contextIntervalMs: nil, summaryIntervalMs: baseline,
                                liveIntervalMs: baseline, flushRelevantTransition: false)
        }
        let live = min(baseline, capability.advertisedServicesCadenceMs, 60_000, capability.mapTTLms / 3)
        let ceiling = capability.sessionTimeoutMs / 3
        let mode: SamplingPlan.Mode
        let context: Int64
        let summary: Int64
        if let until = noveltyUntilMs, now.monotonicTimeMs < until {
            mode = .novelty
            context = 30_000
            summary = min(baseline, 15_000)
        } else if motion.contextStable {
            mode = .stable
            context = 300_000
            summary = max(baseline, min(300_000, ceiling))
        } else if motion.state == .movingConfirmed || motion.state == .movingInferred {
            mode = .moving
            context = 60_000
            summary = min(60_000, ceiling)
        } else {
            mode = .conservative
            context = 60_000
            summary = baseline
        }
        let flush = pendingTransition && (noveltyUntilMs.map { now.monotonicTimeMs < $0 } ?? false)
        pendingTransition = false
        return SamplingPlan(mode: mode, contextIntervalMs: context, summaryIntervalMs: summary,
                            liveIntervalMs: live, flushRelevantTransition: flush)
    }

    private func prepare(at now: SamplingClock, policy: DataCollectionPolicy) -> Bool {
        if !policy.location, !locations.isEmpty {
            locations.removeAll()
            fallbackReason = "source_disabled"
            removeNovelty(from: .freshLocation)
        }
        if policy.wifi != collectionPolicy.wifi {
            contexts.removeAll()
            candidateStarted = nil
            removeNovelty(from: .contextFusion)
        }
        collectionPolicy = policy
        guard now.isReliable, now.monotonicTimeMs >= 0 else {
            clearEvidence()
            anchor = nil
            return false
        }
        if let anchor, anchor.bootIdentifier != now.bootIdentifier
            || now.monotonicTimeMs < anchor.monotonicTimeMs
            || abs((now.wallTimeMs - anchor.wallTimeMs) - (now.monotonicTimeMs - anchor.monotonicTimeMs)) > 5_000 {
            clearEvidence()
            self.anchor = now
            return false
        }
        anchor = now
        if let native, native.age(at: now) > 120_000 { invalidateNativeActivity(reason: "evidence_expired") }
        if let last = contexts.last, last.age(at: now) > 120_000 { contexts.removeAll() }
        if let last = locations.last, last.age(at: now) > 60_000 {
            locations.removeAll()
            fallbackReason = "evidence_expired"
        }
        return true
    }

    private func clearEvidence() {
        invalidateNativeActivity(reason: "startup")
        locations.removeAll()
        contexts.removeAll()
        seenContextIDs.removeAll()
        noveltyUntilMs = nil
        noveltySource = .none
        pendingTransition = false
    }

    private func timed<T>(_ value: T, timestamp: Int64, at now: SamplingClock, ttl: Int64) -> Timed<T>? {
        let age = now.wallTimeMs - timestamp
        guard age >= 0, age <= ttl else { return nil }
        return Timed(value: value, clock: now, observedAtMs: timestamp, initialAgeMs: age)
    }

    private func markNovelty(at now: SamplingClock, source: MotionSource, ageMs: Int64 = 0) {
        let remaining = max(0, 90_000 - ageMs)
        noveltyUntilMs = now.monotonicTimeMs + remaining
        noveltySource = source
        pendingTransition = remaining > 0
    }

    private func removeNovelty(from source: MotionSource) {
        guard noveltySource == source else { return }
        noveltyUntilMs = nil
        noveltySource = .none
        pendingTransition = false
    }

    private func contextIsStable(at now: SamplingClock) -> Bool {
        guard contexts.count >= 3, let first = contexts.first, let last = contexts.last,
              last.age(at: now) <= 30_000 else { return false }
        return last.observedAtMs - first.observedAtMs >= 120_000
    }

    private func matchesContext(
        _ first: SamplingContextObservation, _ second: SamplingContextObservation, wifiEnabled: Bool
    ) -> Bool {
        if wifiEnabled, (first.connectedAP != nil || second.connectedAP != nil),
           first.connectedAP != second.connectedAP { return false }
        let a = Set(first.beaconRSSIs.keys)
        let b = Set(second.beaconRSSIs.keys)
        let similarity = Double(a.intersection(b).count) / Double(a.union(b).count)
        return similarity >= 0.8 && abs(median(first.beaconRSSIs) - median(second.beaconRSSIs)) <= 8
    }

    private func median(_ readings: [String: Int]) -> Double {
        let sorted = readings.values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? Double(sorted[middle - 1] + sorted[middle]) / 2 : Double(sorted[middle])
    }

    private func valid(_ fix: SamplingLocationObservation) -> Bool {
        fix.latitude.isFinite && (-90 ... 90).contains(fix.latitude)
            && fix.longitude.isFinite && (-180 ... 180).contains(fix.longitude)
            && fix.accuracyMeters.isFinite && fix.accuracyMeters > 0 && fix.accuracyMeters <= 50
            && !fix.provider.isEmpty
    }

    private func distance(_ first: SamplingLocationObservation, _ second: SamplingLocationObservation) -> Double {
        let radians = Double.pi / 180
        let lat = (second.latitude - first.latitude) * radians
        let lon = (second.longitude - first.longitude) * radians
        let h = pow(sin(lat / 2), 2) + cos(first.latitude * radians)
            * cos(second.latitude * radians) * pow(sin(lon / 2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, h)))
    }

    private func resolvesMovement(_ first: SamplingLocationObservation, _ second: SamplingLocationObservation) -> Bool {
        let interval = second.observedAtMs - first.observedAtMs
        guard (5_000 ... 120_000).contains(interval) else { return false }
        let displacement = distance(first, second)
        return displacement > max(25, first.accuracyMeters + second.accuracyMeters)
            && displacement / (Double(interval) / 1_000) >= 0.8
    }

    private func locationShowsMovement(at now: SamplingClock) -> Bool {
        guard locations.count >= 2, let last = locations.last, last.age(at: now) <= 60_000 else { return false }
        let previous = locations[locations.count - 2]
        return previous.age(at: now) <= 60_000 && resolvesMovement(previous.value, last.value)
    }

    private func locationSupportsStationary(at now: SamplingClock) -> Bool {
        guard locations.count >= 3, let first = locations.first, let last = locations.last,
              last.age(at: now) <= 60_000, last.observedAtMs - first.observedAtMs >= 120_000 else { return false }
        return zip(locations, locations.dropFirst()).allSatisfy {
            (5_000 ... 120_000).contains($1.observedAtMs - $0.observedAtMs)
                && distance($0.value, $1.value) <= max(25, $0.value.accuracyMeters + $1.value.accuracyMeters)
        }
    }

    private func unknown(_ reason: String, stable: Bool = false) -> MotionEvidence {
        MotionEvidence(state: .unknown, source: .none, confidence: .none, reason: reason,
                       observedAtMs: nil, ageMs: nil, contextStable: stable)
    }

    private func evidence<T>(
        _ state: MotionState, _ source: MotionSource, _ confidence: MotionConfidence, _ reason: String,
        _ observation: Timed<T>, stable: Bool, at now: SamplingClock
    ) -> MotionEvidence {
        MotionEvidence(state: state, source: source, confidence: confidence, reason: reason,
                       observedAtMs: observation.observedAtMs, ageMs: observation.age(at: now), contextStable: stable)
    }
}
