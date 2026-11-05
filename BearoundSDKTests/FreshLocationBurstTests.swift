import Foundation
import Testing
@testable import BearoundSDK

private final class BurstHarness {
    final class Timer {
        let due: TimeInterval
        let action: () -> Void
        var cancelled = false
        init(due: TimeInterval, action: @escaping () -> Void) { self.due = due; self.action = action }
    }
    var elapsed: TimeInterval = 0
    var wallOffset: TimeInterval = 0
    var eligible = true
    var contextGeneration = 0
    var persistSucceeds = true
    var deferPersistence = false
    var pendingPersistence: ((Bool) -> Void)?
    var timers: [Timer] = []
    var requests: [(DeviceLocation?) -> Void] = []
    var requestCancellations = 0
    var queued: [DeviceLocation] = []
    let epoch: TimeInterval = 1_790_000_000
    lazy var burst = FreshLocationBurst<Int>(
        elapsed: { self.elapsed }, wallTime: { self.epoch + self.elapsed + self.wallOffset },
        eligible: { self.eligible }, captureContext: { self.contextGeneration }, contextIsCurrent: { $0 == self.contextGeneration },
        schedule: { delay, action in
            let timer = Timer(due: self.elapsed + delay, action: action)
            self.timers.append(timer)
            return { timer.cancelled = true }
        }, request: { completion in
            self.requests.append(completion)
            return { self.requestCancellations += 1 }
        }, enqueue: { fix, _, done in
            guard self.persistSucceeds else { done(false); return }
            self.queued.append(fix)
            if self.deferPersistence { self.pendingPersistence = done }
            else { done(true) }
        })
    func fix(offset: TimeInterval = 0, accuracy: Double? = 10) -> DeviceLocation {
        DeviceLocation(latitude: -23.46, longitude: -46.87, accuracy: accuracy,
            timestamp: Date(timeIntervalSince1970: epoch + elapsed + wallOffset + offset), source: "gnss")
    }
    func respond(_ fix: DeviceLocation?) { requests.last?(fix) }
    func advance(_ seconds: TimeInterval) {
        let target = elapsed + seconds
        while let timer = timers.filter({ !$0.cancelled && $0.due <= target }).min(by: { $0.due < $1.due }) {
            timer.cancelled = true
            elapsed = timer.due
            timer.action()
        }
        elapsed = target
    }
}

@Suite("Bounded foreground fresh locations")
struct FreshLocationBurstTests {
    @Test("Three original accurate fixes are retained independently over seventy seconds")
    func preservesThreeIndependentFixes() {
        let h = BurstHarness()
        h.burst.start()
        h.respond(h.fix())
        h.advance(35)
        h.respond(h.fix())
        h.advance(35)
        h.respond(h.fix())
        #expect(h.queued.map(\.timestamp) == [0, 35_000, 70_000].map { Int(h.epoch * 1000) + $0 })
        #expect(h.requests.count == 3)
        #expect(h.requestCancellations == 3)
        #expect(h.timers.allSatisfy { $0.cancelled })
        h.burst.start()
        h.advance(829)
        #expect(h.requests.count == 3)
        h.advance(1)
        h.burst.start()
        #expect(h.requests.count == 4)
    }

    @Test("Cached, future, inaccurate and absent fixes cannot produce an observation")
    func invalidFixesFailClosed() {
        for kind in 0..<5 {
            let h = BurstHarness()
            h.burst.start()
            let bad: DeviceLocation? = switch kind {
            case 0: h.fix(offset: -1)
            case 1: h.fix(offset: 1)
            case 2: h.fix(accuracy: 51)
            case 3: h.fix(accuracy: nil)
            default: nil
            }
            h.respond(bad)
            h.advance(200)
            #expect(h.queued.isEmpty)
            #expect(h.requests.count == 1)
            #expect(h.timers.allSatisfy { $0.cancelled })
        }
    }

    @Test("Repeated cached timestamps never count as an independent second fix")
    func rejectsRepeatedFix() {
        let h = BurstHarness()
        h.burst.start()
        let first = h.fix()
        h.respond(first)
        h.advance(35)
        h.respond(first)
        #expect(h.queued == [first])
        h.advance(300)
        #expect(h.requests.count == 2)
    }

    @Test("Stop immediately cancels the request and all timers, ignoring late callbacks")
    func cancellationAndGeneration() {
        let h = BurstHarness()
        h.burst.start()
        let old = h.requests[0]
        h.burst.stop()
        #expect(h.requestCancellations == 1)
        #expect(h.timers.allSatisfy { $0.cancelled })
        old(h.fix())
        #expect(h.queued.isEmpty)
        h.advance(900)
        h.burst.start()
        old(h.fix())
        #expect(h.queued.isEmpty)
        h.respond(h.fix())
        #expect(h.queued.count == 1)
    }

    @Test("Denied eligibility, revocation and storage failure cannot start or continue a burst")
    func eligibilityAndPersistence() {
        let h = BurstHarness()
        h.eligible = false
        h.burst.start()
        #expect(h.requests.isEmpty)
        h.eligible = true
        h.burst.start()
        h.eligible = false
        h.respond(h.fix())
        #expect(h.queued.isEmpty)
        #expect(h.timers.allSatisfy { $0.cancelled })
        let failed = BurstHarness()
        failed.persistSucceeds = false
        failed.burst.start()
        failed.respond(failed.fix())
        failed.advance(300)
        #expect(failed.queued.isEmpty)
        #expect(failed.requests.count == 1)
    }

    @Test("An unanswered request times out after ten seconds without later delivery")
    func requestTimeout() {
        let h = BurstHarness()
        h.burst.start()
        h.advance(10)
        #expect(h.requestCancellations == 1)
        h.respond(h.fix())
        #expect(h.queued.isEmpty)
        #expect(h.timers.allSatisfy { $0.cancelled })
    }

    @Test("Reconfiguration cannot rebind an outstanding native request to a new tenant generation")
    func contextPinnedBeforeNativeRequest() {
        let h = BurstHarness()
        h.burst.start() // Context zero is pinned while requesting, before any fix exists.
        h.contextGeneration = 1 // Reconfigured and re-enabled before cancellation executes.
        h.respond(h.fix())
        #expect(h.queued.isEmpty)
        #expect(h.requests.count == 1)
        #expect(h.timers.allSatisfy { $0.cancelled })
    }

    @Test("A late asynchronous persistence completion cannot restart a cancelled generation")
    func asynchronousPersistenceCancellation() {
        let h = BurstHarness()
        h.deferPersistence = true
        h.burst.start()
        h.respond(h.fix())
        h.advance(35)
        #expect(h.requests.count == 1)
        h.burst.stop()
        h.pendingPersistence?(true)
        h.advance(1000)
        #expect(h.requests.count == 1)
        #expect(h.timers.allSatisfy { $0.cancelled })
    }

    @Test("A delayed event loop cannot accept a result after the request budget")
    func delayedCallbackDeadline() {
        let h = BurstHarness()
        h.burst.start()
        h.elapsed = 111 // Simulate the callback arriving before a delayed timer is processed.
        h.respond(h.fix())
        #expect(h.queued.isEmpty)
        #expect(h.requestCancellations == 1)
        #expect(h.timers.allSatisfy { $0.cancelled })
    }

    @Test("Synchronous acquisition completion is persisted once and its request is cancelled")
    func synchronousCompletion() {
        var cancelled = 0
        var queued: [DeviceLocation] = []
        let fix = DeviceLocation(latitude: -23.46, longitude: -46.87, accuracy: 10,
            timestamp: Date(timeIntervalSince1970: 1_790_000_000), source: "gnss")
        let burst = FreshLocationBurst<Int>(elapsed: { 0 }, wallTime: { 1_790_000_000 },
            eligible: { true }, captureContext: { 0 }, contextIsCurrent: { $0 == 0 }, schedule: { _, _ in {} },
            request: { completion in completion(fix); return { cancelled += 1 } },
            enqueue: { fix, _, done in queued.append(fix); done(true) })
        burst.start()
        #expect(queued == [fix])
        #expect(cancelled == 1)
        burst.stop()
        #expect(cancelled == 1)
    }

    @Test("A forward clock jump cannot turn fifty physical seconds into a qualifying visit span")
    func forwardClockJumpCannotManufactureDwell() {
        let h = BurstHarness()
        h.burst.start()
        h.respond(h.fix())
        h.wallOffset = 20
        h.advance(35)
        h.respond(h.fix())
        h.advance(15)
        h.respond(h.fix())
        #expect(h.queued.count == 1)
        #expect(h.requests.count == 1)
        #expect(h.timers.allSatisfy { $0.cancelled })
    }

    @Test("Wall clock movement does not accelerate acquisition or bypass monotonic cooldown")
    func monotonicScheduling() {
        let h = BurstHarness()
        h.burst.start()
        h.respond(h.fix())
        h.wallOffset = -20
        h.advance(34)
        #expect(h.requests.count == 1)
        h.advance(1)
        h.respond(h.fix())
        h.advance(35)
        h.respond(h.fix()) // Fifty source seconds cannot satisfy the sixty-second span.
        #expect(h.queued.count == 1)
        #expect(h.timers.allSatisfy { $0.cancelled })
        h.wallOffset = 100_000
        h.burst.start()
        #expect(h.requests.count == 1)
    }
}
