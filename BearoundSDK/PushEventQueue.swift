//
//  PushEventQueue.swift
//  BearoundSDK
//
//  Persisted queue for push receipt/open events (REQ-025, REQ-026). Separate from
//  `OfflineBatchStorage` (which only ever carries beacon batches): this queue carries
//  `{sid, type, occurredAt}` entries reported to `POST {ingest}/push-events`.
//
//  Golden rules (parity with ErrorReporter's transport):
//    1. Fire-and-forget best-effort delivery; NEVER throw, NEVER block the host.
//    2. Own isolated transport, short timeout.
//    3. Survives cold launch (a notification tap can launch the app before `configure()`
//       runs) via UserDefaults persistence, drained once the business token is known.
//

import Foundation

/// Kind of push event tracked by the queue.
enum PushEventType: String, Codable {
    case received
    case opened
}

/// A single push event pending delivery to `/push-events`.
struct PushEventEntry: Codable, Equatable {
    let sid: String
    let type: PushEventType
    let occurredAt: Date
    var attempt: Int
}

/// Parses the `bearound` marker out of a remote-notification `userInfo` dictionary.
/// Tolerates both the object shape (APNs top-level `bearound: {...}`) and a JSON-string
/// shape (some bridges/legacy paths stringify it), matching the FCM `data.bearound` convention.
enum PushMarker {
    /// Returns the marker's `sid`, or nil if the marker is absent, malformed, or has no `sid`.
    /// No `sid` means nothing is reported (REQ-018/REQ-019: sync/silent pushes have no `sid`).
    static func extractSid(from userInfo: [AnyHashable: Any]) -> String? {
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

        guard let sid = marker?["sid"] as? String, !sid.isEmpty else { return nil }
        return sid
    }
}

/// Delivery outcome for one push-events request (REQ-026).
enum PushEventDeliveryOutcome {
    /// 202 or any 4xx other than 429: drop the batch, do not retry.
    case drain
    /// 5xx, 429, or a transport error: keep the batch, retry with backoff.
    case keep
}

/// Isolated transport used by `PushEventQueue`. Abstracted so tests can inject a fake
/// without a real network round trip (parity with the "test doubles for each response
/// class" requirement, REQ-026).
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
                // Any 4xx other than 429: drop, do not retry (REQ-026).
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

    // MARK: - Configuration (REQ-025)

    private static let maxEntries = 200
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    private static let maxBatchSize = 50
    private static let requestTimeout: TimeInterval = 5
    private static let path = "/push-events"
    private static let defaultSuiteName = "com.bearound.sdk.pushevents"
    private static let storageKey = "queue"
    private static let baseRetryDelay: TimeInterval = 2

    /// UserDefaults suite name. Injectable so each test isolates its own persisted queue
    /// (production always uses the default suite), avoiding the shared-state flakiness
    /// that a single suite would cause across parallel tests.
    private let suiteName: String

    private let lock = NSLock()

    /// Business token used as the `Authorization` header. Empty until `install(...)` runs;
    /// a cold-launch tap enqueues before that and the entries simply wait for install.
    private var businessToken: String = ""
    private var apiBaseURL: String = "https://ingest.bearound.io"
    private var sdkVersion: String = BeAroundSDK.version
    private var appId: String = Bundle.main.bundleIdentifier ?? "unknown"

    /// Local dedupe of `(sid, type)` seen in this process, so a delegate double-fire
    /// (e.g. willPresent + didReceive, or two lifecycle callbacks) never enqueues twice
    /// even across a flush that already drained the persisted entry.
    private var seen = Set<String>()

    /// Injectable so tests can fake each response class (202/4xx/429/5xx/transport error)
    /// without a real network call. Production uses `URLSessionPushEventTransport`.
    var transport: PushEventTransport

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    init(transport: PushEventTransport = URLSessionPushEventTransport(), suiteName: String = PushEventQueue.defaultSuiteName) {
        self.transport = transport
        self.suiteName = suiteName
    }

    // MARK: - Install

    /// Wires the business token/base URL used to deliver queued events. Safe to call
    /// repeatedly (configure() and autoConfigureFromStorage() both call it); each call
    /// also attempts to flush whatever is already queued (e.g. a cold-launch tap that
    /// enqueued before the token was known).
    func install(businessToken: String, apiBaseURL: String? = nil, sdkVersion: String? = nil) {
        lock.lock()
        self.businessToken = businessToken
        if let apiBaseURL, !apiBaseURL.isEmpty { self.apiBaseURL = apiBaseURL }
        if let sdkVersion, !sdkVersion.isEmpty { self.sdkVersion = sdkVersion }
        self.appId = Bundle.main.bundleIdentifier ?? "unknown"
        lock.unlock()

        flush()
    }

    // MARK: - Enqueue (REQ-018, REQ-019)

    /// Enqueues a push event and attempts immediate delivery. No-op if `(sid, type)`
    /// was already enqueued (or drained) in this process.
    func enqueue(sid: String, type: PushEventType, occurredAt: Date = Date()) {
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
            entries.append(PushEventEntry(sid: sid, type: type, occurredAt: occurredAt, attempt: 0))
        }
        entries = PushEventQueue.evictStale(entries)
        saveEntries(entries)
        lock.unlock()

        flush()
    }

    // MARK: - Eviction (REQ-025)

    /// Applies the 7-day age cap, then the 200-entry cap (oldest dropped first).
    private static func evictStale(_ entries: [PushEventEntry]) -> [PushEventEntry] {
        let cutoff = Date().addingTimeInterval(-maxAge)
        var result = entries.filter { $0.occurredAt >= cutoff }
        if result.count > maxEntries {
            result = Array(result.suffix(maxEntries))
        }
        return result
    }

    // MARK: - Flush / transport (REQ-026)

    /// Attempts to deliver the persisted queue in batches of at most 50 events.
    /// Best-effort: never throws, never blocks the caller (network calls are async).
    func flush() {
        lock.lock()
        let token = businessToken
        guard !token.isEmpty else {
            // Not configured yet (cold-launch tap before `configure()`); entries stay
            // persisted and will flush on the next `install(...)` or `enqueue(...)`.
            lock.unlock()
            return
        }
        let entries = loadEntries()
        lock.unlock()

        guard !entries.isEmpty else { return }

        let batch = Array(entries.prefix(PushEventQueue.maxBatchSize))
        send(batch: batch, token: token)
    }

    private func send(batch: [PushEventEntry], token: String) {
        guard let request = makeRequest(batch: batch, token: token) else { return }

        transport.send(request: request) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .drain:
                self.drain(batch)
            case .keep:
                self.keepAndBackoff(batch)
            }
        }
    }

    private func drain(_ batch: [PushEventEntry]) {
        lock.lock()
        var entries = loadEntries()
        let drainedKeys = Set(batch.map { "\($0.sid)|\($0.type.rawValue)" })
        entries.removeAll { drainedKeys.contains("\($0.sid)|\($0.type.rawValue)") }
        saveEntries(entries)
        lock.unlock()
    }

    private func keepAndBackoff(_ batch: [PushEventEntry]) {
        lock.lock()
        var entries = loadEntries()
        for sent in batch {
            if let idx = entries.firstIndex(where: { $0.sid == sent.sid && $0.type == sent.type }) {
                entries[idx].attempt += 1
            }
        }
        saveEntries(entries)
        let nextAttempt = batch.map { $0.attempt + 1 }.max() ?? 1
        lock.unlock()

        let delay = min(PushEventQueue.baseRetryDelay * pow(2, Double(nextAttempt - 1)), 300)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flush()
        }
    }

    // MARK: - Request building

    private func makeRequest(batch: [PushEventEntry], token: String) -> URLRequest? {
        lock.lock()
        let base = apiBaseURL
        let version = sdkVersion
        let app = appId
        lock.unlock()

        guard let url = URL(string: "\(base)\(PushEventQueue.path)") else { return nil }

        let events = batch.map { entry -> [String: Any] in
            [
                "sid": entry.sid,
                "type": entry.type.rawValue,
                "occurredAt": iso.string(from: entry.occurredAt),
            ]
        }

        let payload: [String: Any] = [
            "events": events,
            "device": [
                "deviceId": DeviceIdentifier.getDeviceId(),
                "platform": "ios",
            ],
            "sdk": [
                "version": version,
                "platform": "ios",
                "appId": app,
            ],
        ]

        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.httpBody = body
        request.timeoutInterval = PushEventQueue.requestTimeout
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
        defaults?.removeObject(forKey: PushEventQueue.storageKey)
        businessToken = ""
        lock.unlock()
    }

    /// Snapshot of the persisted queue. Test-only.
    func entriesForTesting() -> [PushEventEntry] {
        lock.lock()
        defer { lock.unlock() }
        return loadEntries()
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
