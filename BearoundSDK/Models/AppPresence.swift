//
//  AppPresence.swift
//  BearoundSDK
//
//  Public models, validation and build-evidence helpers for the app presence feature.
//  Cross-platform JSON contract: keys and enum raw values must match the Android SDK and
//  the Flutter / React Native wrappers exactly.
//

import CryptoKit
import Foundation

// MARK: - Configuration

/// A locally configured app the host wants to check for. At least one platform identifier
/// is expected; a target without the identifier for the running platform is reported as
/// `unknown` / `unsupported_platform`.
public struct AppPresenceTarget: Codable, Equatable, Hashable {
    /// Stable host-defined id: ASCII `[A-Za-z0-9._-]`, 1 to 64 characters, unique per configuration.
    public let id: String
    /// URL scheme (RFC 3986 scheme syntax, no `://`), declared in `LSApplicationQueriesSchemes`.
    public let iosScheme: String?
    /// Android package name, used only by the Android SDK.
    public let androidPackageName: String?

    public init(id: String, iosScheme: String? = nil, androidPackageName: String? = nil) {
        self.id = id
        self.iosScheme = iosScheme
        self.androidPackageName = androidPackageName
    }

    /// Scheme as compared by the SDK (case-insensitive).
    var normalizedIosScheme: String? { iosScheme?.lowercased() }
}

/// App presence feature configuration. Opt-in: the default value is disabled with no targets.
public struct AppPresenceConfiguration: Codable, Equatable {
    /// Maximum number of targets accepted in one configuration.
    public static let maximumTargets = 50
    /// Maximum length of a target id.
    public static let maximumTargetIdLength = 64

    public let enabled: Bool
    /// Targets in the host's order; results are delivered in this same order.
    public let targets: [AppPresenceTarget]

    public init(enabled: Bool = false, targets: [AppPresenceTarget] = []) {
        self.enabled = enabled
        self.targets = targets
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, targets
    }

    /// Missing keys restore the opt-in defaults (`enabled = false`, `targets = []`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        targets = try container.decodeIfPresent([AppPresenceTarget].self, forKey: .targets) ?? []
    }

    /// Validates ids, uniqueness, target count and platform identifiers.
    /// Throws ``AppPresenceConfigurationError`` on the first violation found.
    public func validate() throws {
        if targets.count > Self.maximumTargets {
            throw AppPresenceConfigurationError(.tooManyTargets(count: targets.count))
        }
        var seenIds = Set<String>()
        for (index, target) in targets.enumerated() {
            guard AppPresenceValidation.isValidTargetId(target.id) else {
                throw AppPresenceConfigurationError(.invalidTargetId(index: index))
            }
            guard seenIds.insert(target.id).inserted else {
                throw AppPresenceConfigurationError(.duplicateTargetId(target.id))
            }
            if let scheme = target.iosScheme {
                guard AppPresenceValidation.isValidSchemeSyntax(scheme) else {
                    throw AppPresenceConfigurationError(.invalidIosScheme(targetId: target.id))
                }
                guard !AppPresenceValidation.isForbiddenScheme(scheme) else {
                    throw AppPresenceConfigurationError(.forbiddenIosScheme(targetId: target.id))
                }
            }
            if let packageName = target.androidPackageName {
                guard AppPresenceValidation.isValidAndroidPackageName(packageName) else {
                    throw AppPresenceConfigurationError(.invalidAndroidPackageName(targetId: target.id))
                }
            }
        }
    }

    /// Lowercase hex SHA-256 of ``canonicalTargetsJSON``. Independent of the target order
    /// and of `enabled`.
    public var fingerprint: String {
        AppPresenceHashing.sha256Hex(Data(canonicalTargetsJSON.utf8))
    }

    /// Canonical JSON used for the fingerprint: an array of
    /// `{"androidPackageName":<string|null>,"id":<string>,"iosScheme":<string|null>}`
    /// objects sorted by `id` (byte order), keys sorted, no whitespace, `iosScheme` lowercased.
    var canonicalTargetsJSON: String {
        let sorted = targets.sorted { Array($0.id.utf8).lexicographicallyPrecedes(Array($1.id.utf8)) }
        let objects: [[String: Any]] = sorted.map { target in
            [
                "id": target.id,
                "iosScheme": target.normalizedIosScheme ?? NSNull(),
                "androidPackageName": target.androidPackageName ?? NSNull(),
            ]
        }
        let data = (try? JSONSerialization.data(
            withJSONObject: objects,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Raised when an ``AppPresenceConfiguration`` is rejected. Only the app presence feature is
/// disabled; the rest of the SDK keeps running. Never reported to error telemetry.
public struct AppPresenceConfigurationError: Error, Equatable, CustomStringConvertible {
    /// Stable cross-platform error code.
    public static let code = "app_presence_invalid_configuration"

    public enum Violation: Equatable {
        case tooManyTargets(count: Int)
        case invalidTargetId(index: Int)
        case duplicateTargetId(String)
        case invalidIosScheme(targetId: String)
        case forbiddenIosScheme(targetId: String)
        case invalidAndroidPackageName(targetId: String)
    }

    public let violation: Violation
    public var code: String { Self.code }

    public init(_ violation: Violation) {
        self.violation = violation
    }

    public var description: String {
        switch violation {
        case .tooManyTargets(let count):
            return "\(Self.code): \(count) targets exceeds the maximum of \(AppPresenceConfiguration.maximumTargets)"
        case .invalidTargetId(let index):
            return "\(Self.code): target at index \(index) has an invalid id (ASCII [A-Za-z0-9._-], 1-64 characters)"
        case .duplicateTargetId(let id):
            return "\(Self.code): duplicate target id \"\(id)\""
        case .invalidIosScheme(let id):
            return "\(Self.code): target \"\(id)\" has an invalid iosScheme (scheme name only, without \"://\")"
        case .forbiddenIosScheme(let id):
            return "\(Self.code): target \"\(id)\" uses a forbidden iosScheme (http/https)"
        case .invalidAndroidPackageName(let id):
            return "\(Self.code): target \"\(id)\" has an invalid androidPackageName"
        }
    }
}

enum AppPresenceValidation {
    static func isValidTargetId(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard !bytes.isEmpty, bytes.count <= AppPresenceConfiguration.maximumTargetIdLength else { return false }
        return bytes.allSatisfy { isAsciiAlphanumeric($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
    }

    /// RFC 3986: `scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`. Anything else,
    /// including `:`, `/`, `?` and spaces, is rejected.
    static func isValidSchemeSyntax(_ scheme: String) -> Bool {
        let bytes = Array(scheme.utf8)
        guard let first = bytes.first, isAsciiLetter(first) else { return false }
        return bytes.dropFirst().allSatisfy {
            isAsciiAlphanumeric($0) || $0 == UInt8(ascii: "+") || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: ".")
        }
    }

    static func isForbiddenScheme(_ scheme: String) -> Bool {
        let lowered = scheme.lowercased()
        return lowered == "http" || lowered == "https"
    }

    /// Dot-separated Java identifier segments (`[A-Za-z][A-Za-z0-9_]*`), at least two, no wildcard.
    static func isValidAndroidPackageName(_ name: String) -> Bool {
        let segments = name.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy { segment in
            let bytes = Array(segment.utf8)
            guard let first = bytes.first, isAsciiLetter(first) else { return false }
            return bytes.dropFirst().allSatisfy { isAsciiAlphanumeric($0) || $0 == UInt8(ascii: "_") }
        }
    }

    private static func isAsciiLetter(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
    }

    private static func isAsciiAlphanumeric(_ byte: UInt8) -> Bool {
        isAsciiLetter(byte) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
    }
}

enum AppPresenceHashing {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Results

public enum AppPresenceState: String, Codable, Equatable {
    case present
    case absent
    case unknown
}

public enum AppPresenceReason: String, Codable, Equatable {
    case notDeclared = "not_declared"
    case declarationUnverified = "declaration_unverified"
    case schemeBudgetExceeded = "scheme_budget_exceeded"
    case unsupportedPlatform = "unsupported_platform"
    case queryFailed = "query_failed"
}

public enum AppPresenceDetectionMethod: String, Codable, Equatable {
    case iosUrlScheme = "ios_url_scheme"
    case androidPackage = "android_package"
    case none
}

/// Result for one target. `present == true` means a handler for the declared scheme exists;
/// it does not verify the identity of the app behind it.
public struct AppPresenceResult: Codable, Equatable {
    public let targetId: String
    public let state: AppPresenceState
    public let reason: AppPresenceReason?
    /// Moment the decision for this target was made (UTC, millisecond precision).
    public let checkedAt: Date
    public let detectionMethod: AppPresenceDetectionMethod

    /// `true` for `present`, `false` for `absent`, `nil` for `unknown`.
    public var present: Bool? {
        switch state {
        case .present: return true
        case .absent: return false
        case .unknown: return nil
        }
    }

    public init(
        targetId: String,
        state: AppPresenceState,
        reason: AppPresenceReason? = nil,
        checkedAt: Date,
        detectionMethod: AppPresenceDetectionMethod
    ) {
        self.targetId = targetId
        self.state = state
        self.reason = reason
        self.checkedAt = AppPresenceTimestamp.truncatedToMilliseconds(checkedAt)
        self.detectionMethod = detectionMethod
    }

    private enum CodingKeys: String, CodingKey {
        case targetId, state, present, reason, checkedAt, detectionMethod
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetId = try container.decode(String.self, forKey: .targetId)
        state = try container.decode(AppPresenceState.self, forKey: .state)
        reason = try container.decodeIfPresent(AppPresenceReason.self, forKey: .reason)
        checkedAt = try AppPresenceTimestamp.decode(container, forKey: .checkedAt)
        detectionMethod = try container.decode(AppPresenceDetectionMethod.self, forKey: .detectionMethod)
    }

    /// `present` and `reason` are always written, as JSON `null` when absent.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(targetId, forKey: .targetId)
        try container.encode(state, forKey: .state)
        try container.encode(present, forKey: .present)
        try container.encode(reason, forKey: .reason)
        try container.encode(AppPresenceTimestamp.string(from: checkedAt), forKey: .checkedAt)
        try container.encode(detectionMethod, forKey: .detectionMethod)
    }
}

/// One completed round: every configured target exactly once, in the configured order.
public struct AppPresenceSnapshot: Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    /// Generated once per completed round; stable across cached replays.
    public let snapshotId: UUID
    public let configurationFingerprint: String
    /// Moment the round completed (UTC, millisecond precision).
    public let checkedAt: Date
    /// Delivery metadata: `true` when replayed from cache, not a new round.
    public let cached: Bool
    public let results: [AppPresenceResult]

    public init(
        snapshotId: UUID = UUID(),
        configurationFingerprint: String,
        checkedAt: Date,
        cached: Bool = false,
        results: [AppPresenceResult]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.snapshotId = snapshotId
        self.configurationFingerprint = configurationFingerprint
        self.checkedAt = AppPresenceTimestamp.truncatedToMilliseconds(checkedAt)
        self.cached = cached
        self.results = results
    }

    /// Same round delivered from cache: only `cached` changes.
    func markedCached() -> AppPresenceSnapshot {
        AppPresenceSnapshot(
            snapshotId: snapshotId,
            configurationFingerprint: configurationFingerprint,
            checkedAt: checkedAt,
            cached: true,
            results: results
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, snapshotId, configurationFingerprint, checkedAt, cached, results
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let rawId = try container.decode(String.self, forKey: .snapshotId)
        guard let id = UUID(uuidString: rawId) else {
            throw DecodingError.dataCorruptedError(forKey: .snapshotId, in: container, debugDescription: "Invalid UUID")
        }
        snapshotId = id
        configurationFingerprint = try container.decode(String.self, forKey: .configurationFingerprint)
        checkedAt = try AppPresenceTimestamp.decode(container, forKey: .checkedAt)
        cached = try container.decode(Bool.self, forKey: .cached)
        results = try container.decode([AppPresenceResult].self, forKey: .results)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(snapshotId.uuidString.lowercased(), forKey: .snapshotId)
        try container.encode(configurationFingerprint, forKey: .configurationFingerprint)
        try container.encode(AppPresenceTimestamp.string(from: checkedAt), forKey: .checkedAt)
        try container.encode(cached, forKey: .cached)
        try container.encode(results, forKey: .results)
    }
}

/// ISO 8601 UTC with milliseconds (`2026-10-09T12:34:56.789Z`), independent of the
/// encoder's date strategy.
enum AppPresenceTimestamp {
    private static let lock = NSLock()
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
    private static let withoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Floors to whole milliseconds. The small epsilon keeps the operation idempotent for
    /// values that are already whole milliseconds but not exactly representable in binary.
    static func truncatedToMilliseconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: millisecondsSince1970(date) / 1000)
    }

    /// Formats from integer milliseconds so binary rounding never turns `.123` into `.122`.
    static func string(from date: Date) -> String {
        let totalMilliseconds = Int64(millisecondsSince1970(date))
        var seconds = totalMilliseconds / 1000
        var milliseconds = totalMilliseconds % 1000
        if milliseconds < 0 {
            milliseconds += 1000
            seconds -= 1
        }
        lock.lock()
        let base = withoutFraction.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        lock.unlock()
        return String(base.dropLast()) + String(format: ".%03lldZ", milliseconds)
    }

    private static func millisecondsSince1970(_ date: Date) -> Double {
        (date.timeIntervalSince1970 * 1000 + 0.001).rounded(.down)
    }

    static func date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return withFraction.date(from: string) ?? withoutFraction.date(from: string)
    }

    static func decode<K: CodingKey>(_ container: KeyedDecodingContainer<K>, forKey key: K) throws -> Date {
        let raw = try container.decode(String.self, forKey: key)
        guard let date = date(from: raw) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Invalid ISO 8601 timestamp")
        }
        return truncatedToMilliseconds(date)
    }
}

// MARK: - Scheme budget and build evidence

/// Build evidence written into the host's Info.plist under
/// ``AppPresenceSchemeBudget/buildEvidenceInfoPlistKey`` by the build verifier.
public struct AppPresenceBuildEvidence: Equatable {
    public let bundleId: String
    public let linkedSdkMajor: Int
    /// ``AppPresenceSchemeBudget/schemesSha256(_:)`` of the full `LSApplicationQueriesSchemes`.
    public let schemesSha256: String

    public init(bundleId: String, linkedSdkMajor: Int, schemesSha256: String) {
        self.bundleId = bundleId
        self.linkedSdkMajor = linkedSdkMajor
        self.schemesSha256 = schemesSha256
    }

    /// Parses the Info.plist dictionary value. Returns nil for any missing or mistyped field.
    public init?(infoPlistValue: Any?) {
        guard let dictionary = infoPlistValue as? [String: Any],
              let bundleId = dictionary["bundleId"] as? String,
              let major = dictionary["linkedSdkMajor"] as? NSNumber,
              CFGetTypeID(major) != CFBooleanGetTypeID(),
              let hash = dictionary["schemesSha256"] as? String else { return nil }
        self.init(bundleId: bundleId, linkedSdkMajor: major.intValue, schemesSha256: hash)
    }
}

/// Ceiling on the host's `LSApplicationQueriesSchemes` (the whole list, not only SDK targets).
/// The runtime never widens the ceiling based on the OS version: 25 unless verifiable build
/// evidence shows a linked SDK older than iOS 27, which allows 50.
public enum AppPresenceSchemeBudget {
    public static let conservativeCeiling = 25
    public static let extendedCeiling = 50
    /// First linked SDK major that drops the ceiling to 25.
    public static let reducedCeilingSdkMajor = 27
    public static let buildEvidenceInfoPlistKey = "BeAroundAppPresenceBuildEvidence"
    public static let queriesSchemesInfoPlistKey = "LSApplicationQueriesSchemes"

    /// Declared schemes, lowercased, in Info.plist order (duplicates kept).
    public static func declaredSchemes(infoPlist: [String: Any]) -> [String] {
        guard let raw = infoPlist[queriesSchemesInfoPlistKey] as? [Any] else { return [] }
        return raw.compactMap { ($0 as? String)?.lowercased() }
    }

    /// Lowercase hex SHA-256 of the normalized full scheme list: each entry lowercased,
    /// sorted ascending (byte order), duplicates kept, joined with `\n`, UTF-8.
    /// The build verifier must compute the same value.
    public static func schemesSha256(_ schemes: [String]) -> String {
        let normalized = schemes
            .map { $0.lowercased() }
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            .joined(separator: "\n")
        return AppPresenceHashing.sha256Hex(Data(normalized.utf8))
    }

    /// 50 only when the evidence matches `bundleIdentifier`, the current scheme list, and a
    /// linked SDK major below 27; otherwise 25.
    public static func ceiling(infoPlist: [String: Any], bundleIdentifier: String?) -> Int {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              let evidence = AppPresenceBuildEvidence(infoPlistValue: infoPlist[buildEvidenceInfoPlistKey]),
              evidence.bundleId == bundleIdentifier,
              evidence.linkedSdkMajor > 0,
              evidence.linkedSdkMajor < reducedCeilingSdkMajor,
              evidence.schemesSha256.lowercased() == schemesSha256(declaredSchemes(infoPlist: infoPlist))
        else { return conservativeCeiling }
        return extendedCeiling
    }

    /// True when the host's full scheme list exceeds the validated ceiling.
    public static func isExceeded(infoPlist: [String: Any], bundleIdentifier: String?) -> Bool {
        declaredSchemes(infoPlist: infoPlist).count > ceiling(infoPlist: infoPlist, bundleIdentifier: bundleIdentifier)
    }
}
