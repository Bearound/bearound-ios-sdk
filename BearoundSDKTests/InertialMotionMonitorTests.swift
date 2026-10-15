import Foundation
import Testing
@testable import BearoundSDK

@Suite("Inertial Motion Monitor Tests")
struct InertialMotionMonitorTests {
    private final class Provider: InertialMotionProviding {
        var available = true
        var availabilityReads = 0
        var isAvailable: Bool { availabilityReads += 1; return available }
        var starts = 0
        var stops = 0
        var interval: TimeInterval?
        var callbacks: [(InertialSample?) -> Void] = []
        func start(interval: TimeInterval, queue: OperationQueue, handler: @escaping (InertialSample?) -> Void) {
            self.interval = interval; starts += 1; callbacks.append(handler)
        }
        func stop() { stops += 1 }
    }
    private final class Harness {
        let provider = Provider()
        var now = SamplingClock(wallTimeMs: 1_000_000, monotonicTimeMs: 100_000, bootIdentifier: "boot")
        var allowed = true
        var factories = 0
        var closures: [() -> Void] = []
        var delays: [TimeInterval] = []
        var windows: [InertialWindow] = []
        var clocks: [SamplingClock] = []
        lazy var monitor = InertialMotionMonitor(providerFactory: { self.factories += 1; return self.provider },
            clock: { self.now }, schedule: { delay, work in
                self.delays.append(delay); self.closures.append(work); return {}
            })
        func move(_ delta: Int64) {
            now = SamplingClock(wallTimeMs: 1_000_000 + delta, monotonicTimeMs: 100_000 + delta, bootIdentifier: "boot")
        }
        @discardableResult func start(_ generation: UInt64 = 1) -> Bool {
            monitor.requestBurst(generation: generation, eligible: { self.allowed }) { window, clock in
                self.windows.append(window); self.clocks.append(clock)
            }
        }
        func emit(_ start: Int64 = 0, callback: Int = 0) {
            for delta in stride(from: 0, through: 2_950, by: 50) {
                move(start + Int64(delta))
                provider.callbacks[callback](InertialSample(monotonicAtMs: now.monotonicTimeMs,
                    xG: 0, yG: 0, zG: delta.isMultiple(of: 100) ? 1.1 : 0.9))
            }
        }
    }

    @Test("Disabled adaptive policy stopped SDK and inactive foreground never construct or access the raw provider")
    func noAccessWhenIneligible() {
        for _ in 0 ..< 4 {
            let h = Harness(); h.allowed = false
            #expect(!h.start())
            #expect(h.factories == 0 && h.provider.availabilityReads == 0 && h.closures.isEmpty)
        }
    }

    @Test("Raw bursts request twenty hertz close at three seconds and preserve original source times")
    func originalSourceTimeAndBudget() throws {
        let h = Harness()
        #expect(h.start())
        #expect(h.provider.interval == 0.05 && h.delays == [3])
        h.emit(); h.move(3_000); h.closures[0]()
        let window = try #require(h.windows.first)
        #expect(window.startedAtMonotonicMs == 100_000 && window.endedAtMonotonicMs == 102_950)
        #expect(window.sampleCount == 60 && window.classification == .active && h.provider.stops == 1)
        h.move(29_999); #expect(!h.start(2))
        h.move(30_000); #expect(h.start(2))
        h.monitor.stop()
        h.move(30_001); #expect(!h.start(3))
    }

    @Test("Background cancellation stop and generation changes discard samples and reject stale callbacks")
    func cancellationAndRestart() {
        let h = Harness(); h.start(); h.emit()
        h.allowed = false; h.monitor.stop(); h.move(3_000); h.closures[0]()
        #expect(h.windows.isEmpty && h.provider.stops == 1)
        h.allowed = true; h.move(30_000); #expect(h.start(2))
        h.provider.callbacks[0](InertialSample(monotonicAtMs: 130_000, xG: 0, yG: 0, zG: 1))
        h.emit(30_000, callback: 1); h.move(33_000); h.closures[1]()
        #expect(h.windows.count == 1 && h.windows[0].generation == 2)
    }

    @Test("Unavailable errors future samples gaps and close overrun never produce evidence")
    func invalidSources() {
        let unavailable = Harness(); unavailable.provider.available = false
        #expect(!unavailable.start() && unavailable.provider.starts == 0)
        for failure in 0 ..< 5 {
            let h = Harness(); h.start(); h.emit()
            switch failure {
            case 0: h.provider.callbacks[0](nil)
            case 1: h.provider.callbacks[0](InertialSample(monotonicAtMs: 103_001, xG: 0, yG: 0, zG: 1))
            case 2: h.move(4_000)
            case 3: h.allowed = false
            default: h.now = SamplingClock(wallTimeMs: 1_003_000, monotonicTimeMs: 103_000, bootIdentifier: "other")
            }
            if failure < 2 { h.move(3_000) }
            h.closures[0]()
            #expect(h.windows.isEmpty && h.provider.stops == 1)
        }
    }

    @Test("The sample cap stops a dense provider without creating an oversized or incomplete observation")
    func boundedProvider() {
        let h = Harness(); h.start()
        for delta in 0 ..< 140 {
            h.move(Int64(delta))
            h.provider.callbacks[0](InertialSample(monotonicAtMs: 100_000 + Int64(delta), xG: 0, yG: 0, zG: 1))
        }
        #expect(h.provider.stops == 1 && h.windows.isEmpty)
    }
    @Test("Scheduler lateness permits exactly two hundred fifty milliseconds and rejects the next millisecond")
    func closeDeadlineBoundary() {
        for delay: Int64 in [3_250, 3_251, 4_000] {
            let h = Harness(); h.start(); h.emit(); h.move(delay); h.closures[0]()
            #expect(h.windows.count == (delay == 3_250 ? 1 : 0))
            #expect(h.provider.stops == 1)
            #expect(h.windows.first?.endedAtMonotonicMs ?? 102_950 <= 103_000)
        }
    }

}
