import BearoundSDK
import Combine
import CoreBluetooth
import CoreLocation
import SwiftUI
import UserNotifications

#if DEBUG && BEAROUND_ADAPTIVE_BENCH && !BEAROUND_ADAPTIVE_BASELINE
import CryptoKit
import Security
#endif

#if DEBUG && BEAROUND_ADAPTIVE_BENCH
struct AdaptiveBenchHostConfiguration {
    let token: String
    let user: String
    let adaptiveEnabled: Bool

    static func load() -> AdaptiveBenchHostConfiguration? {
        let info = Bundle.main
        guard info.object(forInfoDictionaryKey: "BEAROUND_ADAPTIVE_BENCH") as? Bool == true,
              let endpoint = info.object(forInfoDictionaryKey: "BEAROUND_ADAPTIVE_BENCH_ENDPOINT") as? String,
              let url = URL(string: endpoint), url.scheme == "https", let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", isLocalHost(host),
              let token = info.object(forInfoDictionaryKey: "BEAROUND_ADAPTIVE_BENCH_TOKEN") as? String,
              let user = info.object(forInfoDictionaryKey: "BEAROUND_ADAPTIVE_BENCH_USER") as? String,
              token.hasPrefix("fixture-"), user.hasPrefix("fixture-"),
              let enabled = info.object(forInfoDictionaryKey: "BEAROUND_ADAPTIVE_BENCH_ENABLED") as? Bool,
              info.bundleIdentifier?.hasSuffix(".adaptivebench") == true,
              AdaptiveSamplingBench.isEnabled else { return nil }
        #if BEAROUND_ADAPTIVE_BASELINE
        guard info.object(forInfoDictionaryKey: "BEAROUND_ADAPTIVE_BENCH_BASELINE") as? Bool == true, !enabled else { return nil }
        #else
        guard info.object(forInfoDictionaryKey: "BEAROUND_ADAPTIVE_BENCH_BASELINE") as? Bool == false else { return nil }
        #endif
        return AdaptiveBenchHostConfiguration(token: token, user: user, adaptiveEnabled: enabled)
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if value == "localhost" || value.hasSuffix(".local") || value == "::1" { return true }
        let parts = value.split(separator: ".")
        let octets = parts.compactMap { Int($0) }
        if parts.count == 4, octets.count == 4, octets.allSatisfy({ (0 ... 255).contains($0) }) {
            return octets[0] == 127 || octets[0] == 10 || (octets[0] == 172 && (16 ... 31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
        }
        return value.contains(":") && (value.hasPrefix("fc") || value.hasPrefix("fd") || value.hasPrefix("fe8")
            || value.hasPrefix("fe9") || value.hasPrefix("fea") || value.hasPrefix("feb"))
    }
}
#endif

#if DEBUG && BEAROUND_ADAPTIVE_BENCH && !BEAROUND_ADAPTIVE_BASELINE
enum AdaptiveBenchHostDiagnostics {
    nonisolated private static func sanitized(_ text: String, limit: Int) -> String {
        var description = String(text.prefix(1024))
        for pattern in [#"https?://\S+"#, #"fixture-[A-Za-z0-9_-]+"#,
                        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
                        #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27,}\b"#,
                        #"\b[0-9A-Fa-f]{16,}\b"#, #"-?\d+\.\d+"#, #"[\"\u201c\u201d'][^\"\u201c\u201d']*[\"\u201c\u201d']"#] {
            description = description.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return String(description.prefix(limit))
    }

    nonisolated static func capturedTrust(_ trust: SecTrust) -> [String: Any] {
        var result = SecTrustResultType.invalid
        let status = SecTrustGetTrustResult(trust, &result)
        var value: [String: Any] = ["peerTrustPresent": true, "readStatus": status, "recordedTrustResult": result.rawValue,
            "evaluationAvailable": status == errSecSuccess && result != .invalid]
        guard status == errSecSuccess, result != .invalid else {
            value["certificateDERSHA256"] = [String]()
            value["failureReasons"] = [String]()
            return value
        }
        let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
        value["chainCount"] = certificates.count
        value["certificateDERSHA256"] = certificates.prefix(4).map {
            SHA256.hash(data: SecCertificateCopyData($0) as Data).map { String(format: "%02x", $0) }.joined()
        }
        let recorded = SecTrustCopyResult(trust) as? [String: Any]
        value["copiedTrustResult"] = recorded?[kSecTrustResultValue as String] ?? NSNull()
        let properties = SecTrustCopyProperties(trust) as? [[String: Any]] ?? []
        value["failureReasons"] = Array(properties.prefix(4).compactMap { property -> String? in
            let reason = property["type"] as? String == "error" ? property["value"] as? String
                : property[kSecPropertyTypeError as String] as? String
            return reason.map { sanitized($0, limit: 160) }
        }.prefix(3))
        return value
    }

    nonisolated private static func peerTrust(_ error: NSError) -> [String: Any] {
        guard error.domain == NSURLErrorDomain, (-1206 ... -1200).contains(error.code) else {
            return ["peerTrustPresent": false, "reason": "not_urlsession_tls_failure"]
        }
        var current: NSError? = error
        var invalidType = false
        for depth in 0 ..< 3 {
            guard let candidate = current else { break }
            if let raw = candidate.userInfo[NSURLErrorFailingURLPeerTrustErrorKey] {
                if CFGetTypeID(raw as CFTypeRef) == SecTrustGetTypeID() {
                    let trust = raw as! SecTrust
                    var value = capturedTrust(trust)
                    value["sourceErrorDepth"] = depth
                    return value
                }
                invalidType = true
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return ["peerTrustPresent": false, "reason": invalidType ? "invalid_type" : "key_absent_within_depth_bound"]
    }

    nonisolated private static func failingEndpoint(_ error: NSError) -> [String: Any] {
        var current: NSError? = error
        for depth in 0 ..< 3 {
            guard let candidate = current else { break }
            let direct = candidate.userInfo[NSURLErrorFailingURLErrorKey] as? URL
            let text = candidate.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
            if let url = direct ?? text.flatMap({ URL(string: $0) }) {
                guard url.scheme == "https", let host = url.host?.lowercased(),
                      ["192.168.15.25", "127.0.0.1", "localhost"].contains(host),
                      let port = url.port, [18080, 18081].contains(port) else {
                    return ["available": false, "unexpectedEndpoint": true]
                }
                let path = ["", "/", "/ingest", "/sdk/places/nearby", "/health"].contains(url.path) ? url.path : "[redacted]"
                return ["available": true, "unexpectedEndpoint": false, "sourceErrorDepth": depth,
                        "host": host, "port": port, "path": path]
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return ["available": false, "reason": "key_absent_within_depth_bound"]
    }

    nonisolated static func syncError(_ error: NSError) -> [String: Any] {
        let domain = [NSURLErrorDomain, NSCocoaErrorDomain, "BeAroundSDK", "BearoundSDK.APIError"].contains(error.domain)
            ? error.domain : "unrecognized_error_domain"
        let usesSystemDescription = error.domain == NSURLErrorDomain
        let description = usesSystemDescription ? error.localizedDescription
            : NSError(domain: domain, code: error.code, userInfo: nil).localizedDescription
        return ["domain": domain, "code": error.code, "description": sanitized(description, limit: 512),
                "descriptionPolicy": usesSystemDescription ? "sanitized_system" : "domain_code_only",
                "tls": peerTrust(error), "failingEndpoint": failingEndpoint(error)]
    }

    nonisolated static func encode(counters: Data, endpoint: String, locationAuthorization: Int,
                                   permissionRequestInvoked: Bool, lastSync: [String: Any]?) -> Data? {
        guard let original = try? JSONSerialization.jsonObject(with: counters) as? [String: Any] else { return nil }
        let keys = ["schemaVersion", "pid", "deviceTimestampMs", "counterScope", "generation", "httpAttempts",
                    "serializedBytes", "uniqueSamples", "complementaryReads", "complementaryCacheReads", "cachedCallbacks",
                    "liveAttempts", "summaryAttempts", "transitionAttempts", "failures", "policyDenials", "clockUncertainties"]
        var value = original.filter { keys.contains($0.key) }
        value["hostEndpoint"] = endpoint
        value["hostLocationAuthorization"] = locationAuthorization
        value["hostForegroundLocationRequestInvoked"] = permissionRequestInvoked
        value["hostLastSync"] = lastSync ?? NSNull()
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), data.count <= 4096 else { return nil }
        return data
    }
}

final class AdaptiveBenchDefaultTLSProbe: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated static let endpoint = URL(string: "https://192.168.15.25:18081/health")!
    nonisolated private let lock = NSLock()
    nonisolated private let outputFile: URL
    nonisolated(unsafe) private var retainedTrust: SecTrust?
    nonisolated(unsafe) private var session: URLSession?
    nonisolated(unsafe) private var started = false
    nonisolated(unsafe) private var unexpectedChallenge = false

    init(outputFile: URL) { self.outputFile = outputFile }

    nonisolated func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let activeSession = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        lock.lock(); session = activeSession; lock.unlock()
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        activeSession.dataTask(with: request) { [weak self] _, response, error in
            self?.completed(response: response, error: error)
        }.resume()
    }

    nonisolated func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                               completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == Self.endpoint.host,
           challenge.protectionSpace.port == Self.endpoint.port {
            lock.lock(); retainedTrust = challenge.protectionSpace.serverTrust; lock.unlock()
        } else {
            lock.lock(); unexpectedChallenge = true; lock.unlock()
        }
        completionHandler(.performDefaultHandling, nil)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                               completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url == Self.endpoint ? request : nil)
    }

    nonisolated private func completed(response: URLResponse?, error: Error?) {
        lock.lock()
        let trust = retainedTrust
        let unusual = unexpectedChallenge
        let activeSession = session
        session = nil
        retainedTrust = nil
        lock.unlock()
        var value: [String: Any] = ["schemaVersion": 1, "pid": ProcessInfo.processInfo.processIdentifier,
            "deviceTimestampMs": Int64(Date().timeIntervalSince1970 * 1000), "probeScope": "auxiliary_health_get",
            "observationBodyCountersIncluded": false, "endpoint": Self.endpoint.absoluteString,
            "defaultHandling": true, "unexpectedChallenge": unusual,
            "httpStatus": (response as? HTTPURLResponse)?.statusCode as Any? ?? NSNull(),
            "transportError": error.map { AdaptiveBenchHostDiagnostics.syncError($0 as NSError) } ?? NSNull()]
        value["challengeTrust"] = trust.map { AdaptiveBenchHostDiagnostics.capturedTrust($0) }
            ?? ["peerTrustPresent": false, "reason": "no_allowed_server_trust_challenge"]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), data.count <= 4096 {
            do {
                try data.write(to: outputFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputFile.path)
            } catch {}
        }
        activeSession?.finishTasksAndInvalidate()
    }
}
#endif

private enum UserDefaultsKeys {
    static let scanPrecision = "scanPrecision"
    static let queueSize = "queueSize"
    static let userPropertyInternalId = "userPropertyInternalId"
    static let userPropertyEmail = "userPropertyEmail"
    static let userPropertyName = "userPropertyName"
    static let userPropertyCustom = "userPropertyCustom"
}

enum BeaconSortOption: String, CaseIterable {
    case proximity = "Proximidade"
    case name = "ID"
}

/// A single entry in the geofence/capture debug log.
struct GeofenceEvent: Identifiable {
    enum Kind {
        case regionEnter
        case regionExit
        case scanResumed
        case scanPaused
        // v2.5 — Two Eyes
        case bluetoothZoneEnter
        case bluetoothZoneExit
    }

    let id = UUID()
    let kind: Kind
    let timestamp: Date
    /// Free-form detail line (reason / outcome / coordinates).
    let detail: String
}

/// Which "eye" is being mirrored by a Debug Geofence card.
/// LEFT  = Location (CoreLocation region monitoring)
/// RIGHT = Bluetooth (CBCentralManager scan, BLE-only zone detector)
enum GeofenceEye {
    case location
    case bluetooth
}

class BeaconViewModel: NSObject, ObservableObject, BeAroundSDKDelegate {
    @Published var isScanning = false
    @Published var beacons: [Beacon] = []
    @Published var statusMessage = "Pronto"
    @Published var permissionStatus = "Verificando..."
    @Published var lastScanTime: Date?
    @Published var sortOption: BeaconSortOption = .proximity
    @Published var bluetoothStatus: String = "Verificando..."
    @Published var notificationStatus: String = "Verificando..."

    // SDK Configuration Settings
    @Published var scanPrecision: ScanPrecision = .high
    @Published var queueSize: MaxQueuedPayloads = .medium

    // Sync Info
    @Published var lastSyncTime: Date?
    @Published var lastSyncBeaconCount: Int = 0
    @Published var lastSyncResult: String = "Aguardando..."
    @Published var retryBatchCount: Int = 0

    // BLE Diagnostic
    @Published var bleDiagnostic: String = "..."

    // MARK: - Geofence Debug — Two Eyes (v2.5)
    //
    // Two independent presence signals, each rendered in its own card:
    //   👁 LEFT  — Location:  isInBeaconRegion + lastLocationEnter/Exit + locationRegionEnterCount
    //   👁 RIGHT — Bluetooth: isInBluetoothZone + lastBluetoothEnter/Exit + bluetoothZoneEnterCount

    /// LEFT EYE (Location) — True while CoreLocation reports the device is inside the iBeacon region.
    /// Works even if the user has BT permission off (iOS manages BLE at the system level).
    @Published var isInBeaconRegion: Bool = false
    /// LEFT EYE — When the Location eye most recently saw a region ENTER. Resets per session.
    @Published var lastLocationEnter: Date?
    /// LEFT EYE — When the Location eye most recently saw a region EXIT. Resets per session.
    @Published var lastLocationExit: Date?
    /// LEFT EYE — Number of region enters observed in this session.
    @Published var locationRegionEnterCount: Int = 0

    /// RIGHT EYE (Bluetooth) — True while the BLE-only zone detector sees at least one beacon
    /// in its rolling window. Works even if the user has Location off (region monitoring inactive).
    @Published var isInBluetoothZone: Bool = false
    /// RIGHT EYE — When the Bluetooth eye most recently entered the zone. Resets per session.
    @Published var lastBluetoothEnter: Date?
    /// RIGHT EYE — When the Bluetooth eye most recently exited the zone. Resets per session.
    @Published var lastBluetoothExit: Date?
    /// RIGHT EYE — Number of Bluetooth zone enters observed in this session.
    @Published var bluetoothZoneEnterCount: Int = 0

    /// LEFT EYE — Unique beacon keys (`major.minor`) ever seen by the Location eye in this session.
    /// Used to compute the "Total detectados" pill on the card. Survives beacons going out of range.
    @Published var locationBeaconKeysSeen: Set<String> = []

    /// RIGHT EYE — Unique beacon keys ever seen by the Bluetooth eye in this session.
    @Published var bluetoothBeaconKeysSeen: Set<String> = []

    /// First-detection timestamp per beacon per eye. Used by the comparative analysis block
    /// to measure latency — for any beacon both eyes saw, we know which eye fired first and
    /// by how much. Populated lazily in didUpdateBeacons (first sighting only — no overwrites).
    @Published var firstSeenByLocation: [String: Date] = [:]
    @Published var firstSeenByBluetooth: [String: Date] = [:]

    /// LEFT EYE — Beacons currently visible to the Location eye (have `.coreLocation` in sources).
    /// Live-derived from `beacons` so it tracks comings and goings without extra state.
    var locationBeaconsNow: Int {
        beacons.filter { $0.discoverySources.contains(.coreLocation) }.count
    }

    /// RIGHT EYE — Beacons currently visible to the Bluetooth eye (have `.serviceUUID` or `.name` in sources).
    var bluetoothBeaconsNow: Int {
        beacons.filter {
            $0.discoverySources.contains(.serviceUUID) || $0.discoverySources.contains(.name)
        }.count
    }

    // MARK: - Comparative Analysis (v2.5)
    //
    // These derived values power the "Análise comparativa" block on the dedicated screen.
    // They answer: which eye is more useful in YOUR environment right now?

    /// Beacon keys this session was seen ONLY by the Location eye (never by BT).
    /// Indicates beacons that BT can't reach — could be permission off, BT-disabled beacons,
    /// or out of BLE scan range while still in iBeacon region range.
    var locationOnlyKeys: Set<String> {
        locationBeaconKeysSeen.subtracting(bluetoothBeaconKeysSeen)
    }

    /// Beacon keys ONLY seen by the Bluetooth eye (never by Location).
    /// Indicates beacons that CL doesn't pick up — Precise Location off, distance > region trigger,
    /// or beacon advertises the BEAD service but isn't a CLBeaconRegion target.
    var bluetoothOnlyKeys: Set<String> {
        bluetoothBeaconKeysSeen.subtracting(locationBeaconKeysSeen)
    }

    /// Beacon keys seen by BOTH eyes — the overlap. Only these have meaningful latency data.
    var bothEyesKeys: Set<String> {
        locationBeaconKeysSeen.intersection(bluetoothBeaconKeysSeen)
    }

    /// Per-beacon winner: which eye fired first for each beacon in the overlap.
    /// Returns (locationWins, bluetoothWins, averageLeadSeconds). Lead is positive when the
    /// winning eye saw it earlier — averaged across all beacons.
    /// (locationWins, bluetoothWins) won't always sum to bothEyesKeys.count because ties exist.
    var detectionRace: (locationWins: Int, bluetoothWins: Int, ties: Int, avgLeadSeconds: Double) {
        var locWins = 0
        var btWins = 0
        var ties = 0
        var leadsSeconds: [Double] = []

        for key in bothEyesKeys {
            guard let locFirst = firstSeenByLocation[key],
                  let btFirst = firstSeenByBluetooth[key] else { continue }
            let delta = btFirst.timeIntervalSince(locFirst)  // positive = location was earlier
            // Treat anything within 100ms as a tie — beneath the resolution of our event loop.
            if abs(delta) < 0.1 {
                ties += 1
            } else if delta > 0 {
                locWins += 1
                leadsSeconds.append(delta)
            } else {
                btWins += 1
                leadsSeconds.append(-delta)
            }
        }

        let avg = leadsSeconds.isEmpty ? 0.0 : leadsSeconds.reduce(0, +) / Double(leadsSeconds.count)
        return (locWins, btWins, ties, avg)
    }

    /// RSSI statistics from the BT eye for beacons currently in range.
    /// Returns (avg, min, max). Defaults to (0,0,0) when no beacons are visible.
    /// CoreLocation does NOT give us raw RSSI (only CLProximity buckets), which is one
    /// concrete reason to keep the Bluetooth eye even when Location is working — it's the
    /// only source of fine-grained signal strength.
    var bluetoothRSSIStats: (avg: Int, min: Int, max: Int) {
        let rssiValues = beacons.compactMap { beacon -> Int? in
            let hasBLE = beacon.discoverySources.contains(.serviceUUID) || beacon.discoverySources.contains(.name)
            return hasBLE ? beacon.rssi : nil
        }
        guard !rssiValues.isEmpty else { return (0, 0, 0) }
        let avg = rssiValues.reduce(0, +) / rssiValues.count
        return (avg, rssiValues.min() ?? 0, rssiValues.max() ?? 0)
    }

    // MARK: - Duty Cycle (v2.5)

    /// RIGHT EYE — Current scan mode of the Bluetooth eye. Drives the "Modo" pill on the card.
    /// Defaults to `.idle` so the UI renders correctly even before the SDK fires its first event.
    @Published var bluetoothScanMode: BluetoothScanMode = .idle

    /// RIGHT EYE — Absolute time of the next idle peek. Non-nil only while bluetoothScanMode == .idle.
    /// Used together with `nowTick` to render the live "Próx. scan em Xs" countdown.
    @Published var bluetoothNextIdleScanAt: Date?

    /// 1Hz heartbeat used to age the countdown ("4:23 → 4:22 → 4:21...") without forcing the
    /// BluetoothManager to fire an SDK event every second. Updated by `tickTimer`.
    @Published var nowTick: Date = Date()
    private var tickTimer: Timer?

    /// True when active scanning (ranging + BLE) is running. Outside a region this stays false.
    @Published var isActiveScanRunning: Bool = false
    /// Rolling log of geofence events (most recent first, max 30).
    @Published var geofenceEventLog: [GeofenceEvent] = []
    private let maxGeofenceLogEntries = 30

    // Detection Log — separate queues for foreground, background, background locked, and terminated
    @Published var foregroundLog: [DetectionLogEntry] = []
    @Published var backgroundLog: [DetectionLogEntry] = []
    @Published var backgroundLockedLog: [DetectionLogEntry] = []
    @Published var terminatedLog: [DetectionLogEntry] = []
    private let maxForegroundLogEntries = 50000
    private let maxBackgroundLogEntries = 50000
    private let maxBackgroundLockedLogEntries = 50000
    private let maxTerminatedLogEntries = 50000

    /// Tracks whether the device is locked
    private(set) var isDeviceLocked: Bool = false

    /// True when the process was started by iOS in the background (cold relaunch after the
    /// app was force-quit / killed). While true, detections are tagged `.terminated` — they
    /// happened while the app was "dead" and iOS woke it via region monitoring. Cleared the
    /// moment the user actually opens the app (didBecomeActive).
    private var launchedFromTerminated: Bool = false

    /// Debounced disk-save handle for the detection log.
    private var saveWorkItem: DispatchWorkItem?

    var detectionLog: [DetectionLogEntry] {
        (foregroundLog + backgroundLog + backgroundLockedLog + terminatedLog).sorted { $0.timestamp > $1.timestamp }
    }

    // Pinned Beacons
    @Published var pinnedBeaconKeys: Set<String> = []

    // User Properties
    @Published var userPropertyInternalId: String = ""
    @Published var userPropertyEmail: String = ""
    @Published var userPropertyName: String = ""
    @Published var userPropertyCustom: String = ""

    private let locationManager = CLLocationManager()
    private var wasInBeaconRegion = false
    private var scanStartTime: Date?
    private let notificationManager = NotificationManager.shared
    private var bluetoothManager: CBCentralManager?
    private var diagnosticTimer: Timer?
    #if DEBUG && BEAROUND_ADAPTIVE_BENCH && !BEAROUND_ADAPTIVE_BASELINE
    private var adaptiveBenchDiagnosticsURL: URL?
    private var adaptiveBenchPermissionRequestInvoked = false
    private var adaptiveBenchLastSync: [String: Any]?
    private var adaptiveBenchDefaultTLSProbe: AdaptiveBenchDefaultTLSProbe?
    #endif

    override init() {
        super.init()
        #if DEBUG && BEAROUND_ADAPTIVE_BENCH
        guard AdaptiveBenchHostConfiguration.load() != nil else {
            statusMessage = "Configuração de bancada inválida"
            return
        }
        #endif
        locationManager.delegate = self

        // If the process is starting while not active, iOS relaunched us in the background
        // after the app was killed — detections in this window are "terminated" state.
        launchedFromTerminated = (UIApplication.shared.applicationState != .active)

        loadSavedSettings()
        loadPersistedLogs()
        setupLockObservers()

        #if !(DEBUG && BEAROUND_ADAPTIVE_BENCH)
        locationManager.requestAlwaysAuthorization()
        notificationManager.requestAuthorization()
        #endif
        updatePermissionStatus()
        checkBluetoothStatus()
        checkNotificationStatus()
        initializeSDK()
        startDiagnosticTimer()
        startTickTimer()
    }

    /// 1Hz heartbeat that re-publishes `nowTick`. SwiftUI views observing the view model
    /// re-render with each tick, which is how the EyeCard's countdown stays live.
    private func startTickTimer() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.nowTick = Date()
            }
        }
    }

    private func setupLockObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceDidLock),
            name: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceDidUnlock),
            name: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        // Check initial state
        isDeviceLocked = !UIApplication.shared.isProtectedDataAvailable
    }

    @objc private func deviceDidLock() {
        isDeviceLocked = true
    }

    @objc private func deviceDidUnlock() {
        isDeviceLocked = false
    }

    @objc private func appDidBecomeActive() {
        // The user opened the app — the terminated-relaunch window is over.
        launchedFromTerminated = false
    }

    @objc private func appDidEnterBackground() {
        // Flush synchronously so nothing is lost if iOS suspends/kills us next.
        persistDetectionLog(synchronous: true)
    }

    private func checkBluetoothStatus() {
        bluetoothManager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    private func checkNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    self.notificationStatus = "Autorizada"
                case .denied:
                    self.notificationStatus = "Negada"
                case .notDetermined:
                    self.notificationStatus = "Não solicitada"
                @unknown default:
                    self.notificationStatus = "Desconhecida"
                }
            }
        }
    }

    private func loadSavedSettings() {
        let defaults = UserDefaults.standard

        if let precisionRaw = defaults.string(forKey: UserDefaultsKeys.scanPrecision),
           let precision = ScanPrecision(rawValue: precisionRaw) {
            self.scanPrecision = precision
        }

        if let queueRaw = defaults.object(forKey: UserDefaultsKeys.queueSize) as? Int,
           let queue = MaxQueuedPayloads(rawValue: queueRaw) {
            self.queueSize = queue
        }

        self.userPropertyInternalId = defaults.string(forKey: UserDefaultsKeys.userPropertyInternalId) ?? ""
        self.userPropertyEmail = defaults.string(forKey: UserDefaultsKeys.userPropertyEmail) ?? ""
        self.userPropertyName = defaults.string(forKey: UserDefaultsKeys.userPropertyName) ?? ""
        self.userPropertyCustom = defaults.string(forKey: UserDefaultsKeys.userPropertyCustom) ?? ""
    }

    private func saveCurrentSettings() {
        let defaults = UserDefaults.standard

        defaults.set(scanPrecision.rawValue, forKey: UserDefaultsKeys.scanPrecision)
        defaults.set(queueSize.rawValue, forKey: UserDefaultsKeys.queueSize)

        defaults.set(userPropertyInternalId, forKey: UserDefaultsKeys.userPropertyInternalId)
        defaults.set(userPropertyEmail, forKey: UserDefaultsKeys.userPropertyEmail)
        defaults.set(userPropertyName, forKey: UserDefaultsKeys.userPropertyName)
        defaults.set(userPropertyCustom, forKey: UserDefaultsKeys.userPropertyCustom)
    }

    private func updatePermissionStatus() {
        let locationAuth = locationManager.authorizationStatus

        var status: String = switch locationAuth {
        case .authorizedAlways: "Sempre (Background habilitado)"
        case .authorizedWhenInUse: "Quando em uso (Background não funciona)"
        case .denied, .restricted: "Negada"
        case .notDetermined: "Aguardando resposta..."
        @unknown default: "Status desconhecido"
        }

        // Check precise location — iOS disables all beacon APIs when off
        if #available(iOS 14.0, *) {
            if locationAuth == .authorizedAlways || locationAuth == .authorizedWhenInUse {
                if locationManager.accuracyAuthorization == .reducedAccuracy {
                    status += " | Precisa: OFF (beacons CL desabilitados)"
                }
            }
        }

        permissionStatus = status
    }

    #if DEBUG && BEAROUND_ADAPTIVE_BENCH
    @MainActor
    private func configureAdaptiveBench() -> Bool {
        guard let bench = AdaptiveBenchHostConfiguration.load() else {
            statusMessage = "Configuração de bancada inválida"
            return false
        }
        let sdk = BeAroundSDK.shared
        sdk.setErrorReportingEnabled(false)
        #if BEAROUND_ADAPTIVE_BASELINE
        sdk.configure(businessToken: bench.token, scanPrecision: scanPrecision, maxQueuedPayloads: queueSize,
            requestTrackingOnStart: false)
        #else
        sdk.configure(businessToken: bench.token, scanPrecision: scanPrecision, maxQueuedPayloads: queueSize,
            requestTrackingOnStart: false, adaptiveSamplingEnabled: bench.adaptiveEnabled)
        #endif
        userPropertyInternalId = bench.user
        userPropertyEmail = ""
        userPropertyName = ""
        userPropertyCustom = ""
        sdk.setUserProperties(UserProperties(internalId: bench.user))
        #if !BEAROUND_ADAPTIVE_BASELINE
        if adaptiveBenchDiagnosticsURL == nil,
           let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                adaptiveBenchDiagnosticsURL = directory.appendingPathComponent("adaptive-bench-diagnostics.json")
            } catch { statusMessage = "Could not prepare bench diagnostics" }
        }
        #endif
        return true
    }
    #endif

    @MainActor
    private func initializeSDK() {
        #if DEBUG && BEAROUND_ADAPTIVE_BENCH
        guard configureAdaptiveBench() else { return }
        BeAroundSDK.shared.delegate = self
        statusMessage = "Bancada local configurada"
        #if !BEAROUND_ADAPTIVE_BASELINE
        if !adaptiveBenchPermissionRequestInvoked,
           ProcessInfo.processInfo.arguments.contains("--adaptive-bench-request-existing-permissions") {
            adaptiveBenchPermissionRequestInvoked = true
            BeAroundSDK.shared.requestLocationAuthorization(.whenInUse)
        }
        if adaptiveBenchDefaultTLSProbe == nil,
           ProcessInfo.processInfo.arguments.contains("--adaptive-bench-probe-default-tls"),
           let file = adaptiveBenchDiagnosticsURL?.deletingLastPathComponent().appendingPathComponent("adaptive-bench-default-tls.json") {
            let probe = AdaptiveBenchDefaultTLSProbe(outputFile: file)
            adaptiveBenchDefaultTLSProbe = probe
            probe.start()
        }
        #endif
        startScanning()
        return
        #else
        BeAroundSDK.shared.configure(
            businessToken: "ee2ec9c46d2b2ad99bddcdd0afe224e6",
            scanPrecision: scanPrecision,
            maxQueuedPayloads: queueSize
        )

        BeAroundSDK.shared.delegate = self

        // Só envia se o campo "ID do usuário" (Settings) estiver preenchido.
        // Persistido no UserDefaults → ao reabrir o app, assume o id salvo.
        if !userPropertyInternalId.isEmpty {
            BeAroundSDK.shared.setUserProperties(
                UserProperties(
                    internalId: userPropertyInternalId,
                    email: userPropertyEmail,
                    name: userPropertyName,
                    customProperties: ["custom": userPropertyCustom]
                )
            )
        }

        statusMessage = "Configurado"

        startScanning()
        #endif
    }
    
    @MainActor
    func applySettings() {
        #if DEBUG && BEAROUND_ADAPTIVE_BENCH
        let wasScanning = isScanning
        if wasScanning { stopScanning() }
        guard configureAdaptiveBench() else { return }
        if wasScanning { startScanning() }
        return
        #else
        let wasScanning = isScanning

        if wasScanning {
            stopScanning()
        }

        BeAroundSDK.shared.configure(
            businessToken: "ee2ec9c46d2b2ad99bddcdd0afe224e6",
            scanPrecision: scanPrecision,
            maxQueuedPayloads: queueSize
        )
        
        let properties = UserProperties(
            internalId: userPropertyInternalId,
            email: userPropertyEmail,
            name: userPropertyName,
            customProperties: [
                "custom": userPropertyCustom,
            ]
        )

        BeAroundSDK.shared.setUserProperties(properties)

        // Save settings to UserDefaults
        saveCurrentSettings()

        statusMessage = "Configurações aplicadas"

        if wasScanning {
            startScanning()
        }
        #endif
    }

    @MainActor
    func startScanning() {
        BeAroundSDK.shared.startScanning()
        isScanning = true
        statusMessage = "Scaneando..."
        lastScanTime = Date()
        scanStartTime = Date() // Marca início do scan para evitar notificações imediatas
        wasInBeaconRegion = false // Reseta estado para detectar nova entrada
    }

    @MainActor
    func stopScanning() {
        BeAroundSDK.shared.stopScanning()
        isScanning = false
        statusMessage = "Parado"
        wasInBeaconRegion = false // Reseta para permitir nova detecção quando iniciar novamente
        scanStartTime = nil
    }

    func togglePin(for beacon: Beacon) {
        let key = "\(beacon.major).\(beacon.minor)"
        if pinnedBeaconKeys.contains(key) {
            pinnedBeaconKeys.remove(key)
        } else {
            pinnedBeaconKeys.insert(key)
        }
        beacons = sortBeacons(beacons, by: sortOption)
    }

    func isPinned(_ beacon: Beacon) -> Bool {
        pinnedBeaconKeys.contains("\(beacon.major).\(beacon.minor)")
    }

    var scanPrecisionLabel: String {
        switch BeAroundSDK.shared.currentScanPrecision ?? scanPrecision {
        case .high: return "Alta (Ininterrupto)"
        case .medium: return "Média (3x10s/min)"
        case .low: return "Baixa (1x10s/min)"
        }
    }

    var scanMode: String {
        return scanPrecisionLabel
    }

    var sdkVersion: String {
        return BeAroundSDK.version
    }

    private func startDiagnosticTimer() {
        diagnosticTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.bleDiagnostic = BeAroundSDK.shared.bleDiagnosticInfo
            #if DEBUG && BEAROUND_ADAPTIVE_BENCH && !BEAROUND_ADAPTIVE_BASELINE
            guard AdaptiveSamplingBench.isEnabled, let self, let file = self.adaptiveBenchDiagnosticsURL,
                  AdaptiveBenchHostConfiguration.load() != nil,
                  let endpoint = Bundle.main.object(forInfoDictionaryKey: "BEAROUND_ADAPTIVE_BENCH_ENDPOINT") as? String else { return }
            let authorization = Int(self.locationManager.authorizationStatus.rawValue)
            let requestInvoked = self.adaptiveBenchPermissionRequestInvoked
            let lastSync = self.adaptiveBenchLastSync
            AdaptiveSamplingBench.counterSnapshot { data in
                guard let counters = data,
                      let data = AdaptiveBenchHostDiagnostics.encode(counters: counters, endpoint: endpoint,
                          locationAuthorization: authorization, permissionRequestInvoked: requestInvoked, lastSync: lastSync) else { return }
                do {
                    try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                } catch {}
            }
            #endif
        }
    }

    deinit {
        diagnosticTimer?.invalidate()
        tickTimer?.invalidate()
    }
}

extension BeaconViewModel: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_: CLLocationManager) {
        DispatchQueue.main.async {
            self.updatePermissionStatus()
            self.initializeSDK()
        }
    }
}

extension BeaconViewModel: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async {
            switch central.state {
            case .poweredOn:
                self.bluetoothStatus = "Ligado"
            case .poweredOff:
                self.bluetoothStatus = "Desligado"
            case .unsupported:
                self.bluetoothStatus = "Não suportado"
            case .unauthorized:
                self.bluetoothStatus = "Não autorizado"
            case .resetting:
                self.bluetoothStatus = "Reiniciando"
            case .unknown:
                self.bluetoothStatus = "Desconhecido"
            @unknown default:
                self.bluetoothStatus = "Desconhecido"
            }
        }
    }
}

extension BeaconViewModel {
    func didUpdateBeacons(_ beacons: [Beacon]) {
        DispatchQueue.main.async {
            let sortedBeacons = self.sortBeacons(beacons, by: self.sortOption)
            
            // Notifications are driven solely by zone enter/exit transitions
            // (didEnterBluetoothZone / didExitBluetoothZone and the Location-eye
            // equivalents), not by every beacon update — see those delegate methods.
            self.wasInBeaconRegion = !sortedBeacons.isEmpty
            self.beacons = sortedBeacons
            self.lastScanTime = Date()

            // v2.5 — Two Eyes — accumulate unique beacon keys per detection source so each
            // EyeCard can show "Total detectados" independently. Sets dedupe automatically.
            // Also stamp the FIRST sighting per eye so the comparative analysis can compute
            // latency (who saw which beacon first, and by how many seconds).
            let now = Date()
            for beacon in sortedBeacons {
                let key = "\(beacon.major).\(beacon.minor)"
                if beacon.discoverySources.contains(.coreLocation) {
                    self.locationBeaconKeysSeen.insert(key)
                    if self.firstSeenByLocation[key] == nil {
                        self.firstSeenByLocation[key] = now
                    }
                }
                if beacon.discoverySources.contains(.serviceUUID) || beacon.discoverySources.contains(.name) {
                    self.bluetoothBeaconKeysSeen.insert(key)
                    if self.firstSeenByBluetooth[key] == nil {
                        self.firstSeenByBluetooth[key] = now
                    }
                }
            }

            // Record detection log entries
            let isBackground = UIApplication.shared.applicationState != .active
            self.recordDetections(beacons: sortedBeacons, isBackground: isBackground)

            if sortedBeacons.isEmpty {
                self.statusMessage = "Scaneando..."
            } else {
                self.statusMessage = "\(sortedBeacons.count) beacon\(sortedBeacons.count == 1 ? "" : "s")"
            }
        }
    }

    private func sortBeacons(_ beacons: [Beacon], by option: BeaconSortOption) -> [Beacon] {
        beacons.sorted { beacon1, beacon2 in
            let key1 = "\(beacon1.major).\(beacon1.minor)"
            let key2 = "\(beacon2.major).\(beacon2.minor)"
            let pinned1 = pinnedBeaconKeys.contains(key1)
            let pinned2 = pinnedBeaconKeys.contains(key2)

            if pinned1 != pinned2 {
                return pinned1
            }

            switch option {
            case .proximity:
                let proximityOrder: [BeaconProximity] = [.immediate, .near, .far, .bt, .unknown]
                if let index1 = proximityOrder.firstIndex(of: beacon1.proximity),
                   let index2 = proximityOrder.firstIndex(of: beacon2.proximity),
                   index1 != index2 {
                    return index1 < index2
                }

                if beacon1.rssi != beacon2.rssi {
                    return beacon1.rssi > beacon2.rssi
                }

                if beacon1.accuracy > 0 && beacon2.accuracy > 0 {
                    return beacon1.accuracy < beacon2.accuracy
                }
                if beacon1.accuracy > 0 { return true }
                if beacon2.accuracy > 0 { return false }

                return false

            case .name:
                return "\(beacon1.major).\(beacon1.minor)" < "\(beacon2.major).\(beacon2.minor)"
            }
        }
    }

    func didFailWithError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            print("Erro: \(error.localizedDescription)")
            self?.statusMessage = "Erro: \(error.localizedDescription)"
        }
    }

    func didChangeScanning(isScanning: Bool) {
        DispatchQueue.main.async {
            self.isScanning = isScanning
            self.statusMessage = isScanning ? "Scaneando..." : "Parado"
        }
    }

    // MARK: - Sync Lifecycle Delegate Methods

    func willStartSync(beaconCount: Int) {
        DispatchQueue.main.async {
            NSLog("[BeaconViewModel] Sync starting with %d beacons", beaconCount)
            self.lastSyncBeaconCount = beaconCount
            self.lastSyncResult = "Enviando..."
        }
    }

    func didCompleteSync(beaconCount: Int, success: Bool, error: Error?) {
        DispatchQueue.main.async {
            self.lastSyncTime = Date()
            self.lastSyncBeaconCount = beaconCount
            self.retryBatchCount = BeAroundSDK.shared.pendingBatchCount
            #if DEBUG && BEAROUND_ADAPTIVE_BENCH && !BEAROUND_ADAPTIVE_BASELINE
            self.adaptiveBenchLastSync = ["completedAtMs": Int64(Date().timeIntervalSince1970 * 1000), "success": success,
                "error": error.map { AdaptiveBenchHostDiagnostics.syncError($0 as NSError) } ?? NSNull()]
            #endif
            if success {
                NSLog("[BeaconViewModel] Sync completed successfully: %d beacons", beaconCount)
                self.lastSyncResult = "Sucesso"
            } else {
                let errorMsg = error?.localizedDescription ?? "Erro desconhecido"
                NSLog("[BeaconViewModel] Sync failed: %@", errorMsg)
                self.lastSyncResult = "Falha: \(errorMsg)"
            }
            // App-level (NOT the SDK): surface every ingest as a local notification so it's
            // visible — including syncs that happen in background / terminated state.
            // Only when beacons were actually sent (beaconCount > 0) to avoid no-op syncs.
            if beaconCount > 0 {
                self.notificationManager.notifyAPISyncCompleted(beaconCount: beaconCount, success: success)
            }
        }
    }

    // Fired by the SDK after it auto-handled a Bearound silent push (swizzled). The app just
    // surfaces it — no push code in the AppDelegate.
    func didCompletePushScan(beaconsFound: Int, ingestStarted: Bool, pendingBatches: Int) {
        DispatchQueue.main.async {
            self.notificationManager.notifyPushTriggeredSync(
                beaconsFound: beaconsFound,
                ingestStarted: ingestStarted,
                pendingBatches: pendingBatches
            )
        }
    }

    // MARK: - Background Events Delegate Methods

    func didDetectBeaconInBackground(beacons: [Beacon]) {
        DispatchQueue.main.async {
            NSLog("[BeaconViewModel] Beacon detected in background: %d beacons", beacons.count)
            // No notification here — push is driven only by zone enter/exit transitions.
            self.recordDetections(beacons: beacons, isBackground: true)
        }
    }

    // MARK: - Detection Log

    private func recordDetections(beacons: [Beacon], isBackground: Bool) {
        guard !beacons.isEmpty else { return }

        let mode: DetectionMode
        if launchedFromTerminated && isBackground {
            mode = .terminated
        } else if isBackground && isDeviceLocked {
            mode = .backgroundLocked
        } else if isBackground {
            mode = .background
        } else {
            mode = .foreground
        }

        let newEntries = beacons.map { DetectionLogEntry.from(beacon: $0, mode: mode) }

        switch mode {
        case .terminated:
            terminatedLog.insert(contentsOf: newEntries, at: 0)
            trim(&terminatedLog, max: maxTerminatedLogEntries)
            // Process may be killed again within seconds — persist immediately.
            persistDetectionLog(synchronous: true)
        case .backgroundLocked:
            backgroundLockedLog.insert(contentsOf: newEntries, at: 0)
            trim(&backgroundLockedLog, max: maxBackgroundLockedLogEntries)
            scheduleDetectionLogSave()
        case .background:
            backgroundLog.insert(contentsOf: newEntries, at: 0)
            trim(&backgroundLog, max: maxBackgroundLogEntries)
            scheduleDetectionLogSave()
        case .foreground:
            foregroundLog.insert(contentsOf: newEntries, at: 0)
            trim(&foregroundLog, max: maxForegroundLogEntries)
            scheduleDetectionLogSave()
        }
    }

    private func trim(_ log: inout [DetectionLogEntry], max: Int) {
        if log.count > max {
            log = Array(log.prefix(max))
        }
    }

    func clearDetectionLog() {
        foregroundLog.removeAll()
        backgroundLog.removeAll()
        backgroundLockedLog.removeAll()
        terminatedLog.removeAll()
        saveWorkItem?.cancel()
        DetectionLogStore.clear()
    }

    // MARK: - Detection Log Persistence

    private func loadPersistedLogs() {
        let snapshot = DetectionLogStore.load()
        foregroundLog = snapshot.foreground
        backgroundLog = snapshot.background
        backgroundLockedLog = snapshot.backgroundLocked
        terminatedLog = snapshot.terminated
    }

    /// Coalesces frequent foreground/background detections into a single write ~1.5s later.
    private func scheduleDetectionLogSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistDetectionLog() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func persistDetectionLog(synchronous: Bool = false) {
        saveWorkItem?.cancel()
        let fg = foregroundLog, bg = backgroundLog, lk = backgroundLockedLog, tm = terminatedLog
        let save = {
            DetectionLogStore.save(foreground: fg, background: bg, backgroundLocked: lk, terminated: tm)
        }
        if synchronous {
            save()
        } else {
            DispatchQueue.global(qos: .utility).async(execute: save)
        }
    }

    // MARK: - Geofence / Location Capture Delegate (v2.4)

    func didEnterBeaconRegion() {
        DispatchQueue.main.async {
            let now = Date()
            self.isInBeaconRegion = true
            self.lastLocationEnter = now
            self.locationRegionEnterCount += 1
            self.appendGeofenceEvent(.init(
                kind: .regionEnter,
                timestamp: now,
                detail: "👁 LOCATION (esquerdo) — iOS reportou entrada na região (CLBeaconRegion)"
            ))
            self.notificationManager.notifyZoneEnter(eye: "Location")
        }
    }

    func didExitBeaconRegion() {
        DispatchQueue.main.async {
            let now = Date()
            self.isInBeaconRegion = false
            self.lastLocationExit = now
            self.appendGeofenceEvent(.init(
                kind: .regionExit,
                timestamp: now,
                detail: "👁 LOCATION (esquerdo) — iOS reportou saída da região"
            ))
            self.notificationManager.notifyZoneExit(eye: "Location")
        }
    }

    // MARK: - Bluetooth Zone Delegate (v2.5) — RIGHT EYE

    func didEnterBluetoothZone() {
        DispatchQueue.main.async {
            let now = Date()
            self.isInBluetoothZone = true
            self.lastBluetoothEnter = now
            self.bluetoothZoneEnterCount += 1
            self.appendGeofenceEvent(.init(
                kind: .bluetoothZoneEnter,
                timestamp: now,
                detail: "👁 BLUETOOTH (direito) — BLE detectou beacon (CBCentralManager)"
            ))
            self.notificationManager.notifyZoneEnter(eye: "Bluetooth")
        }
    }

    func didExitBluetoothZone() {
        DispatchQueue.main.async {
            let now = Date()
            self.isInBluetoothZone = false
            self.lastBluetoothExit = now
            self.appendGeofenceEvent(.init(
                kind: .bluetoothZoneExit,
                timestamp: now,
                detail: "👁 BLUETOOTH (direito) — zona vazia por 10s (graça expirou)"
            ))
            self.notificationManager.notifyZoneExit(eye: "Bluetooth")
        }
    }

    // v2.5 — Duty cycle mode transition (Bluetooth eye)
    // BluetoothManager flips between .idle (5min cycle) and .active (continuous + 10s tick).
    // SDK already dispatches this on main, but we wrap defensively anyway.
    func didChangeBluetoothScanMode(_ mode: BluetoothScanMode, nextIdleScanAt: Date?) {
        DispatchQueue.main.async {
            self.bluetoothScanMode = mode
            self.bluetoothNextIdleScanAt = nextIdleScanAt
        }
    }

    func didChangeActiveScanState(isActive: Bool) {
        DispatchQueue.main.async {
            self.isActiveScanRunning = isActive
            self.appendGeofenceEvent(.init(
                kind: isActive ? .scanResumed : .scanPaused,
                timestamp: Date(),
                detail: isActive
                    ? "Scan ativo (ranging + BLE) LIGADO"
                    : "Scan ativo (ranging + BLE) DESLIGADO — só region monitoring rodando"
            ))
        }
    }

    private func appendGeofenceEvent(_ event: GeofenceEvent) {
        geofenceEventLog.insert(event, at: 0)
        if geofenceEventLog.count > maxGeofenceLogEntries {
            geofenceEventLog = Array(geofenceEventLog.prefix(maxGeofenceLogEntries))
        }
    }

    func clearGeofenceLog() {
        geofenceEventLog.removeAll()
    }
}
