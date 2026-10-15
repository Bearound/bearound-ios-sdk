import CoreLocation
import Foundation
import NetworkExtension
import SystemConfiguration.CaptiveNetwork

/// Why a Wi-Fi round did or did not see an access point. Surfaced in `BeAroundDiagnostics`
/// so a host that never gets a Wi-Fi visit can tell what is missing.
enum WifiCollectorStatus: String {
    /// Joined to an access point and iOS disclosed it.
    case ready
    /// Joined to Wi-Fi, location allowed, yet iOS withheld the access point: the host app
    /// lacks `com.apple.developer.networking.wifi-info`.
    case missingEntitlement
    /// iOS only discloses the access point with location authorization.
    case locationNotAuthorized
    /// Not joined to any Wi-Fi network: a real, conclusive absence.
    case notConnected

    /// A conclusive round can contradict a match; an inconclusive one says nothing either way.
    var isConclusive: Bool { self == .ready || self == .notConnected }
}

/// The outcome of one access-point read.
struct WifiRound: Equatable {
    let status: WifiCollectorStatus
    /// The connected access point; nil unless `status == .ready`.
    let observation: WifiObservation?
}

/// Seam for the visit matcher: one fresh read, completed on the main thread.
protocol WifiRoundProviding: AnyObject {
    func fetchRound(completion: @escaping (WifiRound) -> Void)
}

/// Collects the Wi-Fi access point the device is joined to.
///
/// **iOS gives us one access point, not a list.** There is no public API for scanning
/// neighbouring networks — `NEHotspotHelper` is reserved for hotspot-provider apps and
/// nothing else enumerates the air. So on iOS the payload carries at most the one access
/// point the device is joined to.
///
/// Two host-app requirements, both outside the SDK's control:
///
/// - the **Access WiFi Information** capability (`com.apple.developer.networking.wifi-info`)
/// - location authorisation — When In Use is enough **while the app is in the foreground**;
///   `.always` is what keeps the access point coming once it is backgrounded. With
///   `.whenInUse` iOS returns `nil` in the background rather than an error, so background
///   payloads carry no Wi-Fi unless the app holds `.always`.
///
/// Without either, iOS returns `nil` and the SDK simply reports no Wi-Fi — every other
/// feature behaves exactly as before.
final class WifiCollector: WifiRoundProviding {

    private let locationAuthorized: () -> Bool
    private let isOnWifi: () -> Bool

    init(
        locationAuthorized: @escaping () -> Bool = WifiCollector.systemLocationAuthorized,
        isOnWifi: @escaping () -> Bool = { NetworkSnapshotProvider.shared.current == "wifi" }
    ) {
        self.locationAuthorized = locationAuthorized
        self.isOnWifi = isOnWifi
    }

    /// `NEHotspotNetwork.fetchCurrent` answers nil for three different reasons. This tells
    /// them apart from what the SDK can observe: the observation itself, location
    /// authorization and whether the device is joined to Wi-Fi at all.
    static func status(observation: WifiObservation?, locationAuthorized: Bool,
                       onWifi: Bool) -> WifiCollectorStatus {
        if observation != nil { return .ready }
        if !locationAuthorized { return .locationNotAuthorized }
        return onWifi ? .missingEntitlement : .notConnected
    }

    static func systemLocationAuthorized() -> Bool {
        let status: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            status = CLLocationManager().authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }
        return status == .authorizedAlways || status == .authorizedWhenInUse
    }

    /// One fresh read for the visit matcher, always completed on the main thread. Also
    /// refreshes the payload cache and records the status for the SDK diagnostics.
    func fetchRound(completion: @escaping (WifiRound) -> Void) {
        let finish: (String?, String?) -> Void = { [weak self] bssid, ssid in
            guard let self else { return }
            let observation = Self.observation(from: bssid, ssid: ssid)
            self.lock.lock()
            self.cached = observation
            self.lock.unlock()
            let status = Self.status(observation: observation, locationAuthorized: self.locationAuthorized(),
                                     onWifi: self.isOnWifi())
            DiagnosticsStore.shared.recordWifiStatus(status.rawValue)
            let round = WifiRound(status: status, observation: observation)
            if Thread.isMainThread { completion(round) } else { DispatchQueue.main.async { completion(round) } }
        }
        if #available(iOS 14.0, *) {
            NEHotspotNetwork.fetchCurrent { network in finish(network?.bssid, network?.ssid) }
        } else {
            let legacy = Self.legacyNetwork()
            finish(legacy?.bssid, legacy?.ssid)
        }
    }

    /// Cached because `fetchCurrent` is async and the payload builder is not. Refreshed
    /// opportunistically; a slightly stale access point is still the right one in the
    /// overwhelming majority of cases (people do not hop networks every few seconds).
    private var cached: WifiObservation?
    private let lock = NSLock()

    /// Kicks off a refresh of the cached access point. Cheap, non-blocking, and safe to
    /// call from anywhere — the result lands in `current()` on a later payload.
    func refresh() {
        if #available(iOS 14.0, *) {
            NEHotspotNetwork.fetchCurrent { [weak self] network in
                guard let self else { return }
                let observation = Self.observation(from: network?.bssid, ssid: network?.ssid)
                self.lock.lock()
                self.cached = observation
                self.lock.unlock()
            }
        } else {
            let legacy = Self.legacyNetwork()
            let observation = Self.observation(from: legacy?.bssid, ssid: legacy?.ssid)
            lock.lock()
            cached = observation
            lock.unlock()
        }
    }

    /// The connected network's name. Part of the payload contract — see `WifiObservation.ssid`.
    func connectedSSID() -> String? {
        lock.lock()
        let ssid = cached?.ssid
        lock.unlock()
        return ssid
    }

    /// - Returns: the access points to report. At most one on iOS; empty when the host app
    ///            lacks the entitlement or location authorisation.
    func current() -> [WifiObservation] {
        lock.lock()
        let observation = cached
        lock.unlock()
        return observation.map { [$0] } ?? []
    }

    /// The connected access point's hashed identity, for the `network` block.
    func connectedApId() -> String? {
        lock.lock()
        let apId = cached?.apId
        lock.unlock()
        return apId
    }

    // MARK: - Private

    private static func observation(from bssid: String?, ssid: String?) -> WifiObservation? {
        guard let apId = ApIdentifier.from(bssid) else { return nil }
        return WifiObservation(
            apId: apId,
            // Part of the contract, not a leftover — see WifiObservation.ssid.
            ssid: ssid,
            // Deliberately nil: `NEHotspotNetwork.signalStrength` is a coarse 0…1 value, not dBm.
            rssi: nil,
            connected: true,
            // Not exposed by iOS at all.
            frequencyMhz: nil,
            timestamp: Int(Date().timeIntervalSince1970 * 1000)
        )
    }

    /// Pre-iOS 14 path. `CNCopyCurrentNetworkInfo` is deprecated and needs the same
    /// entitlement, but it is the only option on those versions.
    private static func legacyNetwork() -> (bssid: String?, ssid: String?)? {
        guard let interfaces = CNCopySupportedInterfaces() as? [String] else { return nil }
        for interface in interfaces {
            guard let info = CNCopyCurrentNetworkInfo(interface as CFString) as NSDictionary?
            else { continue }
            let bssid = info[kCNNetworkInfoKeyBSSID as String] as? String
            let ssid = info[kCNNetworkInfoKeySSID as String] as? String
            if bssid != nil || ssid != nil {
                return (bssid, ssid)
            }
        }
        return nil
    }
}
