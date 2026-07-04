//
//  ErrorReporter.swift
//  BearoundSDK
//
//  Created by Bearound on 04/07/26.
//
//  First-party crash/error telemetry for the Bearound iOS SDK. This is the iOS
//  counterpart of the Android `io.bearound.sdk.telemetry.ErrorReporter` and MUST
//  keep behavioral parity with it. The contract (endpoint, JSON body, golden
//  rules) is identical across platforms so the backend can treat both the same.
//
//  GOLDEN RULES (identical to Android):
//    1. NEVER throw, NEVER break the host, NEVER hijack the app's crash handler.
//    2. Only report errors originating in OUR library (filter by image/module in
//       the stack). Exclude the telemetry module itself.
//    3. The global handler is ALWAYS chained: keep the previous handler and always
//       delegate to it.
//    4. Fire-and-forget, rate-limited + de-duplicated (hash of type|context|first
//       stack line), stack capped at 8000 chars.
//    5. Own isolated transport; short timeouts.
//    6. Public opt-out `setErrorReportingEnabled(_:)`, default ON.
//

import CoreBluetooth
import CoreLocation
import Foundation
import UIKit

/// Fire-and-forget reporter that ships SDK-internal errors (and uncaught NSExceptions
/// raised inside our library) to `POST {ingest}/sdk-errors`.
///
/// It never throws and never affects the host app: every probe is wrapped in
/// `try?`/`do-catch`, the uncaught-exception handler is chained (the previous handler
/// is always invoked), and network delivery is best-effort with a short timeout.
final class ErrorReporter {

    static let shared = ErrorReporter()

    // MARK: - Constants (parity with Android)

    /// The stack-frame image name that identifies frames belonging to OUR library.
    /// `NSException.callStackSymbols` prints the Mach-O image name per frame; a frame
    /// from our binary contains "BearoundSDK". This is how we honor golden rule #2.
    private static let ourImageName = "BearoundSDK"

    /// Errors are ignored once this many have been sent within the rolling hour.
    private static let maxReportsPerHour = 20

    /// A given (type|context|firstStackLine) hash is sent at most once per this window.
    private static let dedupeWindow: TimeInterval = 5 * 60

    /// Hard cap on the serialized stack trace (parity with Android's 8000-char cap).
    private static let stackTraceCap = 8000

    /// Short timeout — telemetry must never hold resources or block on a slow network.
    private static let requestTimeout: TimeInterval = 5

    /// Path appended to the ingest base URL. The full URL is `{apiBaseURL}/sdk-errors`.
    private static let path = "/sdk-errors"

    // MARK: - State

    private let lock = NSLock()

    /// Opt-out flag. Default ON (parity with Android). Guarded by `lock`.
    private var enabled = true

    /// Set once `install(...)` has wired the uncaught-exception handler. Guarded by `lock`.
    private var handlerInstalled = false

    /// Business token used as the `Authorization` header (may be empty — endpoint is open).
    private var businessToken: String = ""

    /// Ingest base URL (e.g. `https://ingest.bearound.io`). Defaults to the SDK config value.
    private var apiBaseURL: String = "https://ingest.bearound.io"

    /// SDK version reported in the `sdk` block. Defaults to `BeAroundSDK.version`.
    private var sdkVersion: String = BeAroundSDK.version

    /// Origin technology (`ios-native` | `flutter` | `react-native`). Mapped to `sdk.platform`.
    private var technology: String = "ios-native"

    /// App bundle id reported as `sdk.appId`.
    private var appId: String = Bundle.main.bundleIdentifier ?? "unknown"

    /// Rolling send timestamps (rate limit). Guarded by `lock`.
    private var recentSendTimes: [Date] = []

    /// Last-seen time per dedupe hash. Guarded by `lock`.
    private var lastSentByHash: [String: Date] = [:]

    /// The uncaught-exception handler that was installed before us. Always chained to.
    /// Stored as a static so it survives even if `shared` were ever torn down (it isn't).
    private static var previousExceptionHandler: (@convention(c) (NSException) -> Void)?

    /// Isolated URLSession for telemetry — never the SDK's background upload session.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = ErrorReporter.requestTimeout
        config.timeoutIntervalForResource = ErrorReporter.requestTimeout
        config.waitsForConnectivity = false
        config.allowsCellularAccess = true
        return URLSession(configuration: config)
    }()

    /// Own DeviceInfoCollector — the SDK's instance is private, so we keep our own. It is
    /// only used to build the device snapshot (reuse of the existing collector, golden rule:
    /// reuse-first) and never touches scan/sync state.
    private let deviceInfoCollector = DeviceInfoCollector(isColdStart: false)

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private init() {}

    // MARK: - Public opt-out

    /// Enables/disables error reporting. Default ON. Disabling does NOT uninstall the chained
    /// uncaught-exception handler (that must always remain to delegate to the previous one);
    /// it only short-circuits report delivery.
    func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        lock.unlock()
    }

    // MARK: - Install

    /// Idempotently installs the chained `NSSetUncaughtExceptionHandler`. Safe to call from
    /// both `configure(...)` and `autoConfigureFromStorage()` — only the first call wires the
    /// handler; later calls just refresh the token/metadata.
    ///
    /// - Parameters:
    ///   - businessToken: sent as the `Authorization` header (may be empty; endpoint is open).
    ///   - apiBaseURL: ingest base URL; if nil, the previously stored/default value is kept.
    ///   - technology: origin technology from `SDKInfo`/config (ios-native/flutter/react-native).
    ///   - sdkVersion: SDK version string; if nil, the default `BeAroundSDK.version` is kept.
    func install(
        businessToken: String,
        apiBaseURL: String? = nil,
        technology: String? = nil,
        sdkVersion: String? = nil
    ) {
        lock.lock()
        self.businessToken = businessToken
        if let apiBaseURL, !apiBaseURL.isEmpty { self.apiBaseURL = apiBaseURL }
        if let technology, !technology.isEmpty { self.technology = technology }
        if let sdkVersion, !sdkVersion.isEmpty { self.sdkVersion = sdkVersion }
        self.appId = Bundle.main.bundleIdentifier ?? "unknown"

        // Idempotent: install the handler exactly once.
        guard !handlerInstalled else {
            lock.unlock()
            return
        }
        handlerInstalled = true
        lock.unlock()

        // Chain the handler: capture whoever is installed now (Crashlytics/Sentry/host) and
        // ALWAYS delegate to it from inside our handler (golden rule #3).
        ErrorReporter.previousExceptionHandler = NSGetUncaughtExceptionHandler()

        NSSetUncaughtExceptionHandler { exception in
            // This closure runs in a crash context — do NOT dispatch async, do NOT allocate
            // more than necessary. Everything is wrapped so we never make the crash worse.
            ErrorReporter.shared.handleUncaught(exception)

            // Golden rule #3: always delegate to the previously installed handler.
            ErrorReporter.previousExceptionHandler?(exception)
        }

        // TODO(signal-capture): We deliberately do NOT install POSIX signal handlers
        // (SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGTRAP) in this version. A signal handler is
        // process-global and single-slot per signal; installing ours would clash with the
        // host's crash reporter (Crashlytics/Sentry/Bugsnag), which also chains signal
        // handlers, and a mis-timed handler in a corrupted process can deadlock or re-crash.
        // NSException coverage (Obj-C exceptions + our internal Swift errors reported via
        // `report(_:context:)`) is safe and sufficient here. Signal capture, if ever added,
        // must be strictly chained and async-signal-safe.
    }

    // MARK: - Uncaught exception path

    /// Handles an uncaught `NSException`. Reports ONLY if a stack frame belongs to our library
    /// (golden rule #2). Runs a SHORT SYNCHRONOUS POST because the process is about to die — a
    /// GCD-async dispatch would never fire. Fully guarded; never rethrows.
    ///
    /// Every operation below is non-throwing by construction (no `try`), so there is no Swift
    /// error to catch — the "never destabilize the crash path" guarantee is upheld by using only
    /// total, side-effect-safe operations here (no force-unwraps, no async, short bounded POST).
    private func handleUncaught(_ exception: NSException) {
        let symbols = exception.callStackSymbols
        guard crashOriginatedInOurLibrary(symbols) else { return }

        guard isEnabledSnapshot() else { return }

        let stack = symbols.joined(separator: "\n")
        let type = exception.name.rawValue
        let message = exception.reason ?? ""
        let firstLine = symbols.first ?? ""

        guard shouldSend(type: type, context: "uncaught", firstStackLine: firstLine) else { return }

        let payload = buildPayload(
            type: type,
            message: message,
            stackTrace: stack,
            context: "uncaught"
        )
        sendSynchronously(payload)
    }

    // MARK: - Internal-error path

    /// Fire-and-forget report of an SDK-internal error. Called alongside
    /// `DiagnosticsStore.shared.recordError(...)` at the SDK's internal error sites.
    ///
    /// This path is for OUR errors surfaced through delegate/diagnostics — it does NOT filter
    /// by stack image (the call site already proves origin). Normal operational network errors
    /// from `APIClient` are intentionally NOT wired here (see BearoundSDK.swift call sites).
    func report(_ error: Error, context: String) {
        // Snapshot enablement/install without holding the lock across the network call.
        guard isEnabledSnapshot() else { return }

        let nsError = error as NSError
        let type = "\(nsError.domain)#\(nsError.code)"
        let message = error.localizedDescription

        // Swift errors don't carry a call stack; use the current one, capturing our frames.
        let symbols = Thread.callStackSymbols
        let stack = symbols.joined(separator: "\n")
        let firstLine = symbols.first ?? ""

        guard shouldSend(type: type, context: context, firstStackLine: firstLine) else { return }

        let payload = buildPayload(
            type: type,
            message: message,
            stackTrace: stack,
            context: context
        )
        sendAsync(payload)
    }

    // MARK: - Filtering / rate limit / dedupe

    private func isEnabledSnapshot() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && handlerInstalled
    }

    /// Apple runtime / system-framework image names that are never "the culprit" of a
    /// crash — the exception machinery and OS frameworks a real bug surfaces THROUGH.
    private static let systemImagePrefixes = [
        "libswift", "libsystem", "libc++", "libobjc", "libdispatch", "libdyld",
        "dyld", "libnetwork", "libboringssl", "libxpc", "libMobileGestalt",
    ]
    private static let systemImageNames: Set<String> = [
        "Foundation", "CoreFoundation", "CFNetwork", "UIKit", "UIKitCore", "SwiftUI",
        "CoreServices", "CoreBluetooth", "CoreLocation", "CoreGraphics", "QuartzCore",
        "GraphicsServices", "Security", "CoreData", "Combine", "os", "AttributeGraph",
        "Network",
    ]

    /// Reports ONLY when the crash ORIGINATED in our library — never a host-app crash.
    ///
    /// Ownership = the FIRST application frame (skipping Apple runtime/framework images,
    /// e.g. the CoreFoundation/libobjc exception machinery on top) reading down the stack.
    /// A host crash that merely passes THROUGH one of our callbacks has the host app's own
    /// image as that first application frame — the old "any frame mentions BearoundSDK"
    /// test captured those (a privacy leak of the host's errors); this origin test does not.
    /// If the first application frame cannot be resolved as ours, we do NOT report.
    private func crashOriginatedInOurLibrary(_ symbols: [String]) -> Bool {
        for frame in symbols {
            guard let image = imageName(of: frame) else { continue }
            if ErrorReporter.isSystemImage(image) { continue }
            // First application frame decides ownership.
            return image == ErrorReporter.ourImageName
        }
        return false
    }

    /// Extracts the Mach-O image name from a `callStackSymbols` line, whose format is
    /// `<index>  <imageName>  0x<address>  <symbol> + <offset>` — the image is token #1.
    private func imageName(of frame: String) -> String? {
        let parts = frame.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    private static func isSystemImage(_ image: String) -> Bool {
        if systemImageNames.contains(image) { return true }
        return systemImagePrefixes.contains { image.hasPrefix($0) }
    }

    /// Combined rate-limit + dedupe gate. Returns true if this event may be sent now and
    /// records the decision. Guarded by `lock`.
    private func shouldSend(type: String, context: String, firstStackLine: String) -> Bool {
        let now = Date()
        let hash = Self.dedupeHash(technologySnapshot(), context, firstStackLine, type)

        lock.lock(); defer { lock.unlock() }

        // Dedupe: same signature within the window is dropped.
        if let last = lastSentByHash[hash], now.timeIntervalSince(last) < ErrorReporter.dedupeWindow {
            return false
        }

        // Rate limit: prune to the last hour, then cap.
        let oneHourAgo = now.addingTimeInterval(-3600)
        recentSendTimes.removeAll { $0 < oneHourAgo }
        if recentSendTimes.count >= ErrorReporter.maxReportsPerHour {
            return false
        }

        recentSendTimes.append(now)
        lastSentByHash[hash] = now
        return true
    }

    private func technologySnapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return technology
    }

    /// sha256(platform|context|firstStackLine|type) as a lowercase hex string.
    /// Uses only Foundation (no CryptoKit dependency, keeps iOS 13 support).
    private static func dedupeHash(_ platform: String, _ context: String, _ firstStackLine: String, _ type: String) -> String {
        let input = "\(platform)|\(context)|\(firstStackLine)|\(type)"
        return SHA256Fallback.hexDigest(input)
    }

    // MARK: - Payload

    private func buildPayload(type: String, message: String, stackTrace: String, context: String) -> [String: Any] {
        let cappedStack = String(stackTrace.prefix(ErrorReporter.stackTraceCap))

        let errorBlock: [String: Any] = [
            "type": type,
            "message": message,
            "stackTrace": cappedStack,
            "context": context,
        ]

        lock.lock()
        let version = sdkVersion
        let tech = technology
        let bundleId = appId
        lock.unlock()

        let sdkBlock: [String: Any] = [
            "version": version,
            // `platform` here mirrors the origin technology (ios | flutter | react-native),
            // matching the capture contract, while the SDK is always the iOS binary.
            "platform": tech,
            "appId": bundleId,
        ]

        return [
            "error": errorBlock,
            "device": buildDeviceSnapshot(),
            "sdk": sdkBlock,
            "occurredAt": iso.string(from: Date()),
        ]
    }

    /// Builds the `device` block by REUSING `DeviceInfoCollector.collectDeviceInfo(...)` and
    /// probing permissions/system state independently. Every probe is isolated: a failing probe
    /// is simply omitted, never fatal.
    private func buildDeviceSnapshot() -> [String: Any] {
        var device: [String: Any] = [:]

        // --- Location authorization (reused from BeAroundSDK) ---
        let locationStatus: CLAuthorizationStatus? = {
            BeAroundSDK.authorizationStatus()
        }()

        // --- Bluetooth state ---
        let bluetoothStateString = bluetoothStateForCollector()

        // Reuse the existing collector for device + notifications-permission-from-cache.
        let userDevice: UserDevice? = {
            guard let locationStatus else { return nil }
            return deviceInfoCollector.collectDeviceInfo(
                locationPermission: locationStatus,
                bluetoothState: bluetoothStateString,
                appInForeground: appInForegroundSafe()
            )
        }()

        if let userDevice {
            device["deviceId"] = userDevice.deviceId
            device["model"] = userDevice.model
            device["manufacturer"] = userDevice.manufacturer
            device["os"] = userDevice.os ?? "iOS"
            device["osVersion"] = userDevice.osVersion
            device["appState"] = userDevice.appInForeground ? "foreground" : "background"
        } else {
            // Minimal fallback if the collector could not run.
            device["manufacturer"] = "Apple"
            device["os"] = "iOS"
            device["osVersion"] = UIDevice.current.systemVersion
            device["appState"] = appInForegroundSafe() ? "foreground" : "background"
        }

        device["locale"] = Locale.current.identifier

        // --- permissions block (per iOS) ---
        var permissions: [String: Any] = [:]

        // Bluetooth authorization (distinct from powered-on state).
        if #available(iOS 13.1, *) {
            permissions["bluetooth"] = bluetoothAuthorizationString()
        }

        if let locationStatus {
            let whenInUse = (locationStatus == .authorizedWhenInUse || locationStatus == .authorizedAlways)
            permissions["locationWhenInUse"] = whenInUse
            permissions["fineLocation"] = whenInUse
            permissions["locationAlways"] = (locationStatus == .authorizedAlways)
        }

        // Notifications — reuse the collector's cached value (avoids a fresh async probe here).
        if let userDevice {
            permissions["notifications"] = userDevice.notificationsPermission
        }

        if !permissions.isEmpty {
            device["permissions"] = permissions
        }

        // --- systemState block ---
        var systemState: [String: Any] = [:]

        if let poweredOn = bluetoothPoweredOnSafe() {
            systemState["bluetoothPoweredOn"] = poweredOn
        }

        systemState["locationServicesEnabled"] = CLLocationManager.locationServicesEnabled()

        if let notificationsEnabled = userDevice.map({ $0.notificationsPermission == "authorized" }) {
            systemState["notificationsEnabled"] = notificationsEnabled
        }

        if !systemState.isEmpty {
            device["systemState"] = systemState
        }

        return device
    }

    // MARK: - Isolated probes (each guarded)

    private func appInForegroundSafe() -> Bool {
        // UIApplication.applicationState must be read on the main thread.
        if Thread.isMainThread {
            return UIApplication.shared.applicationState != .background
        }
        var result = true
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            result = UIApplication.shared.applicationState != .background
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 0.2)
        return result
    }

    /// Maps CBCentralManager power state to the "powered_on"/"powered_off" string the collector
    /// expects. Uses `.authorization` (static, cheap) plus a transient manager read guarded so a
    /// failure just yields "powered_off".
    private func bluetoothStateForCollector() -> String {
        return (bluetoothPoweredOnSafe() ?? false) ? "powered_on" : "powered_off"
    }

    /// Best-effort read of the radio power state. Returns nil if it cannot be determined.
    private func bluetoothPoweredOnSafe() -> Bool? {
        // Instantiating CBCentralManager with a nil delegate and no options does not prompt for
        // permission and reads the current adapter state synchronously enough for a snapshot.
        let manager = CBCentralManager()
        switch manager.state {
        case .poweredOn: return true
        case .poweredOff, .resetting, .unauthorized, .unsupported, .unknown: return false
        @unknown default: return nil
        }
    }

    @available(iOS 13.1, *)
    private func bluetoothAuthorizationString() -> String {
        switch CBCentralManager.authorization {
        case .allowedAlways: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Transport

    /// Async fire-and-forget delivery (used on the internal-error path).
    private func sendAsync(_ payload: [String: Any]) {
        guard let request = makeRequest(payload) else { return }
        let task = session.dataTask(with: request) { _, _, _ in
            // Fire-and-forget: ignore result. Never retry, never surface.
        }
        task.resume()
    }

    /// Synchronous, short delivery (used on the uncaught-exception path, where the process is
    /// about to terminate and an async task would never run). Bounded by the request timeout.
    private func sendSynchronously(_ payload: [String: Any]) {
        guard let request = makeRequest(payload) else { return }
        let sem = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { _, _, _ in
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + ErrorReporter.requestTimeout)
    }

    private func makeRequest(_ payload: [String: Any]) -> URLRequest? {
        lock.lock()
        let base = apiBaseURL
        let token = businessToken
        lock.unlock()

        guard let url = URL(string: "\(base)\(ErrorReporter.path)") else { return nil }

        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Token is optional (open endpoint) — only set it when we actually have one.
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        request.timeoutInterval = ErrorReporter.requestTimeout
        return request
    }
}

// MARK: - SHA256 (Foundation-only, iOS 13 compatible)

/// Minimal SHA-256 used only for the dedupe hash. Kept dependency-free (no CryptoKit) so the
/// telemetry module never widens the SDK's minimum deployment or import surface.
private enum SHA256Fallback {
    static func hexDigest(_ input: String) -> String {
        let bytes = Array(input.utf8)
        let digest = sha256(bytes)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [
            0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
            0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
        ]
        let k: [UInt32] = [
            0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
            0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
            0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
            0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
            0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
            0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
            0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
            0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
        ]

        var message = message
        let originalBitLength = UInt64(message.count) * 8

        // Padding.
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0x00)
        }
        for i in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((originalBitLength >> UInt64(i)) & 0xff))
        }

        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
            return (x >> n) | (x << (32 - n))
        }

        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let j = chunkStart + i * 4
                w[i] = (UInt32(message[j]) << 24)
                    | (UInt32(message[j + 1]) << 16)
                    | (UInt32(message[j + 2]) << 8)
                    | UInt32(message[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]

            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                hh = g; g = f; f = e
                e = d &+ temp1
                d = c; c = b; b = a
                a = temp1 &+ temp2
            }

            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }

        var digest = [UInt8]()
        for value in h {
            digest.append(UInt8((value >> 24) & 0xff))
            digest.append(UInt8((value >> 16) & 0xff))
            digest.append(UInt8((value >> 8) & 0xff))
            digest.append(UInt8(value & 0xff))
        }
        return digest
    }
}
