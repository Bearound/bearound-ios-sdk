import CoreMotion
import Foundation

protocol InertialMotionProviding: AnyObject {
    var isAvailable: Bool { get }
    func start(interval: TimeInterval, queue: OperationQueue, handler: @escaping (InertialSample?) -> Void)
    func stop()
}

final class CoreMotionInertialProvider: InertialMotionProviding {
    private let manager = CMMotionManager()
    var isAvailable: Bool { manager.isAccelerometerAvailable }
    func start(interval: TimeInterval, queue: OperationQueue, handler: @escaping (InertialSample?) -> Void) {
        let sourceUptimeMs = ProcessInfo.processInfo.systemUptime * 1_000
        let continuousMs = SamplingClock.continuousSeconds() * 1_000
        manager.accelerometerUpdateInterval = interval
        manager.startAccelerometerUpdates(to: queue) { data, error in
            guard error == nil, let data, data.timestamp.isFinite,
                  data.timestamp >= 0, data.timestamp * 1_000 < Double(Int64.max) else { handler(nil); return }
            handler(InertialSample(monotonicAtMs: Self.continuousTimestamp(sourceSeconds: data.timestamp, sourceUptimeMs: sourceUptimeMs, continuousMs: continuousMs),
                xG: data.acceleration.x, yG: data.acceleration.y, zG: data.acceleration.z))
        }
    }
    static func continuousTimestamp(sourceSeconds: TimeInterval, sourceUptimeMs: Double, continuousMs: Double) -> Int64 {
        Int64(continuousMs + (sourceSeconds * 1_000 - sourceUptimeMs))
    }
    func stop() { manager.stopAccelerometerUpdates() }
}

final class InertialMotionMonitor {
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> (() -> Void)
    private let factory: () -> InertialMotionProviding
    private let clock: () -> SamplingClock
    private let schedule: Scheduler
    private let queue: OperationQueue
    private let lock = NSRecursiveLock()
    private var provider: InertialMotionProviding?
    private var cancellation: (() -> Void)?
    private var token: UInt64 = 0
    private var anchor: SamplingClock?
    private var lastStart: SamplingClock?
    private var samples: [InertialSample] = []

    init(providerFactory: @escaping () -> InertialMotionProviding = { CoreMotionInertialProvider() },
         clock: @escaping () -> SamplingClock = SamplingClock.now,
         schedule: @escaping Scheduler = { delay, work in
             let item = DispatchWorkItem(block: work)
             DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: item)
             return { item.cancel() }
         }) {
        factory = providerFactory
        self.clock = clock
        self.schedule = schedule
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
    }

    deinit { stop() }

    @discardableResult
    func requestBurst(generation: UInt64, eligible: @escaping () -> Bool,
                      handler: @escaping (InertialWindow, SamplingClock) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard eligible() else { stopLocked(); return false }
        let now = clock()
        guard anchor == nil, now.isReliable, now.monotonicTimeMs >= 0 else { return false }
        if let lastStart {
            guard now.bootIdentifier == lastStart.bootIdentifier,
                  now.monotonicTimeMs >= lastStart.monotonicTimeMs,
                  now.monotonicTimeMs - lastStart.monotonicTimeMs >= 30_000 else { return false }
        }
        let source = provider ?? factory()
        provider = source
        guard source.isAvailable else { return false }
        lastStart = now
        anchor = now
        samples.removeAll(keepingCapacity: true)
        token &+= 1
        let burst = token
        cancellation = schedule(3) { [weak self] in
            self?.finish(token: burst, generation: generation, eligible: eligible, handler: handler)
        }
        source.start(interval: 0.05, queue: queue) { [weak self] sample in
            self?.receive(sample, token: burst, generation: generation, eligible: eligible, handler: handler)
        }
        return true
    }

    func stop() { lock.lock(); defer { lock.unlock() }; stopLocked() }

    private func stopLocked() {
        token &+= 1
        cancellation?()
        cancellation = nil
        if anchor != nil { provider?.stop() }
        anchor = nil
        samples.removeAll(keepingCapacity: true)
    }

    private func valid(_ now: SamplingClock, anchor: SamplingClock) -> Bool {
        now.isReliable && now.bootIdentifier == anchor.bootIdentifier
            && now.monotonicTimeMs >= anchor.monotonicTimeMs
            && abs((now.wallTimeMs - anchor.wallTimeMs) - (now.monotonicTimeMs - anchor.monotonicTimeMs)) <= 5_000
    }

    private func receive(_ sample: InertialSample?, token burst: UInt64, generation: UInt64,
                         eligible: @escaping () -> Bool, handler: @escaping (InertialWindow, SamplingClock) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard token == burst, let anchor else { return }
        let now = clock()
        guard eligible(), valid(now, anchor: anchor), let sample,
              sample.xG.isFinite, sample.yG.isFinite, sample.zG.isFinite,
              sample.monotonicAtMs >= anchor.monotonicTimeMs,
              sample.monotonicAtMs <= now.monotonicTimeMs,
              sample.monotonicAtMs <= anchor.monotonicTimeMs + 3_000,
              samples.last.map({ sample.monotonicAtMs > $0.monotonicAtMs
                  && sample.monotonicAtMs - $0.monotonicAtMs <= 250 }) ?? true else { stopLocked(); return }
        guard now.monotonicTimeMs - anchor.monotonicTimeMs <= 3_250 else { stopLocked(); return }
        samples.append(sample)
        if samples.count == 128 {
            finish(token: burst, generation: generation, eligible: eligible, handler: handler)
        }
    }

    private func finish(token burst: UInt64, generation: UInt64, eligible: () -> Bool,
                        handler: (InertialWindow, SamplingClock) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard token == burst, let anchor else { return }
        let now = clock()
        let captured = samples
        let allowed = eligible() && valid(now, anchor: anchor)
            && now.monotonicTimeMs - anchor.monotonicTimeMs <= 3_250
        stopLocked()
        guard allowed, var window = InertialMotionClassifier.classify(captured, generation: generation,
            openedAtMs: anchor.monotonicTimeMs, closedAtMs: min(now.monotonicTimeMs, anchor.monotonicTimeMs + 3_000),
            completedAtMs: now.monotonicTimeMs) else { return }
        window.sourceClock = anchor
        handler(window, now)
    }
}
