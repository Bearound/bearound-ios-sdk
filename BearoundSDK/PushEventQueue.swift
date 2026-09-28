//
//  PushEventQueue.swift
//  BearoundSDK
//
//  Persisted queue for push receipt/open hits. Separate from
//  `OfflineBatchStorage` (which only ever carries beacon batches). Each entry is one
//  tracker hit, `GET {tr}/v1/push:{received|open}?d={d}`, where `d` and `tr` come from
//  the push's `bearound` marker.
//  The hit carries no credential: `d` is the delivery context the API sealed for this
//  device, so the queue does not need the business token and can flush at any time.
//
//  Golden rules (parity with ErrorReporter's transport):
//    1. Fire-and-forget best-effort delivery; NEVER throw, NEVER block the host.
//    2. Own isolated transport, short timeout.
//    3. Survives cold launch (a notification tap can launch the app before `configure()`
//       runs) via UserDefaults persistence.
//

import Foundation

/// Kind of push event tracked by the queue.
enum PushEventType: String, Codable {
    case received
    case opened

    /// The tracker verb: `/v1/push:received`, `/v1/push:open`.
    var verb: String {
        switch self {
        case .received: return "received"
        case .opened: return "open"
        }
    }
}

/// A measurable Bearound marker: the send id, the delivery context and the tracker base.
struct PushMarkerValue: Equatable {
    let sid: String
    let d: String
    let tr: String
}

/// A single tracker hit pending delivery.
struct PushEventEntry: Codable, Equatable {
    let sid: String
    let type: PushEventType
    let occurredAt: Date
    var attempt: Int
    let d: String
    let tr: String
    /// Not before this instant after a failed attempt (backoff). Nil = due now.
    var nextAttemptAt: Date? = nil
}

/// Parses the `bearound` marker out of a remote-notification `userInfo` dictionary.
/// Tolerates both the object shape (APNs top-level `bearound: {...}`) and a JSON-string
/// shape (some bridges/legacy paths stringify it), matching the FCM `data.bearound` convention.
enum PushMarker {
    /// Returns the marker when it is measurable: `sid`, `d` and an https `tr` all present.
    /// Anything else (sync pushes carry only `t`, a server without the proof key sends no
    /// `d`) reports nothing.
    static func extract(from userInfo: [AnyHashable: Any]) -> PushMarkerValue? {
        guard let marker = markerDictionary(from: userInfo),
              let sid = marker["sid"] as? String, !sid.isEmpty,
              let d = marker["d"] as? String, !d.isEmpty,
              let tr = marker["tr"] as? String, tr.lowercased().hasPrefix("https://")
        else { return nil }
        return PushMarkerValue(sid: sid, d: d, tr: tr)
    }

    private static func markerDictionary(from userInfo: [AnyHashable: Any]) -> [String: Any]? {
        guard let raw = userInfo["bearound"] else { return nil }

        let marker: [String: Any]?
        if let dict = raw as? [String: Any] {
            marker = dict
        } else if let jsonString = raw as? String,
                  let data = jsonString.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            marker = decoded
        } else {
            marker = nil
        }
        return marker
    }
}

/// Delivery outcome for one tracker hit.
enum PushEventDeliveryOutcome {
    /// 2xx or any 4xx other than 429: drop the entry, do not retry.
    case drain
    /// 5xx, 429, or a transport error: keep the entry, retry with backoff.
    case keep
}

/// Isolated transport used by `PushEventQueue`. Abstracted so tests can inject a fake
/// without a real network round trip (parity with the "test doubles for each response
/// class" requirement).
protocol PushEventTransport {
    func send(request: URLRequest, completion: @escaping (PushEventDeliveryOutcome) -> Void)
}

/// Default transport: an isolated ephemeral `URLSession`, short timeout (parity with
/// `ErrorReporter`'s transport).
final class URLSessionPushEventTransport: PushEventTransport {
    private static let requestTimeout: TimeInterval = 5

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.timeoutIntervalForResource = Self.requestTimeout
        config.waitsForConnectivity = false
        config.allowsCellularAccess = true
        return URLSession(configuration: config)
    }()

    func send(request: URLRequest, completion: @escaping (PushEventDeliveryOutcome) -> Void) {
        let task = session.dataTask(with: request) { _, response, error in
            if error != nil {
                completion(.keep)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.keep)
                return
            }
            switch http.statusCode {
            case 200..<300:
                completion(.drain)
            case 429:
                completion(.keep)
            case 400..<500:
                // Any 4xx other than 429: drop, do not retry.
                completion(.drain)
            default:
                // 5xx and anything else unexpected: keep for retry.
                completion(.keep)
            }
        }
        task.resume()
    }
}

/// Persisted, deduped, capped queue of push receipt/open events with best-effort
/// immediate delivery and exponential-backoff retry.
///
/// Thread-safety: every public entry point synchronizes on `lock`.
final class PushEventQueue {

    static let shared = PushEventQueue()

    // MARK: - Configuration

    private static let maxEntries = 200
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// Hits sent per flush; the rest wait for the next one.
    private static let maxBatchSize = 50
    private static let requestTimeout: TimeInterval = 5
    private static let defaultSuiteName = "com.bearound.sdk.pushevents"
    private static let storageKey = "queue"
    private static let baseRetryDelay: TimeInterval = 2

    /// UserDefaults suite name. Injectable so each test isolates its own persisted queue
    /// (production always uses the default suite), avoiding the shared-state flakiness
    /// that a single suite would cause across parallel tests.
    private let suiteName: String

    private let lock = NSLock()

    /// Local dedupe of `(sid, type)` seen in this process, so a delegate double-fire
    /// (e.g. willPresent + didReceive, or two lifecycle callbacks) never enqueues twice
    /// even across a flush that already drained the persisted entry.
    private var seen = Set<String>()

    /// Keys `(sid|type)` with a request on the wire. `flush()` skips them, so two
    /// flushes close together (enqueue of `opened` then `received`, or configure)
    /// never send the same hit twice.
    private var inFlight = Set<String>()

    /// At most one pending backoff flush at any time: failed entries carry their
    /// own `nextAttemptAt`, and one timer wakes up for the earliest of them.
    private var retryScheduled = false

    /// Injectable so tests can fake each response class (202/4xx/429/5xx/transport error)
    /// without a real network call. Production uses `URLSessionPushEventTransport`.
    var transport: PushEventTransport

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    init(transport: PushEventTransport = URLSessionPushEventTransport(), suiteName: String = PushEventQueue.defaultSuiteName) {
        self.transport = transport
        self.suiteName = suiteName
    }

    // MARK: - Enqueue

    /// Enqueues a tracker hit and attempts immediate delivery. No-op if `(sid, type)`
    /// was already enqueued (or drained) in this process.
    func enqueue(marker: PushMarkerValue, type: PushEventType, occurredAt: Date = Date()) {
        let sid = marker.sid
        let dedupeKey = "\(sid)|\(type.rawValue)"

        lock.lock()
        if seen.contains(dedupeKey) {
            lock.unlock()
            return
        }
        seen.insert(dedupeKey)

        var entries = loadEntries()
        let alreadyPersisted = entries.contains { $0.sid == sid && $0.type == type }
        if !alreadyPersisted {
            entries.append(PushEventEntry(sid: sid, type: type, occurredAt: occurredAt, attempt: 0, d: marker.d, tr: marker.tr))
        }
        entries = PushEventQueue.evictStale(entries)
        saveEntries(entries)
        lock.unlock()

        flush()
    }

    // MARK: - Eviction

    /// Applies the 7-day age cap, then the 200-entry cap (oldest dropped first).
    private static func evictStale(_ entries: [PushEventEntry]) -> [PushEventEntry] {
        let cutoff = Date().addingTimeInterval(-maxAge)
        var result = entries.filter { $0.occurredAt >= cutoff }
        if result.count > maxEntries {
            result = Array(result.suffix(maxEntries))
        }
        return result
    }

    // MARK: - Flush / transport

    /// Attempts to deliver up to 50 persisted hits, one request each.
    /// Best-effort: never throws, never blocks the caller (network calls are async).
    func flush() {
        let now = Date()
        lock.lock()
        // Age and cap apply on every flush too, not only on enqueue: a relaunch
        // must not send an entry older than 7 days.
        let entries = PushEventQueue.evictStale(loadEntries())
        saveEntries(entries)
        let due = entries
            .filter { !inFlight.contains(PushEventQueue.key($0)) && ($0.nextAttemptAt ?? .distantPast) <= now }
            .prefix(PushEventQueue.maxBatchSize)
        due.forEach { inFlight.insert(PushEventQueue.key($0)) }
        lock.unlock()

        for entry in due {
            send(entry)
        }
    }

    private func send(_ entry: PushEventEntry) {
        guard let request = makeRequest(entry) else {
            // A malformed tracker base can never succeed: drop it instead of retrying.
            drain([entry])
            return
        }

        transport.send(request: request) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .drain:
                self.drain([entry])
            case .keep:
                self.keepAndBackoff([entry])
            }
        }
    }

    private func drain(_ batch: [PushEventEntry]) {
        lock.lock()
        var entries = loadEntries()
        let drainedKeys = Set(batch.map { "\($0.sid)|\($0.type.rawValue)" })
        entries.removeAll { drainedKeys.contains("\($0.sid)|\($0.type.rawValue)") }
        saveEntries(entries)
        batch.forEach { inFlight.remove(PushEventQueue.key($0)) }
        lock.unlock()
    }

    private func keepAndBackoff(_ batch: [PushEventEntry]) {
        lock.lock()
        var entries = loadEntries()
        var earliest: Date?
        for sent in batch {
            inFlight.remove(PushEventQueue.key(sent))
            if let idx = entries.firstIndex(where: { $0.sid == sent.sid && $0.type == sent.type }) {
                entries[idx].attempt += 1
                let delay = min(PushEventQueue.baseRetryDelay * pow(2, Double(entries[idx].attempt - 1)), 300)
                let due = Date().addingTimeInterval(delay)
                entries[idx].nextAttemptAt = due
                earliest = min(earliest ?? due, due)
            }
        }
        saveEntries(entries)
        let shouldSchedule = earliest != nil && !retryScheduled
        if shouldSchedule { retryScheduled = true }
        lock.unlock()

        guard shouldSchedule, let earliest else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(earliest.timeIntervalSinceNow, 0)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.retryScheduled = false
            self.lock.unlock()
            self.flush()
        }
    }

    private static func key(_ entry: PushEventEntry) -> String {
        "\(entry.sid)|\(entry.type.rawValue)"
    }

    // MARK: - Request building

    /// `GET {tr}/v1/push:{verb}?d={d}`. No body and no Authorization: the sealed `d` is
    /// the whole proof.
    func makeRequest(_ entry: PushEventEntry) -> URLRequest? {
        let base = entry.tr.hasSuffix("/") ? String(entry.tr.dropLast()) : entry.tr
        guard var components = URLComponents(string: "\(base)/v1/push:\(entry.type.verb)") else { return nil }
        components.queryItems = [URLQueryItem(name: "d", value: entry.d)]
        guard let url = components.url, url.scheme?.lowercased() == "https" else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = PushEventQueue.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    // MARK: - Persistence

    private func loadEntries() -> [PushEventEntry] {
        guard let defaults, let data = defaults.data(forKey: PushEventQueue.storageKey) else { return [] }
        return (try? JSONDecoder().decode([PushEventEntry].self, from: data)) ?? []
    }

    private func saveEntries(_ entries: [PushEventEntry]) {
        guard let defaults else { return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: PushEventQueue.storageKey)
    }

    // MARK: - Test support

    /// Resets in-memory and persisted state. Test-only.
    func resetForTesting() {
        lock.lock()
        seen.removeAll()
        inFlight.removeAll()
        retryScheduled = false
        defaults?.removeObject(forKey: PushEventQueue.storageKey)
        lock.unlock()
    }

    /// Snapshot of the persisted queue. Test-only.
    func entriesForTesting() -> [PushEventEntry] {
        lock.lock()
        defer { lock.unlock() }
        return loadEntries()
    }

    /// Appends raw entries with NO eviction, as a queue persisted by an older run
    /// would look. Test-only.
    func injectRawForTesting(_ entries: [PushEventEntry]) {
        lock.lock()
        saveEntries(loadEntries() + entries)
        lock.unlock()
    }

    /// Directly persists raw entries (bypassing enqueue/dedupe), then applies eviction,
    /// exactly like `enqueue(...)` does. Lets cap/age eviction tests set up a queue state
    /// without needing distinct `sid`s and real wall-clock waits. Test-only.
    func seedForTesting(_ entries: [PushEventEntry]) {
        lock.lock()
        saveEntries(PushEventQueue.evictStale(entries))
        lock.unlock()
    }
}
