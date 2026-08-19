//
//  DataCollectionPolicy.swift
//  BearoundSDK
//

import Foundation

/// What the host app allows the SDK to collect and upload.
///
/// Three signals in the payload describe the *person* rather than the sighting — the
/// advertising identifier, the device's own coordinates, and the Wi-Fi access points around
/// it. An app may already collect them for its own purposes and still not want them shared
/// with Bearound: a different legal basis, a privacy label it does not want to extend, or a
/// client policy that simply says no.
///
/// Each switch is **collect-and-send**, not send-only: a disabled signal is never read from
/// the platform in the first place, so nothing to withhold ever exists in memory. Turning
/// ``advertisingId`` off also keeps the SDK from raising the App Tracking Transparency
/// prompt on the host's behalf.
///
/// Every switch defaults to `true`, so an integration that does not mention them behaves
/// exactly as it does today.
///
/// - Important: none of these switches stop beacon detection. CoreLocation region monitoring
///   keeps running when ``location`` is off — that is the wake-up mechanism, not a data
///   source; the SDK simply stops reporting *where* the device is.
public struct DataCollectionPolicy: Equatable {
    /// IDFA (and the ATT prompt raised by the SDK). Off: `permissions.advertisingId` and
    /// `permissions.trackingAuthorization` are absent from every payload, and the SDK never
    /// shows the tracking prompt — not on start, not through
    /// ``BeAroundSDK/requestTrackingAuthorization(completion:)``.
    public let advertisingId: Bool

    /// The device's own fix. Off: the `location` block is absent from every payload. The
    /// `permissions.location` / `permissions.locationAccuracy` fields stay — they report the
    /// authorisation the user granted, not where they are, and the backend needs them to
    /// explain missing data.
    public let location: Bool

    /// Access points seen around the device. Off: the `wifis` array and the
    /// `network.apId` / `network.wifiSSID` fields are absent from every payload, and the
    /// Wi-Fi read is never issued.
    public let wifi: Bool

    public init(advertisingId: Bool = true, location: Bool = true, wifi: Bool = true) {
        self.advertisingId = advertisingId
        self.location = location
        self.wifi = wifi
    }

    /// Everything on — the behaviour of every SDK version before this switch existed.
    public static let allEnabled = DataCollectionPolicy()
}

/// Process-wide holder for the active policy.
///
/// Global on purpose: the policy has to be honoured by every collector, including the one
/// inside `ErrorReporter`, which builds its device snapshot on a path that never sees the
/// `SDKConfiguration`. A single guarded value is what keeps a disabled signal disabled on
/// *all* of them — threading the config through each construction site would leave the next
/// collector free to forget.
///
/// Defaults to ``DataCollectionPolicy/allEnabled`` so a payload built before `configure()`
/// (or by a host that never touches these switches) is unchanged.
enum DataCollectionPolicyStore {
    private static let lock = NSLock()
    private static var policy = DataCollectionPolicy.allEnabled

    static var current: DataCollectionPolicy {
        lock.lock()
        defer { lock.unlock() }
        return policy
    }

    static func apply(_ newPolicy: DataCollectionPolicy) {
        lock.lock()
        policy = newPolicy
        lock.unlock()

        if newPolicy != .allEnabled {
            NSLog(
                "[BeAroundSDK] Data collection policy: advertisingId=%@ location=%@ wifi=%@",
                newPolicy.advertisingId ? "on" : "OFF",
                newPolicy.location ? "on" : "OFF",
                newPolicy.wifi ? "on" : "OFF"
            )
        }
    }

    /// Test hook — restores the default so one test's policy cannot leak into the next.
    static func reset() {
        apply(.allEnabled)
    }
}
