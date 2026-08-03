import AdSupport
import AppTrackingTransparency
import Foundation
import UIKit

/// Reads the IDFA (Identifier for Advertisers) — the resettable identifier that lets the
/// same person be recognised across apps for advertising purposes.
///
/// **On iOS the identifier is gated by a user-facing prompt.** Since iOS 14.5, reading a
/// real IDFA requires App Tracking Transparency authorisation; without it the platform
/// returns an all-zero UUID.
///
/// The SDK raises that prompt itself, once, shortly after `configure()` — see
/// ``requestAuthorizationOnStart()``. Apps that need to control the moment (to show their
/// own explainer first) opt out via `configure(requestTrackingOnStart: false)` and call
/// `BeAroundSDK.shared.requestTrackingAuthorization()` when they are ready.
enum AdvertisingIdCollector {

    /// Returned by the platform when tracking is not authorised.
    private static let unauthorised = "00000000-0000-0000-0000-000000000000"

    /// - Returns: the IDFA, or `nil` when the user has not authorised tracking.
    static func current() -> String? {
        guard isAuthorised else { return nil }
        let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        return idfa == unauthorised ? nil : idfa
    }

    /// Authorisation state, reported alongside the identifier so the backend can tell a
    /// refusal apart from a prompt that was simply never shown.
    ///
    /// One of `authorized`, `denied`, `restricted`, `notDetermined` — or `unavailable` on
    /// iOS below 14, where the concept does not exist.
    static func authorizationStatus() -> String {
        guard #available(iOS 14, *) else { return "unavailable" }
        switch ATTrackingManager.trackingAuthorizationStatus {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    /// Shows the system tracking prompt if it has never been answered, and reports the
    /// resulting status. A no-op when already answered — iOS shows the dialog only once per
    /// install, and later calls return the stored decision without any UI.
    ///
    /// Requires `NSUserTrackingUsageDescription` in the host's `Info.plist`; without it iOS
    /// does not show the dialog at all.
    static func requestAuthorization(completion: ((String) -> Void)? = nil) {
        guard #available(iOS 14, *) else {
            completion?("unavailable")
            return
        }
        ATTrackingManager.requestTrackingAuthorization { _ in
            // Hop to main: hosts routinely update UI from this callback, and the framework
            // delivers it on an arbitrary queue.
            DispatchQueue.main.async {
                completion?(authorizationStatus())
            }
        }
    }

    // MARK: - Automatic prompt

    /// Raises the tracking prompt on the SDK's own initiative, once per process, as soon as
    /// the app is actually on screen.
    ///
    /// Two conditions gate it, and both matter:
    ///
    /// 1. **The host must declare `NSUserTrackingUsageDescription`.** That key is the
    ///    integrator's opt-in. An app that has not written a tracking purpose string has not
    ///    decided to collect the IDFA — and its App Store privacy label almost certainly does
    ///    not declare tracking — so the SDK stays silent rather than prompting on its behalf.
    ///    (iOS would suppress the dialog anyway; refusing early keeps the reason legible.)
    ///
    /// 2. **The app must be `.active`.** iOS silently drops the request in any other state,
    ///    leaving the status `notDetermined` forever with no dialog and no error. When the SDK
    ///    is configured before the UI is up — the common case, `configure()` inside
    ///    `didFinishLaunching`, and every background relaunch — the request is deferred to the
    ///    next `didBecomeActive` instead of being wasted.
    static func requestAuthorizationOnStart() {
        guard #available(iOS 14, *) else { return }
        guard hasUsageDescription else {
            NSLog("[BeAroundSDK] IDFA: NSUserTrackingUsageDescription ausente — prompt não exibido")
            return
        }

        DispatchQueue.main.async {
            guard !autoRequestHandled else { return }

            // Already answered: nothing to show, and nothing left to wait for.
            guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else {
                autoRequestHandled = true
                cancelPendingActivation()
                return
            }

            guard UIApplication.shared.applicationState == .active else {
                waitForActivation()
                return
            }

            autoRequestHandled = true
            cancelPendingActivation()
            requestAuthorization()
        }
    }

    /// One-shot latch so a reconfigure — or a second `configure()` after a background
    /// relaunch — never re-enters the prompt path. Main-queue confined.
    private static var autoRequestHandled = false

    private static var activationObserver: NSObjectProtocol?

    private static func waitForActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            cancelPendingActivation()
            requestAuthorizationOnStart()
        }
    }

    private static func cancelPendingActivation() {
        guard let observer = activationObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        activationObserver = nil
    }

    /// Whether the host app declared a tracking purpose string. Empty or whitespace-only
    /// counts as absent — iOS rejects those too.
    private static var hasUsageDescription: Bool {
        guard let text = Bundle.main.object(
            forInfoDictionaryKey: "NSUserTrackingUsageDescription"
        ) as? String else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static var isAuthorised: Bool {
        guard #available(iOS 14, *) else {
            // Before iOS 14 the IDFA was governed by "Limit Ad Tracking", which
            // `isAdvertisingTrackingEnabled` reports.
            return ASIdentifierManager.shared().isAdvertisingTrackingEnabled
        }
        return ATTrackingManager.trackingAuthorizationStatus == .authorized
    }
}
