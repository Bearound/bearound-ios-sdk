import BearoundSDK
import Foundation

/// App lifecycle context in which a beacon detection was captured.
/// `terminated` means iOS relaunched the process after it was force-quit / killed —
/// the detection happened while the app was, from the user's point of view, "dead".
enum DetectionMode: String, Codable, CaseIterable {
    case foreground
    case background
    case backgroundLocked
    case terminated
}

struct DetectionLogEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let major: Int
    let minor: Int
    let rssi: Int
    let proximity: String
    let mode: DetectionMode
    let discoverySource: String
    let beaconUUID: String

    var isBackground: Bool { mode == .background || mode == .backgroundLocked }
    var isLocked: Bool { mode == .backgroundLocked }
    var isTerminated: Bool { mode == .terminated }
}

extension DetectionLogEntry {
    static func from(beacon: Beacon, mode: DetectionMode) -> DetectionLogEntry {
        let proximityText: String = switch beacon.proximity {
        case .immediate: "Imediato"
        case .near: "Perto"
        case .far: "Longe"
        case .bt: "Bluetooth"
        case .unknown: "Desconhecido"
        }

        let sourceText: String
        let hasSU = beacon.discoverySources.contains(.serviceUUID)
        let hasCL = beacon.discoverySources.contains(.coreLocation)
        if hasSU && hasCL {
            sourceText = "Both"
        } else if hasSU {
            sourceText = "Service UUID"
        } else if hasCL {
            sourceText = "iBeacon"
        } else {
            sourceText = "Name"
        }

        return DetectionLogEntry(
            id: UUID(),
            timestamp: Date(),
            major: beacon.major,
            minor: beacon.minor,
            rssi: beacon.rssi,
            proximity: proximityText,
            mode: mode,
            discoverySource: sourceText,
            beaconUUID: beacon.uuid.uuidString
        )
    }
}
