import Foundation

/// One access point seen by the device at a point in time.
///
/// Carries no network name: `apId` is a one-way hash of the BSSID, so the payload never
/// reveals which network the user is on.
///
/// **iOS reports exactly one of these — the access point the device is joined to.** There
/// is no public API for scanning neighbouring networks, so `rssi` is usually `nil` and the
/// list never grows past one entry. Android fills the same structure with the neighbours it
/// can see; the backend consumes both shapes without caring which platform produced them.
struct WifiObservation {
    /// Canonical hash of the BSSID (16 hex chars).
    let apId: String
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
        return dict
    }
}
