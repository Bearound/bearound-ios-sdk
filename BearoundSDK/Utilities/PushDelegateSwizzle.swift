//
//  PushDelegateSwizzle.swift
//  BearoundSDK
//
//  Reports push OPENS (taps): swizzles `UNUserNotificationCenter.setDelegate:` so that
//  whatever `UNUserNotificationCenterDelegate` the host installs (now or later) gets its
//  `userNotificationCenter(_:didReceive:withCompletionHandler:)` patched exactly once per
//  class, to detect a tap on a Bearound notification (bearound.sid in the response's
//  userInfo) and record an `opened` event. Always calls through to the original
//  implementation (or the completion handler, if the class had none), so host behavior is
//  unaffected (REQ-019).
//
//  Opt out via `BearoundAppDelegateProxyEnabled = NO` in Info.plist (same flag as
//  `PushTokenAutoCapture`), which leaves `BeAroundSDK.shared.handleNotificationResponse(_:)`
//  and `trackNotificationOpened(userInfo:)` as the host's explicit wiring path (REQ-021).
//

import Foundation
import ObjectiveC.runtime
import UIKit
import UserNotifications

private typealias SetDelegateIMP = @convention(c) (Any, Selector, AnyObject?) -> Void
private typealias DidReceiveResponseIMP = @convention(c)
    (Any, Selector, UNUserNotificationCenter, UNNotificationResponse, @escaping () -> Void) -> Void

enum PushDelegateSwizzle {
    private static var installed = false

    /// Classes already patched for `didReceive:withCompletionHandler:`, so a class handed to
    /// `setDelegate:` more than once (or shared across instances) is only patched once.
    /// Access is synchronized by `lock` (setDelegate: can be called off the main thread).
    private static var patchedClasses = Set<ObjectIdentifier>()
    private static let lock = NSLock()

    private static let didReceiveResponseSelector =
        #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))

    /// Installs the `setDelegate:` swizzle and, if no delegate is set yet, a minimal
    /// SDK-owned delegate (REQ-020). No-op when the host opted out via Info.plist
    /// (REQ-021) or when already installed.
    static func enableIfPossible() {
        guard !installed else { return }

        if let enabled = Bundle.main.object(forInfoDictionaryKey: "BearoundAppDelegateProxyEnabled") as? Bool,
           enabled == false {
            NSLog("[BeAroundSDK] UN delegate proxy disabled (BearoundAppDelegateProxyEnabled=NO), wire push opens manually")
            return
        }

        installed = true

        // Synchronous when already on the main thread (didFinishLaunching,
        // configure): the tap that cold-launches the app is delivered right after
        // launch finishes, so an async hop could miss it.
        let install = {
            let center = UNUserNotificationCenter.current()
            installSetDelegateSwizzle(on: type(of: center))

            if let existing = center.delegate {
                patchIfNeeded(delegate: existing)
            } else {
                let fallback = BearoundNotificationDelegate.shared
                center.delegate = fallback
                NSLog("[BeAroundSDK] No UNUserNotificationCenterDelegate set, installed a minimal SDK delegate")
            }
        }
        if Thread.isMainThread { install() } else { DispatchQueue.main.async(execute: install) }
    }

    // MARK: - setDelegate: swizzle

    private static func installSetDelegateSwizzle(on cls: AnyClass) {
        let selector = #selector(setter: UNUserNotificationCenter.delegate)
        guard let method = class_getInstanceMethod(cls, selector) else { return }

        // Capture the original BEFORE the swap: a setDelegate: on another thread
        // right after the swap must find it, or the host's delegate is dropped.
        let original = unsafeBitCast(method_getImplementation(method), to: SetDelegateIMP.self)
        let block: @convention(block) (Any, AnyObject?) -> Void = { receiver, newDelegate in
            if let newDelegate {
                patchIfNeeded(delegate: newDelegate)
            }
            original(receiver, selector, newDelegate)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    // MARK: - Per-class didReceive:withCompletionHandler: patch

    /// Adds (or exchanges) `didReceive:withCompletionHandler:` on `delegateClass`, exactly
    /// once per class. Reports `opened` (+ `received`) for Bearound responses, then always
    /// calls through: the original implementation if the class had one, or the completion
    /// handler otherwise.
    /// Patches the delegate's class. Skipped when the class has no implementation of
    /// its own (not even inherited) but the instance still answers the selector:
    /// that is a forwarding delegate (NSProxy, `forwardingTarget(for:)`, multicast),
    /// and adding a method would shadow the forward and swallow every tap of the
    /// host. Those hosts report opens with `handleNotificationResponse(_:)`.
    private static func patchIfNeeded(delegate: AnyObject) {
        let delegateClass: AnyClass = object_getClass(delegate) ?? type(of: delegate)
        if class_getInstanceMethod(delegateClass, didReceiveResponseSelector) == nil,
           delegate.responds(to: didReceiveResponseSelector) {
            NSLog("[BeAroundSDK] UN delegate forwards didReceive, not patched: call handleNotificationResponse(_:) to report opens")
            return
        }
        patchIfNeeded(delegateClass: delegateClass)
    }

    private static func patchIfNeeded(delegateClass: AnyClass) {
        let key = ObjectIdentifier(delegateClass)

        lock.lock()
        guard !patchedClasses.contains(key) else {
            lock.unlock()
            return
        }
        patchedClasses.insert(key)
        lock.unlock()

        let existingMethod = class_getInstanceMethod(delegateClass, didReceiveResponseSelector)
        let hadOwnImplementation = existingMethod != nil

        // Captured per-class so the interceptor calls through to THIS class's original
        // implementation (or the completion handler if it had none), never a different
        // class's IMP.
        var originalIMP: DidReceiveResponseIMP?
        if let existingMethod {
            originalIMP = unsafeBitCast(method_getImplementation(existingMethod), to: DidReceiveResponseIMP.self)
        }

        let block: @convention(block)
            (Any, UNUserNotificationCenter, UNNotificationResponse, @escaping () -> Void) -> Void = {
                receiver, center, response, completionHandler in

                let userInfo = response.notification.request.content.userInfo
                if let marker = PushMarker.extract(from: userInfo) {
                    NSLog("[BeAroundSDK] Bearound notification opened")
                    PushEventQueue.shared.enqueue(marker: marker, type: .opened)
                    PushEventQueue.shared.enqueue(marker: marker, type: .received)
                }

                if hadOwnImplementation, let originalIMP {
                    originalIMP(receiver, didReceiveResponseSelector, center, response, completionHandler)
                } else {
                    completionHandler()
                }
            }
        let newIMP = imp_implementationWithBlock(block)

        // Add on the class itself first. This succeeds when the class does not define the
        // method (absent, or only inherited): the interceptor then calls the inherited IMP,
        // and the superclass stays untouched. Only a method the class defines itself gets
        // its implementation replaced; `method_setImplementation` on an inherited Method
        // would rewrite the superclass for every sibling subclass.
        // Objective-C signature: void (id, SEL, UNUserNotificationCenter*,
        // UNNotificationResponse*, void (^)(void))
        let types = existingMethod.flatMap { method_getTypeEncoding($0) }.map { String(cString: $0) } ?? "v@:@@@?"
        if !class_addMethod(delegateClass, didReceiveResponseSelector, newIMP, types), let existingMethod {
            method_setImplementation(existingMethod, newIMP)
        }
    }

    // MARK: - Test support

    /// Resets swizzle state so tests can re-exercise `enableIfPossible()`/`patchIfNeeded`
    /// against fresh delegate classes. Test-only.
    static func resetForTesting() {
        lock.lock()
        patchedClasses.removeAll()
        lock.unlock()
        installed = false
    }

    /// Exposes the per-class patch step directly, so tests can patch a delegate class
    /// without needing a real `UNUserNotificationCenter.current()` round trip.
    static func patchIfNeededForTesting(delegateClass: AnyClass) {
        patchIfNeeded(delegateClass: delegateClass)
    }

    /// The instance-aware entry point, as `setDelegate:` uses it. Test-only.
    static func patchIfNeededForTesting(delegate: AnyObject) {
        patchIfNeeded(delegate: delegate)
    }
}

/// Minimal SDK-owned `UNUserNotificationCenterDelegate` installed only when the host has
/// none at SDK install time (REQ-020). It deliberately does NOT implement `willPresent`:
/// a delegate without it presents like no delegate at all (no foreground banner), and
/// libraries that chain to a delegate they find (firebase_messaging, for one) fall back
/// to their own presentation options instead of inheriting an empty set from us.
final class BearoundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = BearoundNotificationDelegate()

    private override init() {}

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let marker = PushMarker.extract(from: userInfo) {
            PushEventQueue.shared.enqueue(marker: marker, type: .opened)
            PushEventQueue.shared.enqueue(marker: marker, type: .received)
        }
        completionHandler()
    }
}
