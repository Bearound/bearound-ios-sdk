import Foundation

/// One access point seen by the device at a point in time.
///
/// **iOS reports exactly one of these — the access point the device is joined to.** There
/// is no public API for scanning neighbouring networks, so `rssi` is usually `nil` and the
/// list never grows past one entry. Android fills the same structure with the neighbours it
/// can see; the backend consumes both shapes without caring which platform produced them.
struct WifiObservation {
    /// Canonical hash of the BSSID (16 hex chars) — the identity the backend actually uses.
    let apId: String
    /// Human-readable network name.
    ///
    /// **Temporary — for validating the collection against real networks while the map is
    /// being built.** Nothing downstream consumes it: `apId` is the identity. Remove this
    /// property, its sibling `UserDevice.wifiSSID`, and both payload fields once the
    /// collection is trusted — a network name identifies a household, so it should not
    /// outlive its debugging purpose.
    let ssid: String?
    /// Signal strength in dBm. Almost always `nil` on iOS — the platform exposes only a
    /// coarse 0…1 value that proved unreliable in practice, and publishing a fabricated
    /// dBm would poison distance estimates downstream.
    let rssi: Int?
    /// Whether this is the access point the device is joined to. Always `true` on iOS.
    let connected: Bool
    /// Channel frequency. Always `nil` on iOS — not exposed by the platform.
    let frequencyMhz: Int?
    /// Epoch millis of the observation itself, not of the payload.
    let timestamp: Int

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "apId": apId,
            "connected": connected,
            "timestamp": timestamp,
        ]
        if let rssi { dict["rssi"] = rssi }
        if let frequencyMhz { dict["frequencyMhz"] = frequencyMhz }
        // Temporary, for validating the collection — see `ssid`.
        if let ssid { dict["ssid"] = ssid }
        return dict
    }
}
