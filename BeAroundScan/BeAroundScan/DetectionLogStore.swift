import Foundation

/// Disk persistence for the detection log, so detections captured while the app was
/// killed/terminated (and relaunched in background by iOS) survive the next process death.
/// Stored as a single JSON file in Application Support. Each mode is capped so the file
/// stays small enough to encode/write quickly inside the ~25s terminated-relaunch window.
enum DetectionLogStore {
    private static let maxPersistedPerMode = 500
    private static let fileName = "detection_log.json"

    struct Snapshot: Codable {
        var foreground: [DetectionLogEntry] = []
        var background: [DetectionLogEntry] = []
        var backgroundLocked: [DetectionLogEntry] = []
        var terminated: [DetectionLogEntry] = []
    }

    private static var fileURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return dir.appendingPathComponent(fileName)
    }

    static func load() -> Snapshot {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return Snapshot()
        }
        return snapshot
    }

    static func save(
        foreground: [DetectionLogEntry],
        background: [DetectionLogEntry],
        backgroundLocked: [DetectionLogEntry],
        terminated: [DetectionLogEntry]
    ) {
        guard let url = fileURL else { return }
        let snapshot = Snapshot(
            foreground: Array(foreground.prefix(maxPersistedPerMode)),
            background: Array(background.prefix(maxPersistedPerMode)),
            backgroundLocked: Array(backgroundLocked.prefix(maxPersistedPerMode)),
            terminated: Array(terminated.prefix(maxPersistedPerMode))
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
