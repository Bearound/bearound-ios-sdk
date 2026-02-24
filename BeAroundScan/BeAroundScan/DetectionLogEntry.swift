import BearoundSDK
import Foundation

struct DetectionLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let major: Int
    let minor: Int
    let rssi: Int
    let proximity: String
    let isBackground: Bool
    let isLocked: Bool
    let discoverySource: String
    let beaconUUID: String
}

extension DetectionLogEntry {
    static func from(beacon: Beacon, isBackground: Bool, isLocked: Bool) -> DetectionLogEntry {
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
            timestamp: Date(),
            major: beacon.major,
            minor: beacon.minor,
            rssi: beacon.rssi,
            proximity: proximityText,
            isBackground: isBackground,
            isLocked: isLocked,
            discoverySource: sourceText,
            beaconUUID: beacon.uuid.uuidString
        )
    }
}
