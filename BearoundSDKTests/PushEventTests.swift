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

// MARK: - Marker parsing (REQ-018)

@Suite("PushMarker parsing")
struct PushMarkerTests {

    @Test("Object-shaped marker with sid is extracted")
    func objectMarkerWithSid() {
        let userInfo: [AnyHashable: Any] = ["bearound": ["t": "hot_campaign", "sid": "abc-123"]]
        #expect(PushMarker.extractSid(from: userInfo) == "abc-123")
    }

    @Test("JSON-string-shaped marker with sid is extracted")
    func stringMarkerWithSid() {
        let json = "{\"t\":\"cold_campaign\",\"sid\":\"xyz-789\"}"
        let userInfo: [AnyHashable: Any] = ["bearound": json]
        #expect(PushMarker.extractSid(from: userInfo) == "xyz-789")
    }

    @Test("Marker with no sid (sync push) yields nothing")
    func markerWithoutSid() {
        let userInfo: [AnyHashable: Any] = ["bearound": ["t": "sync"]]
        #expect(PushMarker.extractSid(from: userInfo) == nil)
    }

    @Test("Missing bearound key yields nothing")
    func noMarkerAtAll() {
        let userInfo: [AnyHashable: Any] = ["aps": ["alert": "hi"]]
        #expect(PushMarker.extractSid(from: userInfo) == nil)
    }

    @Test("Empty sid is treated as absent")
    func emptySidIsAbsent() {
        let userInfo: [AnyHashable: Any] = ["bearound": ["sid": ""]]
        #expect(PushMarker.extractSid(from: userInfo) == nil)
    }
}

// MARK: - Fake transport (REQ-026)

/// Test double that replays a scripted outcome for every `send`, and records every
/// request it was asked to send.
final class FakePushEventTransport: PushEventTransport {
    var scriptedOutcome: PushEventDeliveryOutcome = .drain
    private(set) var sendCount = 0
    private let lock = NSLock()

    func send(request: URLRequest, completion: @escaping (PushEventDeliveryOutcome) -> Void) {
        lock.lock()
        sendCount += 1
        lock.unlock()
        completion(scriptedOutcome)
    }
}

// MARK: - Queue: cap / age / dedupe / drain-keep (REQ-025, REQ-026)

@Suite("PushEventQueue")
struct PushEventQueueTests {

    private func makeQueue(outcome: PushEventDeliveryOutcome = .drain) -> (PushEventQueue, FakePushEventTransport) {
        let transport = FakePushEventTransport()
        transport.scriptedOutcome = outcome
        let queue = PushEventQueue(transport: transport, suiteName: "com.bearound.sdk.test.pushevents.\(UUID().uuidString)")
        queue.install(businessToken: "test-token")
        return (queue, transport)
    }

    @Test("Enqueue then successful drain empties the persisted queue")
    func enqueueThenDrainOnSuccess() {
        let (queue, _) = makeQueue(outcome: .drain)
        queue.enqueue(sid: "sid-1", type: .received)

        #expect(queue.entriesForTesting().isEmpty)
    }

    @Test("Enqueue with a keep outcome (5xx) leaves the entry queued")
    func enqueueKeepsOnServerError() {
        let (queue, _) = makeQueue(outcome: .keep)
        queue.enqueue(sid: "sid-2", type: .received)

        let entries = queue.entriesForTesting()
        #expect(entries.count == 1)
        #expect(entries.first?.sid == "sid-2")
        #expect(entries.first?.attempt == 1)
    }

    @Test("202 drains, any non-429 4xx drains, 429 and 5xx keep")
    func drainVsKeepByResponseClass() {
        let cases: [(PushEventDeliveryOutcome, Bool)] = [
            (.drain, true),   // 202 or non-429 4xx
            (.keep, false),   // 429 or 5xx or transport error
        ]
        for (outcome, expectDrained) in cases {
            let (queue, _) = makeQueue(outcome: outcome)
            queue.enqueue(sid: UUID().uuidString, type: .received)
            let isEmpty = queue.entriesForTesting().isEmpty
            #expect(isEmpty == expectDrained)
        }
    }

    @Test("Duplicate (sid, type) is deduped locally, only one entry is sent")
    func dedupePerSidAndType() {
        let (queue, transport) = makeQueue(outcome: .keep)
        queue.enqueue(sid: "sid-dup", type: .received)
        queue.enqueue(sid: "sid-dup", type: .received)
        queue.enqueue(sid: "sid-dup", type: .received)

        #expect(queue.entriesForTesting().count == 1)
        #expect(transport.sendCount == 1)
    }

    @Test("Different types for the same sid are NOT deduped against each other")
    func receivedAndOpenedAreDistinctEvents() {
        let (queue, _) = makeQueue(outcome: .keep)
        queue.enqueue(sid: "sid-both", type: .received)
        queue.enqueue(sid: "sid-both", type: .opened)

        let entries = queue.entriesForTesting()
        #expect(entries.count == 2)
        #expect(Set(entries.map { $0.type }) == [.received, .opened])
    }

    @Test("Queue is capped at 200 entries, oldest dropped first")
    func capEviction() {
        let (queue, _) = makeQueue(outcome: .keep)
        let now = Date()
        let entries = (0..<210).map { i in
            PushEventEntry(sid: "sid-\(i)", type: .received, occurredAt: now.addingTimeInterval(Double(i)), attempt: 0)
        }
        queue.seedForTesting(entries)

        let stored = queue.entriesForTesting()
        #expect(stored.count == 200)
        // Oldest 10 (sid-0...sid-9) must have been dropped; the newest must remain.
        #expect(!stored.contains { $0.sid == "sid-0" })
        #expect(stored.contains { $0.sid == "sid-209" })
    }

    @Test("Entries older than 7 days are evicted by age")
    func ageEviction() {
        let (queue, _) = makeQueue(outcome: .keep)
        let now = Date()
        let old = PushEventEntry(sid: "sid-old", type: .received, occurredAt: now.addingTimeInterval(-8 * 24 * 60 * 60), attempt: 0)
        let fresh = PushEventEntry(sid: "sid-fresh", type: .received, occurredAt: now, attempt: 0)
        queue.seedForTesting([old, fresh])

        let stored = queue.entriesForTesting()
        #expect(stored.count == 1)
        #expect(stored.first?.sid == "sid-fresh")
    }

    @Test("Cap and age eviction trigger independently of each other")
    func capAndAgeEvictIndependently() {
        let (queue, _) = makeQueue(outcome: .keep)
        let now = Date()

        // Age-only case: one old entry among otherwise-fresh entries, well under the cap.
        let ageOnly = (0..<5).map { i in
            PushEventEntry(sid: "age-\(i)", type: .received, occurredAt: now, attempt: 0)
        } + [PushEventEntry(sid: "age-stale", type: .received, occurredAt: now.addingTimeInterval(-10 * 24 * 60 * 60), attempt: 0)]
        queue.seedForTesting(ageOnly)
        #expect(queue.entriesForTesting().count == 5)

        // Cap-only case: all fresh, but over 200.
        let capOnly = (0..<205).map { i in
            PushEventEntry(sid: "cap-\(i)", type: .received, occurredAt: now, attempt: 0)
        }
        queue.seedForTesting(capOnly)
        #expect(queue.entriesForTesting().count == 200)
    }

    @Test("An event enqueued before install() persists and flushes once the token is known")
    func coldLaunchBeforeInstallFlushesLater() {
        let transport = FakePushEventTransport()
        transport.scriptedOutcome = .drain
        let queue = PushEventQueue(transport: transport, suiteName: "com.bearound.sdk.test.pushevents.\(UUID().uuidString)")

        // No install() yet (business token unknown): a tap that cold-launches the app
        // before configure() runs lands here.
        queue.enqueue(sid: "cold-launch-sid", type: .opened)
        #expect(transport.sendCount == 0)
        #expect(queue.entriesForTesting().count == 1)

        queue.install(businessToken: "late-token")
        #expect(transport.sendCount == 1)
        #expect(queue.entriesForTesting().isEmpty)
    }
}

// MARK: - UN delegate swizzle (REQ-019, REQ-020)

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

@Suite("PushDelegateSwizzle")
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
}
