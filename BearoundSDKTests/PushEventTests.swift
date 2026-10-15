//
//  PushEventTests.swift
//  BearoundSDKTests
//
//  Tests for push receipt/open measurement: marker parsing, the persisted queue
//  (cap/age/dedupe), drain-vs-keep transport outcomes, and the UN delegate swizzle.
//

import Foundation
import ObjectiveC.runtime
import Testing
import UserNotifications

@testable import BearoundSDK

// MARK: - Marker parsing

private let trackerBase = "https://track.bearound.io"

private func measurableMarker(_ sid: String) -> [String: Any] {
    ["t": "hot_campaign", "sid": sid, "d": "ctx-\(sid)", "tr": trackerBase]
}

private func marker(_ sid: String) -> PushMarkerValue {
    PushMarkerValue(sid: sid, d: "ctx-\(sid)", tr: trackerBase)
}

@Suite("PushMarker parsing")
struct PushMarkerTests {

    @Test("Object-shaped measurable marker is extracted")
    func objectMarker() {
        let userInfo: [AnyHashable: Any] = ["bearound": measurableMarker("abc-123")]
        #expect(PushMarker.extract(from: userInfo) == PushMarkerValue(sid: "abc-123", d: "ctx-abc-123", tr: trackerBase))
    }

    @Test("JSON-string-shaped marker is extracted")
    func stringMarker() {
        let json = "{\"t\":\"cold_campaign\",\"sid\":\"xyz-789\",\"d\":\"ctx\",\"tr\":\"https://track.bearound.io\"}"
        let userInfo: [AnyHashable: Any] = ["bearound": json]
        #expect(PushMarker.extract(from: userInfo)?.sid == "xyz-789")
    }

    @Test("Sync push (only t) yields nothing")
    func syncMarker() {
        #expect(PushMarker.extract(from: ["bearound": ["t": "sync"]]) == nil)
    }

    @Test("Missing d, missing tr, non-https tr or empty sid yield nothing")
    func incompleteMarkers() {
        var noD = measurableMarker("s"); noD.removeValue(forKey: "d")
        var noTr = measurableMarker("s"); noTr.removeValue(forKey: "tr")
        var http = measurableMarker("s"); http["tr"] = "http://track.bearound.io"
        var emptySid = measurableMarker("s"); emptySid["sid"] = ""
        for candidate in [noD, noTr, http, emptySid] {
            #expect(PushMarker.extract(from: ["bearound": candidate]) == nil)
        }
    }

    @Test("Missing bearound key yields nothing")
    func noMarkerAtAll() {
        #expect(PushMarker.extract(from: ["aps": ["alert": "hi"]]) == nil)
    }
}

// MARK: - Fake transport

/// Test double that replays a scripted outcome for every `send`, and records every
/// request it was asked to send.
final class FakePushEventTransport: PushEventTransport {
    var scriptedOutcome: PushEventDeliveryOutcome = .drain
    private(set) var requests: [URLRequest] = []
    var sendCount: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    private let lock = NSLock()

    func send(request: URLRequest, completion: @escaping (PushEventDeliveryOutcome) -> Void) {
        lock.lock()
        requests.append(request)
        lock.unlock()
        completion(scriptedOutcome)
    }
}

/// Holds completions until the test releases them, like a real network call.
final class DeferredPushEventTransport: PushEventTransport {
    private(set) var requests: [URLRequest] = []
    private var pending: [(PushEventDeliveryOutcome) -> Void] = []
    private let lock = NSLock()

    func send(request: URLRequest, completion: @escaping (PushEventDeliveryOutcome) -> Void) {
        lock.lock()
        requests.append(request)
        pending.append(completion)
        lock.unlock()
    }

    func completeAll(_ outcome: PushEventDeliveryOutcome) {
        lock.lock()
        let toRun = pending
        pending.removeAll()
        lock.unlock()
        toRun.forEach { $0(outcome) }
    }
}

// MARK: - Queue: cap / age / dedupe / drain-keep

@Suite("PushEventQueue")
struct PushEventQueueTests {

    private func makeQueue(outcome: PushEventDeliveryOutcome = .drain) -> (PushEventQueue, FakePushEventTransport) {
        let transport = FakePushEventTransport()
        transport.scriptedOutcome = outcome
        let queue = PushEventQueue(transport: transport, suiteName: "com.bearound.sdk.test.pushevents.\(UUID().uuidString)")
        return (queue, transport)
    }

    private func entry(_ sid: String, at date: Date) -> PushEventEntry {
        PushEventEntry(sid: sid, type: .received, occurredAt: date, attempt: 0, d: "ctx-\(sid)", tr: trackerBase)
    }

    @Test("A hit is a GET to {tr}/v1/push:{verb}?d= with no credential and no body")
    func hitShape() {
        let (queue, transport) = makeQueue(outcome: .drain)
        queue.enqueue(marker: PushMarkerValue(sid: "s1", d: "eyJ2Ijox-_", tr: trackerBase), type: .opened)
        queue.enqueue(marker: PushMarkerValue(sid: "s1", d: "eyJ2Ijox-_", tr: trackerBase), type: .received)

        let urls = transport.requests.map { $0.url?.absoluteString }
        #expect(urls == [
            "https://track.bearound.io/v1/push:open?d=eyJ2Ijox-_",
            "https://track.bearound.io/v1/push:received?d=eyJ2Ijox-_",
        ])
        for request in transport.requests {
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.httpBody == nil)
        }
    }

    @Test("Enqueue then successful drain empties the persisted queue, with no configuration")
    func enqueueThenDrainOnSuccess() {
        let (queue, _) = makeQueue(outcome: .drain)
        queue.enqueue(marker: marker("sid-1"), type: .received)

        #expect(queue.entriesForTesting().isEmpty)
    }

    @Test("Enqueue with a keep outcome (5xx) leaves the entry queued")
    func enqueueKeepsOnServerError() {
        let (queue, _) = makeQueue(outcome: .keep)
        queue.enqueue(marker: marker("sid-2"), type: .received)

        let entries = queue.entriesForTesting()
        #expect(entries.count == 1)
        #expect(entries.first?.sid == "sid-2")
        #expect(entries.first?.attempt == 1)
    }

    @Test("2xx and non-429 4xx drain, 429 and 5xx keep")
    func drainVsKeepByResponseClass() {
        let cases: [(PushEventDeliveryOutcome, Bool)] = [
            (.drain, true),
            (.keep, false),
        ]
        for (outcome, expectDrained) in cases {
            let (queue, _) = makeQueue(outcome: outcome)
            queue.enqueue(marker: marker(UUID().uuidString), type: .received)
            #expect(queue.entriesForTesting().isEmpty == expectDrained)
        }
    }

    @Test("Duplicate (sid, type) is deduped locally, only one hit is sent")
    func dedupePerSidAndType() {
        let (queue, transport) = makeQueue(outcome: .keep)
        queue.enqueue(marker: marker("sid-dup"), type: .received)
        queue.enqueue(marker: marker("sid-dup"), type: .received)
        queue.enqueue(marker: marker("sid-dup"), type: .received)

        #expect(queue.entriesForTesting().count == 1)
        #expect(transport.sendCount == 1)
    }

    @Test("Different types for the same sid are NOT deduped against each other")
    func receivedAndOpenedAreDistinctEvents() {
        let (queue, _) = makeQueue(outcome: .keep)
        queue.enqueue(marker: marker("sid-both"), type: .received)
        queue.enqueue(marker: marker("sid-both"), type: .opened)

        let entries = queue.entriesForTesting()
        #expect(entries.count == 2)
        #expect(Set(entries.map { $0.type }) == [.received, .opened])
    }

    @Test("Queue is capped at 200 entries, oldest dropped first")
    func capEviction() {
        let (queue, _) = makeQueue(outcome: .keep)
        let now = Date()
        queue.seedForTesting((0..<210).map { entry("sid-\($0)", at: now.addingTimeInterval(Double($0))) })

        let stored = queue.entriesForTesting()
        #expect(stored.count == 200)
        #expect(!stored.contains { $0.sid == "sid-0" })
        #expect(stored.contains { $0.sid == "sid-209" })
    }

    @Test("Entries older than 7 days are evicted by age")
    func ageEviction() {
        let (queue, _) = makeQueue(outcome: .keep)
        let now = Date()
        queue.seedForTesting([entry("sid-old", at: now.addingTimeInterval(-8 * 24 * 60 * 60)), entry("sid-fresh", at: now)])

        let stored = queue.entriesForTesting()
        #expect(stored.count == 1)
        #expect(stored.first?.sid == "sid-fresh")
    }

    @Test("Cap and age eviction trigger independently of each other")
    func capAndAgeEvictIndependently() {
        let (queue, _) = makeQueue(outcome: .keep)
        let now = Date()

        let ageOnly = (0..<5).map { entry("age-\($0)", at: now) }
            + [entry("age-stale", at: now.addingTimeInterval(-10 * 24 * 60 * 60))]
        queue.seedForTesting(ageOnly)
        #expect(queue.entriesForTesting().count == 5)

        queue.seedForTesting((0..<205).map { entry("cap-\($0)", at: now) })
        #expect(queue.entriesForTesting().count == 200)
    }

    @Test("Back-to-back flushes never resend a hit already on the wire")
    func noDuplicateWhileInFlight() {
        let transport = DeferredPushEventTransport()
        let queue = PushEventQueue(transport: transport, suiteName: "com.bearound.sdk.test.pushevents.\(UUID().uuidString)")
        queue.enqueue(marker: marker("tap"), type: .opened)
        queue.enqueue(marker: marker("tap"), type: .received)
        queue.flush()
        queue.flush()

        #expect(transport.requests.count == 2)
        transport.completeAll(.drain)
        #expect(queue.entriesForTesting().isEmpty)
    }

    @Test("A failed hit waits for its backoff: repeated flushes do not resend it")
    func failedHitWaitsForBackoff() {
        let transport = DeferredPushEventTransport()
        let queue = PushEventQueue(transport: transport, suiteName: "com.bearound.sdk.test.pushevents.\(UUID().uuidString)")
        queue.enqueue(marker: marker("offline"), type: .received)
        transport.completeAll(.keep)

        for _ in 0..<5 { queue.flush() }

        #expect(transport.requests.count == 1)
        let entry = queue.entriesForTesting().first
        #expect(entry?.attempt == 1)
        #expect((entry?.nextAttemptAt ?? .distantPast) > Date())
    }

    @Test("Entries older than 7 days are dropped on flush, not sent")
    func ageEvictionOnFlush() {
        let transport = FakePushEventTransport()
        let queue = PushEventQueue(transport: transport, suiteName: "com.bearound.sdk.test.pushevents.\(UUID().uuidString)")
        // seedForTesting evicts too, so write a stale entry the way an old install would have.
        queue.seedForTesting([entry("fresh", at: Date())])
        queue.injectRawForTesting([entry("stale", at: Date().addingTimeInterval(-8 * 24 * 60 * 60))])

        queue.flush()

        #expect(transport.requests.map { $0.url?.absoluteString } == ["https://track.bearound.io/v1/push:received?d=ctx-fresh"])
        #expect(queue.entriesForTesting().isEmpty)
    }

    @Test("Persisted hits from a previous launch are sent on flush")
    func persistedHitsFlushLater() {
        let transport = FakePushEventTransport()
        transport.scriptedOutcome = .drain
        let suite = "com.bearound.sdk.test.pushevents.\(UUID().uuidString)"
        let queue = PushEventQueue(transport: transport, suiteName: suite)
        queue.seedForTesting([entry("cold-launch-sid", at: Date())])
        #expect(transport.sendCount == 0)

        queue.flush()
        #expect(transport.sendCount == 1)
        #expect(queue.entriesForTesting().isEmpty)
    }
}

// MARK: - UN delegate swizzle

/// Builds a real `UNNotificationResponse` via KVC. Neither `UNNotification` nor
/// `UNNotificationResponse` expose a public initializer; both are plain `NSObject`
/// subclasses with settable `request`/`notification`/`actionIdentifier` KVC keys, which
/// is the standard way to construct one for tests.
private func makeNotificationResponse(userInfo: [AnyHashable: Any]) -> UNNotificationResponse {
    let content = UNMutableNotificationContent()
    content.userInfo = userInfo
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)

    let notificationClass = NSClassFromString("UNNotification") as! NSObject.Type
    let notification = notificationClass.init()
    notification.setValue(request, forKey: "request")
    notification.setValue(Date(), forKey: "date")

    let responseClass = NSClassFromString("UNNotificationResponse") as! NSObject.Type
    let response = responseClass.init()
    response.setValue(notification, forKey: "notification")
    response.setValue(UNNotificationDefaultActionIdentifier, forKey: "actionIdentifier")
    return response as! UNNotificationResponse
}

// The `center` argument is declared `Any` here (rather than the concrete
// `UNUserNotificationCenter`) because `UNUserNotificationCenter.current()` crashes when
// called from a bare XCTest bundle with no host app (no notification entitlements
// context). The interceptor never reads `center`, only `response`, so an unrelated
// `NSObject` stand-in is safe to pass at the ABI level (Objective-C messaging only
// cares that it is an object pointer).
private typealias TestDidReceiveResponseIMP = @convention(c)
    (Any, Selector, Any, UNNotificationResponse, @escaping () -> Void) -> Void

private let didReceiveResponseSelector =
    #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))

/// Invokes the (possibly swizzle-added) `didReceive:withCompletionHandler:` on `delegate`
/// directly via its IMP, bypassing `perform(_:with:with:)` (which cannot pass a block
/// argument): this calls the C function pointer directly with a concrete closure.
private func invokeDidReceive(
    on delegate: NSObject,
    response: UNNotificationResponse,
    completion: @escaping () -> Void
) {
    guard let method = class_getInstanceMethod(type(of: delegate), didReceiveResponseSelector) else {
        Issue.record("Expected \(didReceiveResponseSelector) to be present after patching")
        return
    }
    let imp = unsafeBitCast(method_getImplementation(method), to: TestDidReceiveResponseIMP.self)
    imp(delegate, didReceiveResponseSelector, NSObject(), response, completion)
}

@objc private class DelegateWithoutMethod: NSObject, UNUserNotificationCenterDelegate {}

@objc private class DelegateWithOwnMethod: NSObject, UNUserNotificationCenterDelegate {
    var originalCalled = false
    var lastUserInfo: [AnyHashable: Any]?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        originalCalled = true
        lastUserInfo = response.notification.request.content.userInfo
        completionHandler()
    }
}

/// Base class defines the method; the subclass only inherits it. Patching the subclass
/// must not rewrite the base class (other subclasses of it would change behavior too).
@objc private class InheritingBaseDelegate: NSObject, UNUserNotificationCenterDelegate {
    var baseCalled = false

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        baseCalled = true
        completionHandler()
    }
}

@objc private class InheritingChildDelegate: InheritingBaseDelegate {}

/// Implements nothing itself and forwards didReceive to an inner handler, like a
/// multicast delegate or a proxy.
@objc private class ForwardingDelegate: NSObject, UNUserNotificationCenterDelegate {
    let inner = DelegateWithOwnMethod()
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        aSelector == didReceiveResponseSelector ? inner : super.forwardingTarget(for: aSelector)
    }
    override func responds(to aSelector: Selector!) -> Bool {
        aSelector == didReceiveResponseSelector || super.responds(to: aSelector)
    }
}

@objc private class MeasuringDelegate: NSObject, UNUserNotificationCenterDelegate {}

@Suite("PushDelegateSwizzle", .serialized)
struct PushDelegateSwizzleTests {

    @Test("A delegate class without the method gets it added, and the completion handler is called")
    func addsMethodWhenAbsent() {
        let delegate = DelegateWithoutMethod()
        PushDelegateSwizzle.patchIfNeededForTesting(delegateClass: DelegateWithoutMethod.self)

        #expect(delegate.responds(to: didReceiveResponseSelector))

        var completionCalled = false
        let response = makeNotificationResponse(userInfo: ["bearound": ["sid": "swizzle-added"]])
        invokeDidReceive(on: delegate, response: response) {
            completionCalled = true
        }

        #expect(completionCalled)
    }

    @Test("A delegate class with its own method still has that method called through, and the completion handler runs")
    func callsThroughWhenPresent() {
        let delegateClass = DelegateWithOwnMethod.self
        // Patching the same class twice must stay a no-op past the first time (idempotent):
        // the second call must not double-wrap (and therefore double-call) the original.
        PushDelegateSwizzle.patchIfNeededForTesting(delegateClass: delegateClass)
        PushDelegateSwizzle.patchIfNeededForTesting(delegateClass: delegateClass)

        let delegate = DelegateWithOwnMethod()
        var completionCalled = false
        let response = makeNotificationResponse(userInfo: ["bearound": ["sid": "swizzle-existing"]])
        invokeDidReceive(on: delegate, response: response) {
            completionCalled = true
        }

        #expect(delegate.originalCalled)
        #expect(completionCalled)
    }

    @Test("A non-bearound notification leaves the original delegate call untouched")
    func nonBearoundResponseIsUntouched() {
        let delegateClass = DelegateWithOwnMethod.self
        PushDelegateSwizzle.patchIfNeededForTesting(delegateClass: delegateClass)

        let delegate = DelegateWithOwnMethod()
        var completionCalled = false
        let response = makeNotificationResponse(userInfo: ["aps": ["alert": "not ours"]])
        invokeDidReceive(on: delegate, response: response) {
            completionCalled = true
        }

        #expect(delegate.originalCalled)
        #expect(completionCalled)
        #expect((delegate.lastUserInfo?["bearound"] as? [String: Any]) == nil)
    }

    @Test("Patching a subclass that only inherits the method leaves the base class untouched")
    func inheritedMethodPatchesSubclassOnly() {
        let baseIMPBefore = method_getImplementation(
            class_getInstanceMethod(InheritingBaseDelegate.self, didReceiveResponseSelector)!
        )
        PushDelegateSwizzle.patchIfNeededForTesting(delegateClass: InheritingChildDelegate.self)
        let baseIMPAfter = method_getImplementation(
            class_getInstanceMethod(InheritingBaseDelegate.self, didReceiveResponseSelector)!
        )
        #expect(baseIMPBefore == baseIMPAfter)

        let child = InheritingChildDelegate()
        var completionCalled = false
        let response = makeNotificationResponse(userInfo: ["bearound": ["sid": "swizzle-inherited"]])
        invokeDidReceive(on: child, response: response) {
            completionCalled = true
        }
        #expect(child.baseCalled)
        #expect(completionCalled)
    }

    @Test("A forwarding delegate is left untouched so the host keeps handling its taps")
    func forwardingDelegateNotPatched() {
        let delegate = ForwardingDelegate()
        PushDelegateSwizzle.patchIfNeededForTesting(delegate: delegate)

        #expect(class_getInstanceMethod(ForwardingDelegate.self, didReceiveResponseSelector) == nil)
    }

    @Test("A tap on a measurable push through the patched delegate fires open and received hits")
    func tapFiresTrackerHits() {
        let transport = FakePushEventTransport()
        PushEventQueue.shared.resetForTesting()
        let previous = PushEventQueue.shared.transport
        PushEventQueue.shared.transport = transport
        defer {
            PushEventQueue.shared.transport = previous
            PushEventQueue.shared.resetForTesting()
        }

        PushDelegateSwizzle.patchIfNeededForTesting(delegate: MeasuringDelegate())
        let response = makeNotificationResponse(userInfo: ["bearound": measurableMarker("tap-sid")])
        var completed = false
        invokeDidReceive(on: MeasuringDelegate(), response: response) { completed = true }

        #expect(completed)
        #expect(transport.requests.map { $0.url?.absoluteString } == [
            "https://track.bearound.io/v1/push:open?d=ctx-tap-sid",
            "https://track.bearound.io/v1/push:received?d=ctx-tap-sid",
        ])
    }
}
