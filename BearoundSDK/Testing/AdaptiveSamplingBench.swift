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

    public static func counterSnapshot(completion: @escaping (Data?) -> Void) {
        guard isEnabled else { completion(nil); return }
        BeAroundSDK.shared.captureAdaptiveBenchCounters(completion: completion)
    }

    static func captureCounters(on queue: DispatchQueue, enabled: Bool,
        runtime: @escaping () -> AdaptiveSamplingRuntime?, clock: @escaping () -> SamplingClock = { .now() },
        completion: @escaping (Data?) -> Void) {
        guard enabled else { completion(nil); return }
        queue.async {
            guard let runtime = runtime() else { completion(nil); return }
            let diagnostics = runtime.diagnostics
            let payload: [String: Any] = [
                "schemaVersion": 1, "pid": ProcessInfo.processInfo.processIdentifier,
                "deviceTimestampMs": clock().wallTimeMs, "counterScope": "all_observation_bodies",
                "generation": runtime.generation, "httpAttempts": runtime.httpAttempts,
                "serializedBytes": diagnostics.serializedBytes, "uniqueSamples": diagnostics.uniqueSamples,
                "complementaryReads": diagnostics.complementaryReads,
                "complementaryCacheReads": diagnostics.complementaryCacheReads,
                "cachedCallbacks": diagnostics.cachedCallbacks, "liveAttempts": diagnostics.liveAttempts,
                "summaryAttempts": diagnostics.summaryAttempts, "transitionAttempts": diagnostics.transitionAttempts,
                "failures": diagnostics.failures, "policyDenials": diagnostics.policyDenials,
                "clockUncertainties": diagnostics.clockUncertainties,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys),
                  data.count <= 4_096 else { completion(nil); return }
            completion(data)
        }
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
