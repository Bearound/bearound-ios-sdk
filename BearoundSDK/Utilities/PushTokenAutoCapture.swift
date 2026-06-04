//
//  PushTokenAutoCapture.swift
//  BearoundSDK
//
//  Created by Bearound on 02/06/26.
//

import Foundation
import UIKit
import ObjectiveC.runtime

private typealias DidRegisterIMP = @convention(c) (Any, Selector, UIApplication, NSData) -> Void
private typealias DidReceiveIMP = @convention(c)
    (Any, Selector, UIApplication, NSDictionary, @escaping (UIBackgroundFetchResult) -> Void) -> Void

/// Swizzles the host's `UIApplicationDelegate` to auto-capture the APNs token and handle Bearound
/// silent pushes. Opt out via `BearoundAppDelegateProxyEnabled = NO` in Info.plist.
enum PushTokenAutoCapture {
    private static var installed = false
    private static var originalRegisterIMP: DidRegisterIMP?
    private static var originalReceiveIMP: DidReceiveIMP?

    private static let registerSelector =
        #selector(UIApplicationDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:))
    private static let receiveSelector =
        #selector(UIApplicationDelegate.application(_:didReceiveRemoteNotification:fetchCompletionHandler:))

    static func enableIfPossible() {
        guard !installed else { return }

        if let enabled = Bundle.main.object(forInfoDictionaryKey: "BearoundAppDelegateProxyEnabled") as? Bool,
           enabled == false {
            NSLog("[BeAroundSDK] AppDelegate proxy disabled (BearoundAppDelegateProxyEnabled=NO) — wire push manually")
            return
        }

        installed = true
        DispatchQueue.main.async {
            installSwizzles()
            UIApplication.shared.registerForRemoteNotifications()
            NSLog("[BeAroundSDK] Auto push capture enabled; requested APNs registration")
        }
    }

    private static func installSwizzles() {
        guard let delegate = UIApplication.shared.delegate else {
            NSLog("[BeAroundSDK] No UIApplicationDelegate — cannot auto-wire push (use setPushToken / forward manually)")
            return
        }
        let cls: AnyClass = type(of: delegate)
        installRegisterSwizzle(on: cls)
        installReceiveSwizzle(on: cls)
    }

    // MARK: - Token capture

    private static func installRegisterSwizzle(on cls: AnyClass) {
        let block: @convention(block) (Any, UIApplication, NSData) -> Void = { receiver, application, deviceToken in
            let token = (deviceToken as Data).map { String(format: "%02x", $0) }.joined()
            NSLog("[BeAroundSDK] APNs token captured automatically (%d bytes)", (deviceToken as Data).count)
            PushTokenStore.setToken(token)
            originalRegisterIMP?(receiver, registerSelector, application, deviceToken)
        }
        let newIMP = imp_implementationWithBlock(block)
        if let method = class_getInstanceMethod(cls, registerSelector) {
            originalRegisterIMP = unsafeBitCast(method_setImplementation(method, newIMP), to: DidRegisterIMP.self)
        } else {
            class_addMethod(cls, registerSelector, newIMP, "v@:@@")
        }
    }

    // MARK: - Silent push handling

    private static func installReceiveSwizzle(on cls: AnyClass) {
        let block: @convention(block)
            (Any, UIApplication, NSDictionary, @escaping (UIBackgroundFetchResult) -> Void) -> Void = {
                receiver, application, userInfo, completionHandler in

                // Only handle our pushes; pass others through to the app's handler.
                guard userInfo["bearound"] != nil else {
                    if let original = originalReceiveIMP {
                        original(receiver, receiveSelector, application, userInfo, completionHandler)
                    } else {
                        completionHandler(.noData)
                    }
                    return
                }

                NSLog("[BeAroundSDK] Bearound silent push received — refreshing scan + sync")
                BeAroundSDK.shared.performBackgroundBLERefreshAndSync(bleScanDuration: 10.0, trigger: "silent_push") { ingestStarted in
                    let info = BeAroundSDK.shared.lastBackgroundScanInfo
                    let found = info?.beaconsFound ?? 0
                    let pending = info?.pendingBatches ?? 0
                    NSLog("[BeAroundSDK] Bearound push handled (beacons=%d, ingestStarted=%d)", found, ingestStarted ? 1 : 0)
                    DispatchQueue.main.async {
                        BeAroundSDK.shared.delegate?.didCompletePushScan(
                            beaconsFound: found, ingestStarted: ingestStarted, pendingBatches: pending
                        )
                    }
                    completionHandler(ingestStarted ? .newData : .noData)
                }
            }
        let newIMP = imp_implementationWithBlock(block)
        if let method = class_getInstanceMethod(cls, receiveSelector) {
            originalReceiveIMP = unsafeBitCast(method_setImplementation(method, newIMP), to: DidReceiveIMP.self)
        } else {
            class_addMethod(cls, receiveSelector, newIMP, "v@:@@@?")
        }
    }
}
