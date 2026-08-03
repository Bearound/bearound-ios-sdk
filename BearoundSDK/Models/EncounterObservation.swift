import Foundation

/// One nearby SDK-carrying device, as seen over BLE during the current window.
///
/// Sightings are reported as observed — "saw `rpi` at `rssi`" — with no local matching.
/// `rpi` is the peer's rotating identifier: 16 random bytes renewed every
/// ``EncounterMeshManager/rpiRotationInterval``, so nothing stable goes on the air.
struct EncounterObservation {
    /// Peer's rotating identifier (32 lowercase hex chars) read over GATT.
    let rpi: String
    /// Most recent signal strength, in dBm.
    let rssi: Int
    /// Number of advertisements aggregated into this observation.
    let sampleCount: Int
    /// Weakest signal seen, in dBm.
    let rssiMin: Int
    /// Strongest signal seen, in dBm.
    let rssiMax: Int
    /// Mean signal across all samples, in dBm (rounded).
    let rssiAvg: Int
    /// Epoch millis of the first advertisement in this aggregate.
    let firstSeen: Int
    /// Epoch millis of the most recent advertisement.
    let lastSeen: Int

    func toDictionary() -> [String: Any] {
        [
            "rpi": rpi,
            "rssi": rssi,
            "rssiSamples": [
                "count": sampleCount,
                "min": rssiMin,
                "max": rssiMax,
                "avg": rssiAvg,
            ],
            "firstSeen": firstSeen,
            "lastSeen": lastSeen,
        ]
    }
}
