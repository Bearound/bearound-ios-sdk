#if DEBUG
import Foundation
import Network

/// Fixture injection is available only in a Debug SDK and an explicitly opted-in host.
/// HTTPS requests still use the production URLSession trust and authorization paths.
public enum AdaptiveSamplingBench {
    public static var isEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "BEAROUND_ADAPTIVE_BENCH") as? Bool == true && endpoint != nil
    }

    static var endpoint: String? {
        guard Bundle.main.object(forInfoDictionaryKey: "BEAROUND_ADAPTIVE_BENCH") as? Bool == true, let value = Bundle.main.object(forInfoDictionaryKey: "BEAROUND_ADAPTIVE_BENCH_ENDPOINT") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return validatedEndpoint(value)
    }

    static func validatedEndpoint(_ value: String?) -> String? {
        guard let value, let url = URL(string: value), url.scheme == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", url.port.map({ (1...65_535).contains($0) }) ?? true else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let privateV4: Bool = {
            guard labels.count == 4 else { return false }
            var octets: [UInt8] = []
            for label in labels {
                guard !label.isEmpty, label.utf8.allSatisfy({ (48...57).contains($0) }),
                      label.count == 1 || label.first != "0", let octet = UInt8(label) else { return false }
                octets.append(octet)
            }
            return octets[0] == 10 || octets[0] == 127 || octets[0] == 192 && octets[1] == 168
                || octets[0] == 172 && (16...31).contains(octets[1])
        }()
        let localDNS = (host == "localhost" || host.hasSuffix(".local")) && host.utf8.count <= 253
            && labels.allSatisfy { label in
                !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }
            }
        let literal = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        let address = IPv6Address(literal)
        let privateV6 = address.map { $0.isLoopback || $0.isLinkLocal || $0.rawValue.first.map { $0 & 0xfe == 0xfc } == true } ?? false
        guard localDNS || privateV4 || privateV6 else { return nil }
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
