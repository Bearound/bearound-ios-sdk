import CoreMotion
import Foundation

protocol MotionActivityProviding: AnyObject {
    var isActivityAvailable: Bool { get }
    var authorizationStatus: CMAuthorizationStatus { get }
    func startUpdates(on queue: OperationQueue, handler: @escaping (NativeActivityObservation?) -> Void)
    func stopUpdates()
}

final class CoreMotionActivityProvider: MotionActivityProviding {
    private let manager = CMMotionActivityManager()
    var isActivityAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }
    var authorizationStatus: CMAuthorizationStatus { CMMotionActivityManager.authorizationStatus() }

    func startUpdates(on queue: OperationQueue, handler: @escaping (NativeActivityObservation?) -> Void) {
        manager.startActivityUpdates(to: queue) { activity in
            guard let activity else { handler(nil); return }
            let confidence: MotionConfidence
            switch activity.confidence {
            case .low: confidence = .low
            case .medium: confidence = .medium
            case .high: confidence = .high
            @unknown default: confidence = .none
            }
            handler(NativeActivityObservation(
                observedAtMs: Int64(activity.startDate.timeIntervalSince1970 * 1_000),
                walking: activity.walking, running: activity.running, cycling: activity.cycling,
                automotive: activity.automotive, stationary: activity.stationary, confidence: confidence
            ))
        }
    }

    func stopUpdates() { manager.stopActivityUpdates() }
}

final class MotionMonitor {
    typealias Handler = (NativeActivityObservation?, SamplingClock, UInt64) -> Void

    private let provider: MotionActivityProviding
    private let usageDescription: () -> String?
    private let clock: () -> SamplingClock
    private let queue: OperationQueue
    private let lock = NSRecursiveLock()
    private var token: UInt64 = 0
    private var active = false
    private var startedAt: SamplingClock?

    init(
        provider: MotionActivityProviding = CoreMotionActivityProvider(),
        usageDescription: @escaping () -> String? = {
            Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription") as? String
        },
        clock: @escaping () -> SamplingClock = SamplingClock.now,
        queue: OperationQueue = .main
    ) {
        self.provider = provider
        self.usageDescription = usageDescription
        self.clock = clock
        self.queue = queue
    }

    deinit { stop() }

    @discardableResult
    func start(generation: UInt64, handler: @escaping Handler) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
        guard provider.isActivityAvailable,
              let description = usageDescription(), !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              provider.authorizationStatus == .authorized else {
            handler(nil, clock(), generation)
            return false
        }
        let start = clock()
        guard start.isReliable else { handler(nil, start, generation); return false }
        startedAt = start
        active = true
        let callbackToken = token
        provider.startUpdates(on: queue) { [weak self] activity in
            self?.receive(activity, token: callbackToken, generation: generation, handler: handler)
        }
        return true
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        token &+= 1
        if active { provider.stopUpdates() }
        active = false
        startedAt = nil
    }

    private func receive(
        _ activity: NativeActivityObservation?, token callbackToken: UInt64,
        generation: UInt64, handler: Handler
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard active, callbackToken == token else { return }
        let now = clock()
        guard provider.isActivityAvailable, provider.authorizationStatus == .authorized,
              let description = usageDescription(), !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let startedAt, now.isReliable, now.bootIdentifier == startedAt.bootIdentifier,
              now.monotonicTimeMs >= startedAt.monotonicTimeMs,
              abs((now.wallTimeMs - startedAt.wallTimeMs) - (now.monotonicTimeMs - startedAt.monotonicTimeMs)) <= 5_000 else {
            stopLocked()
            handler(nil, now, generation)
            return
        }
        guard let activity, let original = activity.observedAtMs,
              original <= now.wallTimeMs, now.wallTimeMs - original <= 120_000 else {
            handler(nil, now, generation)
            return
        }
        handler(activity, now, generation)
    }
}
