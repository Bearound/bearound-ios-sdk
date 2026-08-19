import Foundation
import NetworkExtension
import SystemConfiguration.CaptiveNetwork

/// Collects the Wi-Fi access point the device is joined to.
///
/// **iOS gives us one access point, not a list.** There is no public API for scanning
/// neighbouring networks — `NEHotspotHelper` is reserved for hotspot-provider apps and
/// nothing else enumerates the air. So where Android draws the map, iOS confirms a point on
/// it: "this device is on this access point right now". One vote per device, but a reliable
/// one, and at fleet scale that is what densifies the map.
///
/// Two host-app requirements, both outside the SDK's control:
///
/// - the **Access WiFi Information** capability (`com.apple.developer.networking.wifi-info`)
/// - location authorisation — When In Use is enough **while the app is in the foreground**;
///   `.always` is what keeps the access point coming once it is backgrounded. With
///   `.whenInUse` iOS returns `nil` in the background rather than an error, so the payload
///   simply arrives without Wi-Fi and nothing reports why. A fleet lives in the background,
///   so this is the difference between collecting and not collecting.
///
/// Without either, iOS returns `nil` and the SDK simply reports no Wi-Fi — every other
/// feature behaves exactly as before.
final class WifiCollector {

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
            // Deliberately nil: `NEHotspotNetwork.signalStrength` is a coarse 0…1 value that
            // measured 0 on real hardware. Publishing a fabricated dBm would poison the
            // distance estimates the backend derives from RSSI.
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
