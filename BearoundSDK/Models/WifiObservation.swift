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
    /// Human-readable network name, reported alongside `apId`.
    ///
    /// **Consumed by the backend — keep it.** It is not a debugging leftover on its way out:
    /// the name carries information the hashed `apId` cannot, so it is part of the payload
    /// contract. (An earlier revision of this file marked it for removal; that is no longer
    /// the plan, and deleting it would take a live signal down with it.)
    ///
    /// It is personal data all the same — a network name identifies a place, and at home a
    /// household — so it ships only while the host allows Wi-Fi collection
    /// (`configure(collectWifi:)`) and is dropped with the rest of the block otherwise.
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
        // Part of the contract, not a leftover — see `ssid`.
        if let ssid { dict["ssid"] = ssid }
        return dict
    }
}
