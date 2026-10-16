import Foundation
import Testing
@testable import BearoundSDK

@Suite("Adaptive Sampling Policy Tests")
struct AdaptiveSamplingPolicyTests {
    private func clock(_ seconds: Int64, boot: String = "boot") -> SamplingClock {
        SamplingClock(wallTimeMs: 1_000_000 + seconds * 1_000,
                      monotonicTimeMs: seconds * 1_000, bootIdentifier: boot)
    }

    private func context(_ seconds: Int64, id: String? = nil, beacon: String = "beacon", ap: String? = "ap") -> SamplingContextObservation {
        SamplingContextObservation(windowID: id ?? String(seconds), observedAtMs: clock(seconds).wallTimeMs,
                                   beaconRSSIs: [beacon: -60], connectedAP: ap)
    }

    private func fix(_ seconds: Int64, longitude: Double = 0, accuracy: Double = 10) -> SamplingLocationObservation {
        SamplingLocationObservation(observedAtMs: clock(seconds).wallTimeMs, provider: "existing_fix",
                                    latitude: 0, longitude: longitude, accuracyMeters: accuracy)
    }

    private var configuration: SamplingConfiguration {
        SamplingConfiguration(legacySyncIntervalMs: 15_000, capability: SamplingCapability(
            sessionTimeoutMs: 900_000, advertisedServicesCadenceMs: 60_000, mapTTLms: 180_000
        ))
    }

    private func stablePolicy(withLocations: Bool = false) -> AdaptiveSamplingPolicy {
        let policy = AdaptiveSamplingPolicy()
        for seconds: Int64 in [0, 60, 120] {
            if withLocations { policy.observeLocation(fix(seconds), at: clock(seconds), generation: 0) }
            policy.observeContext(context(seconds), at: clock(seconds), generation: 0)
        }
        return policy
    }

    @Test("A new policy is unknown and preserves legacy cadence without capability")
    func startupAndLegacy() {
        let policy = AdaptiveSamplingPolicy()
        let evidence = policy.evidence(at: clock(0))
        #expect(evidence.state == .unknown)
        #expect(evidence.reason == "startup")
        #expect(evidence.source == .none && evidence.confidence == .none)
        #expect(evidence.observedAtMs == nil && evidence.ageMs == nil)
        let plan = policy.plan(at: clock(0), configuration: SamplingConfiguration(legacySyncIntervalMs: 5_000))
        #expect(plan.mode == .legacy && plan.summaryIntervalMs == 5_000)
        #expect(plan.contextIntervalMs == nil && plan.liveIntervalMs == 5_000)
    }

    @Test("Native movement preserves original time confidence and monotonic age")
    func nativeMovement() {
        let policy = AdaptiveSamplingPolicy()
        policy.observeNativeActivity(NativeActivityObservation(observedAtMs: clock(0).wallTimeMs,
                                                              walking: true, confidence: .high),
                                     at: clock(10), generation: 0)
        let evidence = policy.evidence(at: clock(20))
        #expect(evidence.state == .movingConfirmed && evidence.source == .nativeActivity)
        #expect(evidence.confidence == .high && evidence.reason == "native_moving")
        #expect(evidence.observedAtMs == clock(0).wallTimeMs && evidence.ageMs == 20_000)
    }

    @Test("Expired future and missing activity timestamps cannot create motion")
    func invalidNativeTimestamps() {
        for timestamp: Int64? in [nil, clock(121).wallTimeMs, clock(-121).wallTimeMs] {
            let policy = AdaptiveSamplingPolicy()
            policy.observeNativeActivity(NativeActivityObservation(observedAtMs: timestamp, running: true,
                                                                  confidence: .high), at: clock(0), generation: 0)
            #expect(policy.evidence(at: clock(0)).state == .unknown)
            #expect(policy.plan(at: clock(0), configuration: configuration).mode == .conservative)
        }
    }

    @Test("A delayed native update cannot renew the ninety second novelty window")
    func delayedNativeNovelty() {
        let policy = AdaptiveSamplingPolicy()
        policy.observeNativeActivity(NativeActivityObservation(observedAtMs: clock(0).wallTimeMs,
                                                              walking: true, confidence: .medium),
                                     at: clock(100), generation: 0)
        let plan = policy.plan(at: clock(100), configuration: configuration)
        #expect(plan.mode == .moving && !plan.flushRelevantTransition)
        #expect(policy.evidence(at: clock(121)).state == .unknown)
    }

    @Test("Stationary confirmation requires sixty seconds and a new corroborating context")
    func nativeStationaryHysteresis() {
        let policy = AdaptiveSamplingPolicy()
        policy.observeNativeActivity(NativeActivityObservation(observedAtMs: clock(0).wallTimeMs,
                                                              stationary: true, confidence: .medium),
                                     at: clock(0), generation: 0)
        policy.observeContext(context(59), at: clock(59), generation: 0)
        #expect(policy.evidence(at: clock(59)).state == .stationaryCandidate)
        let evidence = policy.evidence(at: clock(60))
        #expect(evidence.state == .stationaryConfirmed && evidence.confidence == .medium)
        #expect(evidence.reason == "native_stationary_confirmed")
    }

    @Test("Silence and preexisting context do not confirm stationary activity")
    func noStationaryFromSilence() {
        let policy = AdaptiveSamplingPolicy()
        policy.observeContext(context(0), at: clock(0), generation: 0)
        policy.observeNativeActivity(NativeActivityObservation(observedAtMs: clock(0).wallTimeMs,
                                                              stationary: true, confidence: .high),
                                     at: clock(0), generation: 0)
        #expect(policy.evidence(at: clock(60)).state == .stationaryCandidate)
        #expect(policy.evidence(at: clock(121)).state == .unknown)
    }

    @Test("Automotive and stationary flags remain a candidate at a stoplight")
    func automotiveStop() {
        let policy = AdaptiveSamplingPolicy()
        policy.observeNativeActivity(NativeActivityObservation(observedAtMs: clock(0).wallTimeMs,
                                                              automotive: true, stationary: true, confidence: .high),
                                     at: clock(0), generation: 0)
        policy.observeContext(context(60), at: clock(60), generation: 0)
        #expect(policy.evidence(at: clock(60)).state == .stationaryCandidate)
        #expect(policy.evidence(at: clock(60)).reason == "native_stationary_candidate")
    }

    @Test("Revocation removes native confirmation without fabricating a fallback observation")
    func nativeRevocation() {
        let policy = AdaptiveSamplingPolicy()
        policy.observeNativeActivity(NativeActivityObservation(observedAtMs: clock(0).wallTimeMs,
                                                              walking: true, confidence: .high),
                                     at: clock(0), generation: 0)
        policy.invalidateNativeActivity()
        let evidence = policy.evidence(at: clock(1))
        #expect(evidence.state == .unknown && evidence.source == .none)
        #expect(evidence.reason == "permission_unavailable")
        #expect(policy.plan(at: clock(1), configuration: configuration).mode == .conservative)
    }

    @Test("Location displacement must exceed both the threshold and summed uncertainty")
    func gpsUncertainty() {
        let policy = AdaptiveSamplingPolicy()
        policy.observeLocation(fix(0, accuracy: 40), at: clock(0), generation: 0)
        policy.observeLocation(fix(20, longitude: 0.00045, accuracy: 40), at: clock(20), generation: 0)
        #expect(policy.evidence(at: clock(20)).state == .unknown)
        policy.observeLocation(fix(30, longitude: 0.002, accuracy: 40), at: clock(30), generation: 0)
        let evidence = policy.evidence(at: clock(30))
        #expect(evidence.state == .movingInferred && evidence.confidence == .low)
        #expect(evidence.source == .freshLocation && evidence.reason == "location_displacement")
    }

    @Test("Invalid accuracy cached fixes short intervals and slow displacement are rejected")
    func invalidLocationEvidence() {
        for accuracy in [0, -1, 51, Double.nan, Double.infinity] {
            let policy = AdaptiveSamplingPolicy()
            policy.observeLocation(fix(0, accuracy: accuracy), at: clock(0), generation: 0)
            policy.observeLocation(fix(20, longitude: 0.001, accuracy: accuracy), at: clock(20), generation: 0)
            #expect(policy.evidence(at: clock(20)).state == .unknown)
        }
        for (seconds, longitude): (Int64, Double) in [(0, 0.002), (4, 0.002), (60, 0.00027)] {
            let policy = AdaptiveSamplingPolicy()
            policy.observeLocation(fix(0), at: clock(0), generation: 0)
            policy.observeLocation(fix(seconds, longitude: longitude), at: clock(seconds), generation: 0)
            #expect(policy.evidence(at: clock(seconds)).state == .unknown)
        }
    }

    @Test("Stable context is independent of walking and cannot confirm physical stillness")
    func contextVersusMotion() {
        let policy = stablePolicy()
        let unknown = policy.evidence(at: clock(120))
        #expect(unknown.contextStable && unknown.state == .unknown && unknown.reason == "context_stable")
        policy.observeNativeActivity(NativeActivityObservation(observedAtMs: clock(121).wallTimeMs,
                                                              walking: true, confidence: .high),
                                     at: clock(121), generation: 0)
        let walking = policy.evidence(at: clock(121))
        #expect(walking.contextStable && walking.state == .movingConfirmed)
        #expect(policy.plan(at: clock(121), configuration: configuration).mode == .novelty)
    }

    @Test("Context needs three independent windows over one hundred twenty seconds")
    func contextWindowNovelty() {
        let policy = AdaptiveSamplingPolicy()
        policy.observeContext(context(0), at: clock(0), generation: 0)
        policy.observeContext(context(19), at: clock(19), generation: 0)
        policy.observeContext(context(20, id: "0"), at: clock(20), generation: 0)
        var cached = context(60)
        cached.isFresh = false
        policy.observeContext(cached, at: clock(60), generation: 0)
        var coalesced = context(80)
        coalesced.isCoalesced = true
        policy.observeContext(coalesced, at: clock(80), generation: 0)
        policy.observeContext(context(120), at: clock(120), generation: 0)
        #expect(!policy.evidence(at: clock(120)).contextStable)
        policy.observeContext(context(140), at: clock(140), generation: 0)
        #expect(policy.evidence(at: clock(140)).contextStable)
    }

    @Test("Long running context history stays bounded and expired windows cannot replay")
    func boundedContextReplayHistory() {
        let policy = AdaptiveSamplingPolicy()
        for seconds: Int64 in 0 ..< 10_000 {
            policy.observeContext(context(seconds), at: clock(seconds), generation: 0)
        }
        #expect(policy.retainedContextIDCount == 32)
        #expect(policy.latestContextObservedAtMs == clock(9_999).wallTimeMs)
        #expect(policy.evidence(at: clock(9_999)).contextStable)

        let wifiDisabled = DataCollectionPolicy(wifi: false)
        #expect(!policy.evidence(at: clock(10_000), policy: wifiDisabled).contextStable)
        policy.observeContext(context(9_960), at: clock(10_000), generation: 0, policy: wifiDisabled)
        policy.observeContext(context(9_970, id: "unseen_old_timestamp"), at: clock(10_000),
                              generation: 0, policy: wifiDisabled)
        policy.observeContext(context(9_999, id: "older_timestamp"), at: clock(10_000),
                              generation: 0, policy: wifiDisabled)
        #expect(policy.plan(at: clock(10_000), configuration: configuration, policy: wifiDisabled).mode == .conservative)
        #expect(policy.latestContextObservedAtMs == clock(9_999).wallTimeMs)

        policy.observeContext(context(10_001), at: clock(10_001), generation: 0, policy: wifiDisabled)
        #expect(!policy.evidence(at: clock(10_122), policy: wifiDisabled).contextStable)
        #expect(policy.retainedContextIDCount == 32)
        #expect(policy.latestContextObservedAtMs == clock(10_001).wallTimeMs)
        policy.observeContext(context(0), at: clock(10_122), generation: 0, policy: wifiDisabled)
        #expect(policy.plan(at: clock(10_122), configuration: configuration, policy: wifiDisabled).mode == .conservative)
        #expect(!policy.evidence(at: clock(10_122), policy: wifiDisabled).contextStable)
        var coalesced = context(10_123)
        coalesced.isCoalesced = true
        policy.observeContext(coalesced, at: clock(10_123), generation: 0, policy: wifiDisabled)
        #expect(policy.latestContextObservedAtMs == clock(10_001).wallTimeMs)
    }

    @Test("Only stable context plus three distinct unresolved fixes supports inferred stillness")
    func stationaryInference() {
        let policy = stablePolicy(withLocations: true)
        let evidence = policy.evidence(at: clock(120))
        #expect(evidence.state == .stationaryInferred && evidence.contextStable)
        #expect(evidence.source == .contextFusion && evidence.confidence == .low)
        #expect(evidence.reason == "stationary_inferred")
        policy.observeLocation(fix(120), at: clock(125), generation: 0)
        #expect(policy.evidence(at: clock(125)).observedAtMs == clock(120).wallTimeMs)
    }

    @Test("A changed beacon set access point or RSSI median immediately removes stable spacing")
    func contextChanges() {
        for replacement in [context(140, beacon: "new"), context(140, ap: "new"),
                            SamplingContextObservation(windowID: "140", observedAtMs: clock(140).wallTimeMs,
                                                       beaconRSSIs: ["beacon": -70], connectedAP: "ap")] {
            let policy = stablePolicy(withLocations: true)
            policy.observeContext(replacement, at: clock(140), generation: 0)
            let evidence = policy.evidence(at: clock(140))
            #expect(!evidence.contextStable && evidence.state == .unknown)
            let plan = policy.plan(at: clock(140), configuration: configuration)
            #expect(plan.mode == .novelty && plan.flushRelevantTransition)
            #expect(!policy.plan(at: clock(140), configuration: configuration).flushRelevantTransition)
        }
    }

    @Test("An access point or RSSI without a beacon set cannot prove context stability")
    func insufficientContext() {
        let policy = AdaptiveSamplingPolicy()
        for seconds: Int64 in [0, 60, 120] {
            policy.observeContext(SamplingContextObservation(windowID: String(seconds),
                observedAtMs: clock(seconds).wallTimeMs, beaconRSSIs: [:], connectedAP: "ap"),
                at: clock(seconds), generation: 0)
        }
        #expect(!policy.evidence(at: clock(120)).contextStable)
        #expect(policy.evidence(at: clock(120)).state == .unknown)
    }

    @Test("Evidence TTL returns to conservative sampling without inventing an exit")
    func evidenceExpiry() {
        let policy = stablePolicy(withLocations: true)
        #expect(policy.plan(at: clock(120), configuration: configuration).mode == .stable)
        let evidence = policy.evidence(at: clock(181))
        #expect(evidence.state == .unknown && !evidence.contextStable)
        let plan = policy.plan(at: clock(181), configuration: configuration)
        #expect(plan.mode == .conservative && !plan.flushRelevantTransition)
    }

    @Test("Old generations reboot suspension and unreliable clocks invalidate evidence")
    func lifecycleInvalidation() {
        let policy = stablePolicy()
        policy.reset(generation: 1)
        policy.observeContext(context(140), at: clock(140), generation: 0)
        #expect(!policy.evidence(at: clock(140)).contextStable)
        for invalid in [clock(121, boot: "reboot"),
                        SamplingClock(wallTimeMs: clock(240).wallTimeMs, monotonicTimeMs: 121_000, bootIdentifier: "boot"),
                        SamplingClock(wallTimeMs: clock(121).wallTimeMs, monotonicTimeMs: 121_000, bootIdentifier: "boot", isReliable: false)] {
            let current = stablePolicy(withLocations: true)
            let evidence = current.evidence(at: invalid)
            #expect(evidence.state == .unknown && !evidence.contextStable)
            #expect(evidence.reason == "clock_uncertain")
        }
    }

    @Test("Disabled inputs lose their contribution and enabling them requires new evidence")
    func collectionSwitches() {
        let policy = stablePolicy(withLocations: true)
        let disabled = DataCollectionPolicy(location: false, wifi: false)
        #expect(policy.evidence(at: clock(120), policy: disabled).state == .unknown)
        #expect(!policy.evidence(at: clock(120), policy: disabled).contextStable)
        policy.observeLocation(fix(121, longitude: 0.002), at: clock(121), generation: 0, policy: disabled)
        policy.observeContext(context(140, ap: "ignored"), at: clock(140), generation: 0, policy: disabled)
        #expect(policy.evidence(at: clock(141), policy: .allEnabled).state == .unknown)
        #expect(!policy.evidence(at: clock(141), policy: .allEnabled).contextStable)
        let moving = AdaptiveSamplingPolicy()
        moving.observeLocation(fix(0), at: clock(0), generation: 0)
        moving.observeLocation(fix(20, longitude: 0.001), at: clock(20), generation: 0)
        #expect(moving.plan(at: clock(20), configuration: configuration).mode == .novelty)
        #expect(moving.plan(at: clock(21), configuration: configuration, policy: disabled).mode == .conservative)
    }

    @Test("Capability caps summary and live cadence while rollback preserves legacy scheduling")
    func samplingCadences() {
        let policy = stablePolicy()
        let stable = policy.plan(at: clock(120), configuration: configuration)
        #expect(stable.contextIntervalMs == 300_000 && stable.summaryIntervalMs == 300_000)
        var limited = configuration
        limited.capability = SamplingCapability(sessionTimeoutMs: 180_000, advertisedServicesCadenceMs: 8_000, mapTTLms: 15_000)
        let capped = policy.plan(at: clock(120), configuration: limited)
        #expect(capped.summaryIntervalMs == 60_000 && capped.liveIntervalMs == 5_000)
        var fast = SamplingConfiguration(legacySyncIntervalMs: 5_000, capability: configuration.capability)
        #expect(policy.plan(at: clock(120), configuration: fast).liveIntervalMs == 5_000)
        fast.adaptiveSamplingEnabled = false
        #expect(policy.plan(at: clock(120), configuration: fast).mode == .legacy)
        limited.capability = SamplingCapability(sessionTimeoutMs: 30_000, advertisedServicesCadenceMs: 60_000, mapTTLms: 180_000)
        #expect(policy.plan(at: clock(120), configuration: limited).mode == .legacy)
        let fresh = AdaptiveSamplingPolicy()
        fresh.observeContext(context(0), at: clock(0), generation: 0)
        let novelty = fresh.plan(at: clock(0), configuration: configuration)
        #expect(novelty.contextIntervalMs == 30_000 && novelty.summaryIntervalMs == 15_000)
        #expect(fresh.plan(at: clock(90), configuration: configuration).mode == .conservative)
    }

    @Test("Fresh physical zones cap live cadence while preserving stable context and summary budgets",
          arguments: [Int64(5_000), 15_000, 60_000])
    func freshPhysicalZoneCadences(baseline: Int64) {
        let policy = stablePolicy()
        let configuration = SamplingConfiguration(legacySyncIntervalMs: baseline, capability: self.configuration.capability)
        let original = policy.plan(at: clock(120), configuration: configuration)
        let eligible = policy.plan(at: clock(120), configuration: configuration, hasFreshPhysicalZone: true)
        #expect(original.liveIntervalMs == baseline)
        #expect(eligible.liveIntervalMs == min(baseline, 30_000))
        #expect(eligible.mode == original.mode && eligible.contextIntervalMs == 300_000)
        #expect(eligible.summaryIntervalMs == 300_000 && eligible.flushRelevantTransition == original.flushRelevantTransition)
    }

    @Test("Fresh physical zones preserve faster Services and map TTL contracts")
    func freshPhysicalZoneFasterContracts() {
        for capability in [
            SamplingCapability(sessionTimeoutMs: 900_000, advertisedServicesCadenceMs: 5_000, mapTTLms: 180_000),
            SamplingCapability(sessionTimeoutMs: 900_000, advertisedServicesCadenceMs: 60_000, mapTTLms: 15_000)
        ] {
            let policy = stablePolicy()
            let configuration = SamplingConfiguration(legacySyncIntervalMs: 60_000, capability: capability)
            let plan = policy.plan(at: clock(120), configuration: configuration, hasFreshPhysicalZone: true)
            #expect(plan.liveIntervalMs == 5_000 && plan.summaryIntervalMs == 300_000)
            #expect(plan.contextIntervalMs == 300_000)
        }
    }

    @Test("Fresh physical evidence cannot enable a missing disabled or incompatible capability")
    func freshPhysicalZoneFallback() {
        var disabled = SamplingConfiguration(legacySyncIntervalMs: 60_000, capability: configuration.capability)
        disabled.adaptiveSamplingEnabled = false
        let invalid = SamplingConfiguration(legacySyncIntervalMs: 60_000, capability: SamplingCapability(
            sessionTimeoutMs: 30_000, advertisedServicesCadenceMs: 60_000, mapTTLms: 180_000))
        for configuration in [SamplingConfiguration(legacySyncIntervalMs: 60_000), disabled, invalid] {
            let plan = AdaptiveSamplingPolicy().plan(at: clock(0), configuration: configuration, hasFreshPhysicalZone: true)
            #expect(plan.mode == .legacy && plan.liveIntervalMs == 60_000)
            #expect(plan.contextIntervalMs == nil && plan.summaryIntervalMs == 60_000)
        }
    }

    @Test("Ineligible physical collection preserves the established live cadence and complementary budgets",
          arguments: [Int64(5_000), 15_000, 60_000])
    func freshPhysicalZoneIneligibleCadences(baseline: Int64) {
        let policy = stablePolicy()
        let configuration = SamplingConfiguration(legacySyncIntervalMs: baseline, capability: self.configuration.capability)
        let plan = policy.plan(at: clock(120), configuration: configuration, hasFreshPhysicalZone: false)
        #expect(plan.liveIntervalMs == baseline)
        #expect(plan.contextIntervalMs == 300_000 && plan.summaryIntervalMs == 300_000)
        #expect(plan.mode == .stable && !plan.flushRelevantTransition)
    }
    private func inertial(_ end: Int64, generation: UInt64 = 0,
                          classification: InertialWindow.Classification = .active) -> InertialWindow {
        InertialWindow(generation: generation, startedAtMonotonicMs: end * 1_000 - 3_000,
            endedAtMonotonicMs: end * 1_000, sampleCount: 60,
            dynamicRmsG: classification == .active ? 0.1 : 0,
            excursionRatio: classification == .active ? 0.5 : 0, classification: classification)
    }

    @Test("Two independent active windows infer motion with original age despite a co moving beacon and imprecise GPS")
    func inertialFusionAndTTL() {
        let policy = stablePolicy()
        policy.observeLocation(fix(120, longitude: 0.01, accuracy: 100), at: clock(120), generation: 0)
        policy.observeInertial(inertial(123), at: clock(123))
        #expect(policy.evidence(at: clock(123)).state == .unknown)
        policy.observeInertial(inertial(153), at: clock(154))
        let evidence = policy.evidence(at: clock(154))
        #expect(evidence.isInertialInference && evidence.observedAtMs == clock(153).wallTimeMs && evidence.ageMs == 1_000)
        policy.observeInertial(inertial(153), at: clock(158))
        #expect(policy.evidence(at: clock(213)).isInertialInference)
        #expect(policy.evidence(at: clock(214)).state == .unknown)
        policy.observeInertial(inertial(153), at: clock(214))
        #expect(policy.evidence(at: clock(214)).state == .unknown)
    }

    @Test("Sustained inertial motion precedes stable spacing without rejuvenating novelty or changing live cadence")
    func inertialSchedulingPriority() {
        let policy = stablePolicy()
        for seconds: Int64 in [123, 153, 183, 213, 243, 273] {
            policy.observeContext(context(seconds), at: clock(seconds), generation: 0)
            policy.observeInertial(inertial(seconds), at: clock(seconds))
            let plan = policy.plan(at: clock(seconds), configuration: configuration)
            #expect(plan.liveIntervalMs == 15_000)
            if seconds >= 243 {
                #expect(policy.evidence(at: clock(seconds)).contextStable)
                #expect(plan.mode == .moving && plan.contextIntervalMs == 60_000 && plan.summaryIntervalMs == 60_000)
            }
        }
        policy.observeNativeActivity(NativeActivityObservation(observedAtMs: clock(274).wallTimeMs,
            walking: true, confidence: .high), at: clock(274), generation: 0)
        #expect(policy.evidence(at: clock(274)).state == .movingConfirmed)
        #expect(policy.plan(at: clock(274), configuration: configuration).mode == .moving)
    }

    @Test("Quiet ambiguous absent isolated and replayed windows never confirm stationary or manufacture movement")
    func quietAndInvalidInertial() {
        for kind in [InertialWindow.Classification.quiet, .ambiguous] {
            let policy = stablePolicy()
            policy.observeInertial(inertial(123, classification: kind), at: clock(123))
            policy.observeInertial(inertial(153, classification: kind), at: clock(153))
            #expect(policy.evidence(at: clock(153)).state == .unknown)
        }
        let policy = AdaptiveSamplingPolicy()
        policy.observeInertial(inertial(3), at: clock(3))
        policy.observeInertial(inertial(3), at: clock(3))
        policy.observeInertial(inertial(10), at: clock(10))
        #expect(policy.evidence(at: clock(10)).state == .unknown)
        policy.observeInertial(inertial(40, generation: 99), at: clock(40))
        #expect(policy.evidence(at: clock(40)).state == .unknown)
        policy.reset(generation: 1)
        policy.observeInertial(inertial(70), at: clock(70))
        #expect(policy.evidence(at: clock(70)).state == .unknown)
    }

    @Test("One active window contradicts stale native STILL and two cannot override native movement")
    func nativeInertialConflict() {
        let policy = AdaptiveSamplingPolicy()
        policy.observeNativeActivity(NativeActivityObservation(observedAtMs: clock(0).wallTimeMs,
            stationary: true, confidence: .high), at: clock(0), generation: 0)
        policy.observeContext(context(61), at: clock(61), generation: 0)
        policy.observeInertial(inertial(63), at: clock(63))
        #expect(policy.evidence(at: clock(63)).state == .stationaryCandidate)
        policy.observeInertial(inertial(93), at: clock(93))
        #expect(policy.evidence(at: clock(93)).isInertialInference)
        policy.observeNativeActivity(NativeActivityObservation(observedAtMs: clock(94).wallTimeMs,
            walking: true, confidence: .high), at: clock(94), generation: 0)
        #expect(policy.evidence(at: clock(94)).state == .movingConfirmed)
    }

    @Test("Motion opt out removes only sensor contributions and needs new sensor evidence when reenabled")
    func motionPolicyIsolation() {
        let policy = AdaptiveSamplingPolicy()
        policy.observeInertial(inertial(3), at: clock(3))
        policy.observeInertial(inertial(33), at: clock(33))
        #expect(policy.evidence(at: clock(33)).isInertialInference)
        let onlyMotion = DataCollectionPolicy(location: false, wifi: false, motionSensors: true)
        #expect(policy.evidence(at: clock(33), policy: onlyMotion).isInertialInference)
        let disabled = DataCollectionPolicy(motionSensors: false)
        #expect(policy.evidence(at: clock(34), policy: disabled).state == .unknown)
        policy.observeNativeActivity(NativeActivityObservation(observedAtMs: clock(35).wallTimeMs, walking: true),
            at: clock(35), generation: 0, policy: disabled)
        policy.observeLocation(fix(35), at: clock(35), generation: 0, policy: disabled)
        policy.observeLocation(fix(55, longitude: 0.001), at: clock(55), generation: 0, policy: disabled)
        #expect(policy.evidence(at: clock(55), policy: disabled).source == .freshLocation)
        let context = stablePolicy(withLocations: true)
        #expect(context.evidence(at: clock(120), policy: disabled).state == .stationaryInferred)
    }

    @Test("Original inertial epoch is anchored at burst start and never retimestamped by completion wall jitter")
    func inertialSourceClock() {
        let policy = AdaptiveSamplingPolicy()
        policy.observeInertial(inertial(3), at: clock(3))
        var next = inertial(33)
        next.sourceClock = clock(30)
        let received = SamplingClock(wallTimeMs: clock(33).wallTimeMs + 2_000,
            monotonicTimeMs: clock(33).monotonicTimeMs, bootIdentifier: "boot")
        policy.observeInertial(next, at: received)
        #expect(policy.evidence(at: received).observedAtMs == clock(33).wallTimeMs)
        #expect(policy.evidence(at: received).ageMs == 0)
    }

    @Test("Canceling sensor attention preserves independent BLE and GPS novelty")
    func inertialNoveltyRevocation() {
        let policy = AdaptiveSamplingPolicy()
        policy.observeInertial(inertial(3), at: clock(3))
        policy.observeInertial(inertial(33), at: clock(33))
        #expect(policy.plan(at: clock(33), configuration: configuration).mode == .novelty)
        let denied = DataCollectionPolicy(motionSensors: false)
        #expect(policy.plan(at: clock(34), configuration: configuration, policy: denied).mode == .conservative)
        policy.observeContext(context(35), at: clock(35), generation: 0, policy: denied)
        policy.invalidateInertial()
        #expect(policy.plan(at: clock(35), configuration: configuration, policy: denied).mode == .novelty)
        let gps = AdaptiveSamplingPolicy()
        gps.observeLocation(fix(0), at: clock(0), generation: 0)
        gps.observeLocation(fix(20, longitude: 0.001), at: clock(20), generation: 0)
        gps.invalidateInertial()
        #expect(gps.plan(at: clock(21), configuration: configuration, policy: denied).mode == .novelty)
    }

    @Test("Inertial corroboration end spacing accepts ten through sixty seconds and rejects the adjacent bounds")
    func corroborationSpacingBoundaries() {
        for span: Int64 in [9, 10, 60, 61] {
            let policy = AdaptiveSamplingPolicy()
            policy.observeInertial(inertial(3), at: clock(3))
            policy.observeInertial(inertial(3 + span), at: clock(3 + span))
            #expect(policy.evidence(at: clock(3 + span)).isInertialInference == (10 ... 60).contains(span))
        }
    }

}
