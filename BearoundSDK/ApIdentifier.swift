import CryptoKit
import Foundation

/// Canonical, privacy-preserving identifier for a Wi-Fi access point.
///
/// The raw BSSID (the access point's MAC address) never leaves the device — only this
/// hash does. Two properties make it work:
///
/// 1. **Deterministic across platforms.** iOS reports the address without leading zeros
///    (`b8:1e:61:0:95:e`) while Android keeps them (`b8:1e:61:00:95:0e`). Hashing the raw
///    strings would give one physical router two different identities and the access-point
///    map would never converge. Canonical form fixes that: each octet left-padded to two
///    hex digits, lowercased, joined without separators.
///
/// 2. **Deterministic across devices.** No salt, on purpose — two phones that see the same
///    router must produce the same `apId`, otherwise cross-device correlation (the whole
///    point of the map) is impossible. This is pseudonymisation, not anonymisation, and it
///    is a conscious trade-off.
///
/// Verified on-device: `b8:1e:61:0:95:e` (iOS) and `b8:1e:61:00:95:0e` (Android) both
/// produce `2dc5d7448d0b3ef4`. **This contract must never drift from the Android
/// implementation** — if it does, every access point already mapped becomes unreachable.
enum ApIdentifier {

    /// BSSIDs the platform hands back when it will not tell us the real one — a missing
    /// entitlement, a disconnected interface, or a broadcast address. Hashing them would
    /// create a phantom access point shared by every device in that state.
    private static let placeholders: Set<String> = [
        "020000000000",
        "000000000000",
        "ffffffffffff",
    ]

    /// - Returns: the 16-hex-character identifier, or `nil` when `bssid` is absent,
    ///            malformed, or one of the platform placeholders.
    static func from(_ bssid: String?) -> String? {
        guard let raw = bssid?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }

        let octets = raw.replacingOccurrences(of: "-", with: ":").split(
            separator: ":", omittingEmptySubsequences: false
        )
        guard octets.count == 6 else { return nil }

        var canonical = ""
        canonical.reserveCapacity(12)
        for octet in octets {
            guard !octet.isEmpty, octet.count <= 2 else { return nil }
            let padded = String(repeating: "0", count: 2 - octet.count) + octet.lowercased()
            guard padded.allSatisfy({ $0.isHexDigit }) else { return nil }
            canonical += padded
        }

        guard !placeholders.contains(canonical) else { return nil }

        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
