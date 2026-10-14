#if DEBUG
import Foundation

/// Fixture injection is available only in a Debug SDK and an explicitly opted-in host.
/// HTTPS requests still use the production URLSession trust and authorization paths.
public enum AdaptiveSamplingBench {
    public static var isEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "BEAROUND_ADAPTIVE_BENCH") as? Bool == true
    }

    static var endpoint: String? {
        guard isEnabled, let value = Bundle.main.object(forInfoDictionaryKey: "BEAROUND_ADAPTIVE_BENCH_ENDPOINT") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public static func injectBeacon(major: Int, minor: Int, rssi: Int, observedAt: Date, physical: Bool = true) {
        guard isEnabled, (0 ... 65_535).contains(major), (0 ... 65_535).contains(minor), (-127 ... 0).contains(rssi) else { return }
        BeAroundSDK.shared.injectAdaptiveBenchBeacon(Beacon(uuid: BeaconConstants.uuid, major: major,
            minor: minor, rssi: rssi, proximity: .bt, accuracy: -1, timestamp: observedAt), physical: physical)
    }

    public static func closeWindow() {
        guard isEnabled else { return }
        BeAroundSDK.shared.closeAdaptiveBenchWindow()
    }
}
#endif
