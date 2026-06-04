//
//  PushTokenAutoCapture.swift
//  BearoundSDK
//
//  Created by Bearound on 02/06/26.
//

import Foundation
import UIKit
import ObjectiveC.runtime

/// C-function shape of `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
/// (receiver, _cmd, application, deviceToken). Used to call the host app's original impl.
private typealias DidRegisterIMP = @convention(c) (Any, Selector, UIApplication, NSData) -> Void

/// Automatically captures the APNs device token from the host app's `UIApplicationDelegate`
/// via method swizzling — the same technique Firebase / OneSignal / Braze use — so the client
/// doesn't have to forward `didRegisterForRemoteNotificationsWithDeviceToken` manually.
///
/// The SDK also triggers `registerForRemoteNotifications()` itself (no user prompt — that only
/// fetches the token; permission is a separate concern for *visible* notifications).
///
/// **The one thing the SDK can't do for you:** enable the *Push Notifications* capability
/// (the `aps-environment` entitlement) — that's signed app config the client must turn on.
///
/// Opt out by setting `BearoundAppDelegateProxyEnabled` = `NO` in Info.plist; then call
/// `BeAroundSDK.shared.setPushToken(_:)` yourself from your AppDelegate.
enum PushTokenAutoCapture {
    private static var installed = false
    private static var originalIMP: DidRegisterIMP?

    /// Installs the swizzle (once) and requests APNs registration. Safe to call from `configure()`.
    static func enableIfPossible() {
        guard !installed else { return }

        if let enabled = Bundle.main.object(forInfoDictionaryKey: "BearoundAppDelegateProxyEnabled") as? Bool,
           enabled == false {
            NSLog("[BeAroundSDK] AppDelegate proxy disabled (BearoundAppDelegateProxyEnabled=NO) — call setPushToken(_:) manually")
            return
        }

        installed = true
        DispatchQueue.main.async {
            installSwizzle()
            UIApplication.shared.registerForRemoteNotifications()
            NSLog("[BeAroundSDK] Auto push-token capture enabled; requested APNs registration")
        }
    }

    private static func installSwizzle() {
        guard let delegate = UIApplication.shared.delegate else {
            NSLog("[BeAroundSDK] No UIApplicationDelegate found — cannot auto-capture push token (use setPushToken)")
            return
        }
        let cls: AnyClass = type(of: delegate)
        let selector = #selector(UIApplicationDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:))

        // Our replacement: capture the token, then chain to the app's original impl (if any).
        let block: @convention(block) (Any, UIApplication, NSData) -> Void = { receiver, application, deviceToken in
            let token = (deviceToken as Data).map { String(format: "%02x", $0) }.joined()
            NSLog("[BeAroundSDK] APNs token captured automatically (%d bytes)", (deviceToken as Data).count)
            PushTokenStore.setToken(token)
            originalIMP?(receiver, selector, application, deviceToken)
        }
        let newIMP = imp_implementationWithBlock(block)

        if let method = class_getInstanceMethod(cls, selector) {
            // App already implements it — keep its impl and wrap it.
            let old = method_setImplementation(method, newIMP)
            originalIMP = unsafeBitCast(old, to: DidRegisterIMP.self)
        } else {
            // App doesn't implement it — add ours so iOS calls it.
            class_addMethod(cls, selector, newIMP, "v@:@@")
        }
    }
}
