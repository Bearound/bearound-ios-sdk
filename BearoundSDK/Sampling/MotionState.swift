import Foundation

enum MotionState: String, Codable, Equatable {
    case unknown
    case movingInferred = "moving_inferred"
    case movingConfirmed = "moving_confirmed"
    case stationaryCandidate = "stationary_candidate"
    case stationaryInferred = "stationary_inferred"
    case stationaryConfirmed = "stationary_confirmed"
}

enum MotionConfidence: String, Codable, Equatable {
    case none, low, medium, high
}

enum MotionSource: String, Codable, Equatable {
    case nativeActivity = "native_activity"
    case freshLocation = "fresh_location"
    case contextFusion = "context_fusion"
    case none
}

struct MotionEvidence: Codable, Equatable {
    let state: MotionState
    let source: MotionSource
    let confidence: MotionConfidence
    let reason: String
    let observedAtMs: Int64?
    let ageMs: Int64?
    let contextStable: Bool

    var isInertialInference: Bool {
        state == .movingInferred && source == .contextFusion && confidence == .low && reason == "context_changed"
    }

    func filtered(policy: DataCollectionPolicy) -> MotionEvidence {
        let denied = (!policy.motionSensors && (source == .nativeActivity || isInertialInference))
            || (!isInertialInference && ((!policy.location && [.freshLocation, .contextFusion].contains(source))
                || (!policy.wifi && source == .contextFusion)))
        return denied ? MotionEvidence(state: .unknown, source: .none, confidence: .none,
            reason: "source_disabled", observedAtMs: nil, ageMs: nil, contextStable: false) : self
    }
}

struct SamplingClock: Equatable {
    let wallTimeMs: Int64
    let monotonicTimeMs: Int64
    let bootIdentifier: String
    var isReliable = true

    private static let processIdentifier = UUID().uuidString

    static func now() -> SamplingClock {
        SamplingClock(
            wallTimeMs: Int64(Date().timeIntervalSince1970 * 1_000),
            monotonicTimeMs: Int64(continuousSeconds() * 1_000),
            bootIdentifier: processIdentifier
        )
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Seconds since boot, including time spent asleep (`mach_continuous_time`).
    static func continuousSeconds() -> TimeInterval {
        let ticks = mach_continuous_time()
        let nanoseconds = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
        return nanoseconds / 1_000_000_000
    }
}

struct NativeActivityObservation: Equatable {
    let observedAtMs: Int64?
    var walking = false
    var running = false
    var cycling = false
    var automotive = false
    var stationary = false
    var confidence: MotionConfidence = .none

    var moving: Bool { walking || running || cycling || automotive }
}

struct SamplingLocationObservation: Equatable {
    let observedAtMs: Int64
    let provider: String
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double
}

struct SamplingContextObservation: Equatable {
    let windowID: String
    let observedAtMs: Int64
    let beaconRSSIs: [String: Int]
    var connectedAP: String? = nil
    var isFresh = true
    var isCoalesced = false
}

struct SamplingCapability: Equatable {
    let sessionTimeoutMs: Int64
    let advertisedServicesCadenceMs: Int64
    let mapTTLms: Int64
}

struct SamplingConfiguration {
    let legacySyncIntervalMs: Int64
    var adaptiveSamplingEnabled = true
    var capability: SamplingCapability? = nil
}

struct SamplingPlan: Equatable {
    enum Mode: String { case legacy, conservative, moving, novelty, stable }
    let mode: Mode
    let contextIntervalMs: Int64?
    let summaryIntervalMs: Int64
    let liveIntervalMs: Int64
    let flushRelevantTransition: Bool
}
