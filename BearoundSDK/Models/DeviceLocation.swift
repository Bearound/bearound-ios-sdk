import CoreLocation
import Foundation

/// Where the device was, as context for the observations in the same payload.
///
/// Always the **cached** fix that CoreLocation already holds — the SDK never starts a
/// location request of its own, so this costs no extra battery and no GPS wake-up.
struct DeviceLocation {
    let latitude: Double
    let longitude: Double
    let accuracy: Double?
    let altitude: Double?
    /// Epoch millis **of the fix**, not of the payload. A cached fix can be minutes old and
    /// the backend needs to know that to weigh it.
    let timestamp: Int
    /// Which subsystem produced it. iOS does not break this down the way Android does, so
    /// it is always `"ios"` — kept for shape parity between platforms.
    let source: String

    init?(_ location: CLLocation?) {
        guard let location,
              CLLocationCoordinate2DIsValid(location.coordinate)
        else { return nil }

        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        // Negative accuracy means "invalid" in CoreLocation, not "very precise".
        accuracy = location.horizontalAccuracy > 0 ? location.horizontalAccuracy : nil
        altitude = location.verticalAccuracy > 0 ? location.altitude : nil
        timestamp = Int(location.timestamp.timeIntervalSince1970 * 1000)
        source = "ios"
    }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "latitude": latitude,
            "longitude": longitude,
            "timestamp": timestamp,
            "source": source,
        ]
        if let accuracy { dict["accuracy"] = accuracy }
        if let altitude { dict["altitude"] = altitude }
        return dict
    }
}
