import AdSupport
import AppTrackingTransparency
import Foundation

/// Reads the IDFA (Identifier for Advertisers) — the resettable identifier that lets the
/// same person be recognised across apps for advertising purposes.
///
/// **On iOS the identifier is gated by a user-facing prompt.** Since iOS 14.5, reading a
/// real IDFA requires App Tracking Transparency authorisation; without it the platform
/// returns an all-zero UUID. This collector never shows that prompt on its own — the host
/// app decides when, through `BeAroundSDK.shared.requestTrackingAuthorization()`, because
/// Apple requires the dialog to appear in a context the user understands, and because a
/// prompt fired at an arbitrary moment is a rejected app.
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

    private static var isAuthorised: Bool {
        guard #available(iOS 14, *) else {
            // Before iOS 14 the IDFA was governed by "Limit Ad Tracking", which
            // `isAdvertisingTrackingEnabled` reports.
            return ASIdentifierManager.shared().isAdvertisingTrackingEnabled
        }
        return ATTrackingManager.trackingAuthorizationStatus == .authorized
    }
}
