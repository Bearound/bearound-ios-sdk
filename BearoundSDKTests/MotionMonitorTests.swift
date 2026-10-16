import CoreMotion
import Foundation
import Testing
@testable import BearoundSDK

@Suite("Motion Monitor Tests")
struct MotionMonitorTests {
    private final class Provider: MotionActivityProviding {
        var isActivityAvailable = true
        var authorizationStatus: CMAuthorizationStatus = .authorized
        var starts = 0
        var stops = 0
        var callbacks: [(NativeActivityObservation?) -> Void] = []
        func startUpdates(on queue: OperationQueue, handler: @escaping (NativeActivityObservation?) -> Void) {
            starts += 1
            callbacks.append(handler)
        }
        func stopUpdates() { stops += 1 }
    }

    private final class Clock {
        var value = SamplingClock(wallTimeMs: 1_000_000, monotonicTimeMs: 10_000, bootIdentifier: "boot")
    }

    @Test("Unavailable hardware never starts CoreMotion")
    func unavailableHardware() {
        let provider = Provider()
        provider.isActivityAvailable = false
        let monitor = MotionMonitor(provider: provider, usageDescription: { "Activity" })
        var fallbacks = 0
        let started = monitor.start(generation: 1) { activity, _, _ in
            #expect(activity == nil)
            fallbacks += 1
        }
        #expect(!started)
        #expect(provider.starts == 0 && provider.stops == 0 && fallbacks == 1)
    }

    @Test("Missing empty and whitespace descriptions never start CoreMotion")
    func missingHostDescription() {
        for description: String? in [nil, "", " \n\t "] {
            let provider = Provider()
            let monitor = MotionMonitor(provider: provider, usageDescription: { description })
            #expect(!monitor.start(generation: 0) { _, _, _ in })
            #expect(provider.starts == 0 && provider.stops == 0)
        }
    }

    @Test("Undetermined denied and restricted authorization never invokes update APIs")
    func authorizationGate() {
        for status: CMAuthorizationStatus in [.notDetermined, .denied, .restricted] {
            let provider = Provider()
            provider.authorizationStatus = status
            let monitor = MotionMonitor(provider: provider, usageDescription: { "Activity" })
            #expect(!monitor.start(generation: 0) { _, _, _ in })
            #expect(provider.starts == 0 && provider.stops == 0)
        }
    }

    @Test("Authorized activity keeps original start time flags confidence and generation")
    func authorizedOriginalActivity() {
        let provider = Provider()
        let clock = Clock()
        let monitor = MotionMonitor(provider: provider, usageDescription: { "Activity" }, clock: { clock.value })
        var received: NativeActivityObservation?
        var receivedGeneration: UInt64?
        #expect(monitor.start(generation: 7) { activity, _, generation in
            received = activity
            receivedGeneration = generation
        })
        let activity = NativeActivityObservation(observedAtMs: 980_000, automotive: true,
                                                stationary: true, confidence: .high)
        provider.callbacks[0](activity)
        #expect(provider.starts == 1)
        #expect(received == activity && receivedGeneration == 7)
        monitor.stop()
        #expect(provider.stops == 1)
    }

    @Test("Expired future missing and error callbacks provide fallback without new timestamps")
    func delayedAndInvalidCallbacks() {
        let provider = Provider()
        let clock = Clock()
        let monitor = MotionMonitor(provider: provider, usageDescription: { "Activity" }, clock: { clock.value })
        var fallbacks = 0
        monitor.start(generation: 2) { activity, _, generation in
            #expect(activity == nil && generation == 2)
            fallbacks += 1
        }
        for timestamp: Int64? in [879_999, 1_000_001, nil] {
            provider.callbacks[0](NativeActivityObservation(observedAtMs: timestamp, walking: true, confidence: .high))
        }
        provider.callbacks[0](nil)
        #expect(fallbacks == 4 && provider.starts == 1)
    }

    @Test("Suspension reboot and unreliable clocks invalidate callbacks and stop the observer")
    func suspendedCallbacks() {
        for invalid in [SamplingClock(wallTimeMs: 1_240_000, monotonicTimeMs: 11_000, bootIdentifier: "boot"),
                        SamplingClock(wallTimeMs: 1_001_000, monotonicTimeMs: 11_000, bootIdentifier: "new_boot"),
                        SamplingClock(wallTimeMs: 1_001_000, monotonicTimeMs: 11_000, bootIdentifier: "boot", isReliable: false)] {
            let provider = Provider()
            let clock = Clock()
            let monitor = MotionMonitor(provider: provider, usageDescription: { "Activity" }, clock: { clock.value })
            var fallbacks = 0
            monitor.start(generation: 0) { activity, _, _ in
                #expect(activity == nil)
                fallbacks += 1
            }
            clock.value = invalid
            provider.callbacks[0](NativeActivityObservation(observedAtMs: invalid.wallTimeMs, walking: true))
            provider.callbacks[0](nil)
            #expect(fallbacks == 1 && provider.stops == 1)
        }
    }

    @Test("Stopping ignores late callbacks from the old generation")
    func stopRejectsOldCallbacks() {
        let provider = Provider()
        let clock = Clock()
        let monitor = MotionMonitor(provider: provider, usageDescription: { "Activity" }, clock: { clock.value })
        var calls = 0
        monitor.start(generation: 1) { _, _, _ in calls += 1 }
        monitor.stop()
        provider.callbacks[0](NativeActivityObservation(observedAtMs: clock.value.wallTimeMs, walking: true))
        #expect(calls == 0 && provider.stops == 1)
    }

    @Test("Restarting rejects callbacks from the previous start")
    func restartRejectsOldCallbacks() {
        let provider = Provider()
        let clock = Clock()
        let monitor = MotionMonitor(provider: provider, usageDescription: { "Activity" }, clock: { clock.value })
        var generations: [UInt64] = []
        monitor.start(generation: 1) { _, _, generation in generations.append(generation) }
        monitor.start(generation: 2) { _, _, generation in generations.append(generation) }
        let activity = NativeActivityObservation(observedAtMs: clock.value.wallTimeMs, walking: true)
        provider.callbacks[0](activity)
        provider.callbacks[1](activity)
        #expect(generations == [2] && provider.starts == 2 && provider.stops == 1)
    }

    @Test("Revoked authorization availability or host description removes the active observer")
    func capabilityRevocation() {
        for change in 0 ... 2 {
            let provider = Provider()
            let clock = Clock()
            var description: String? = "Activity"
            let monitor = MotionMonitor(provider: provider, usageDescription: { description }, clock: { clock.value })
            var fallbacks = 0
            monitor.start(generation: 1) { activity, _, _ in
                #expect(activity == nil)
                fallbacks += 1
            }
            if change == 0 { provider.authorizationStatus = .denied }
            if change == 1 { provider.isActivityAvailable = false }
            if change == 2 { description = nil }
            provider.callbacks[0](NativeActivityObservation(observedAtMs: clock.value.wallTimeMs, stationary: true))
            #expect(fallbacks == 1 && provider.stops == 1)
        }
    }
    @Test("Motion collection policy blocks authorized native activity before source access and stops revoked callbacks")
    func collectionPolicyGate() {
        let provider = Provider()
        var allowed = false
        let clock = Clock()
        let monitor = MotionMonitor(provider: provider, usageDescription: { "Activity" }, clock: { clock.value })
        #expect(!monitor.start(generation: 1, collectionAllowed: { allowed }) { _, _, _ in })
        #expect(provider.starts == 0)
        allowed = true
        #expect(monitor.start(generation: 2, collectionAllowed: { allowed }) { _, _, _ in })
        allowed = false
        provider.callbacks[0](NativeActivityObservation(observedAtMs: clock.value.wallTimeMs, walking: true))
        #expect(provider.starts == 1 && provider.stops == 1)
    }

}
