//
//  AppPresenceModelsTests.swift
//  BearoundSDKTests
//
//  App presence models: opt-in defaults, legacy restore, validation, JSON nulls,
//  configuration fingerprint and the LSApplicationQueriesSchemes ceiling.
//

import CryptoKit
import Foundation
import Testing

@testable import BearoundSDK

// Storage tests use a private UserDefaults suite per test, never the shared
// "com.bearound.sdk.config" suite, so they cannot race SDKConfigStorageTests.
@Suite("AppPresence Models Tests")
struct AppPresenceModelsTests {

    // MARK: - Helpers

    private func target(_ id: String, ios: String? = nil, android: String? = nil) -> AppPresenceTarget {
        AppPresenceTarget(id: id, iosScheme: ios, androidPackageName: android)
    }

    private func violation(of configuration: AppPresenceConfiguration) -> AppPresenceConfigurationError.Violation? {
        do {
            try configuration.validate()
            return nil
        } catch let error as AppPresenceConfigurationError {
            return error.violation
        } catch {
            Issue.record("Unexpected error type: \(error)")
            return nil
        }
    }

    private func isolatedStore() -> (UserDefaults, String) {
        let name = "io.bearound.tests.app-presence.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Opt-in and legacy

    @Test("Default configuration is opt-in: disabled with no targets")
    func defaultIsOptIn() throws {
        let configuration = AppPresenceConfiguration()
        #expect(configuration.enabled == false)
        #expect(configuration.targets.isEmpty)
        try configuration.validate()
    }

    @Test("JSON without the new keys decodes to the opt-in default")
    func decodingMissingKeysRestoresDefault() throws {
        let decoded = try JSONDecoder().decode(AppPresenceConfiguration.self, from: Data("{}".utf8))
        #expect(decoded == AppPresenceConfiguration())
    }

    @Test("Legacy persisted SDK config without the app presence key restores disabled")
    func legacyStoredConfigRestoresDisabled() {
        let (store, name) = isolatedStore()
        defer { store.removePersistentDomain(forName: name) }
        // Shape of an install persisted by 3.15.0: SDK keys only.
        store.set("legacy-token", forKey: "business_token")
        store.set("high", forKey: "scan_precision")
        store.set(true, forKey: "collect_wifi")
        store.set(true, forKey: "is_configured")

        let restored = SDKConfigStorage.loadAppPresenceConfiguration(store: store)

        #expect(restored.enabled == false)
        #expect(restored.targets.isEmpty)
    }

    @Test("Stored configuration round-trips; unreadable or invalid data restores disabled")
    func storageRoundTripAndFailClosed() {
        let (store, name) = isolatedStore()
        defer { store.removePersistentDomain(forName: name) }
        let configuration = AppPresenceConfiguration(
            enabled: true,
            targets: [target("fixture", ios: "bearound-presence-fixture", android: "io.bearound.fixture.presence")]
        )

        SDKConfigStorage.saveAppPresenceConfiguration(configuration, store: store)
        #expect(SDKConfigStorage.loadAppPresenceConfiguration(store: store) == configuration)

        store.set(Data("not json".utf8), forKey: "app_presence_configuration")
        #expect(SDKConfigStorage.loadAppPresenceConfiguration(store: store) == AppPresenceConfiguration())

        let invalid = #"{"enabled":true,"targets":[{"id":"a","iosScheme":"https"}]}"#
        store.set(Data(invalid.utf8), forKey: "app_presence_configuration")
        #expect(SDKConfigStorage.loadAppPresenceConfiguration(store: store) == AppPresenceConfiguration())

        SDKConfigStorage.saveAppPresenceConfiguration(configuration, store: store)
        SDKConfigStorage.clearAppPresenceConfiguration(store: store)
        #expect(SDKConfigStorage.loadAppPresenceConfiguration(store: store) == AppPresenceConfiguration())
    }

    @Test("SDK configuration defaults and public init are unchanged")
    func sdkConfigurationDefaultsPreserved() {
        let config = SDKConfiguration(businessToken: "t")
        #expect(config.collectAdvertisingId)
        #expect(config.collectLocation)
        #expect(config.collectWifi)
    }

    // MARK: - Validation: ids and count

    @Test("Valid configuration with ids at the boundaries passes")
    func validBoundaries() throws {
        let longId = String(repeating: "a", count: 64)
        let configuration = AppPresenceConfiguration(enabled: true, targets: [
            target("A.b_c-9", ios: "bearound-presence-fixture"),
            target(longId, android: "io.bearound.fixture.presence"),
            target("x"),
        ])
        try configuration.validate()
    }

    @Test("Invalid ids are rejected", arguments: ["", String(repeating: "a", count: 65), "has space", "slash/id", "acentuação", "emoji🙂", "colon:id"])
    func invalidIds(_ id: String) {
        let configuration = AppPresenceConfiguration(enabled: true, targets: [target(id, ios: "fixture")])
        #expect(violation(of: configuration) == .invalidTargetId(index: 0))
    }

    @Test("Duplicate ids are rejected")
    func duplicateIds() {
        let configuration = AppPresenceConfiguration(enabled: true, targets: [
            target("dup", ios: "one"),
            target("dup", ios: "two"),
        ])
        #expect(violation(of: configuration) == .duplicateTargetId("dup"))
    }

    @Test("Same identifier under different ids is allowed")
    func sharedIdentifierAllowed() throws {
        try AppPresenceConfiguration(enabled: true, targets: [
            target("a", ios: "fixture", android: "io.bearound.fixture.presence"),
            target("b", ios: "FIXTURE", android: "io.bearound.fixture.presence"),
        ]).validate()
    }

    @Test("50 targets pass, 51 are rejected")
    func maximumTargets() throws {
        let fifty = (0..<50).map { target("t\($0)", ios: "scheme\($0)") }
        try AppPresenceConfiguration(enabled: true, targets: fifty).validate()

        let fiftyOne = fifty + [target("t50", ios: "scheme50")]
        #expect(violation(of: AppPresenceConfiguration(enabled: true, targets: fiftyOne)) == .tooManyTargets(count: 51))
    }

    // MARK: - Validation: iOS scheme

    @Test("Valid iOS schemes pass", arguments: ["fixture", "bearound-presence-fixture", "a1+b.c-d", "FixtureApp", "x"])
    func validSchemes(_ scheme: String) throws {
        try AppPresenceConfiguration(enabled: true, targets: [target("id", ios: scheme)]).validate()
    }

    @Test("Malformed iOS schemes are rejected", arguments: [
        "", "fixture://", "fixture:", "fixture://path", "fixture/path", "fixture?x=1", "fix ture", " fixture", "1fixture", "-fixture", "fíxture",
    ])
    func malformedSchemes(_ scheme: String) {
        let configuration = AppPresenceConfiguration(enabled: true, targets: [target("id", ios: scheme)])
        #expect(violation(of: configuration) == .invalidIosScheme(targetId: "id"))
    }

    @Test("http and https are forbidden in any case", arguments: ["http", "https", "HTTP", "Https"])
    func forbiddenSchemes(_ scheme: String) {
        let configuration = AppPresenceConfiguration(enabled: true, targets: [target("id", ios: scheme)])
        #expect(violation(of: configuration) == .forbiddenIosScheme(targetId: "id"))
    }

    // MARK: - Validation: Android package

    @Test("Valid Android package names pass", arguments: ["io.bearound.fixture.presence", "a.b", "com.Example_1.app2"])
    func validPackages(_ name: String) throws {
        try AppPresenceConfiguration(enabled: true, targets: [target("id", android: name)]).validate()
    }

    @Test("Malformed Android package names are rejected", arguments: [
        "", "single", "io.bearound.*", "io.*.app", "io..app", ".io.app", "io.app.", "io.1app", "io.app-name", "io.app name", "io._app",
    ])
    func malformedPackages(_ name: String) {
        let configuration = AppPresenceConfiguration(enabled: true, targets: [target("id", android: name)])
        #expect(violation(of: configuration) == .invalidAndroidPackageName(targetId: "id"))
    }

    @Test("Target without the platform identifier is allowed")
    func missingPlatformIdentifierAllowed() throws {
        try AppPresenceConfiguration(enabled: true, targets: [target("android-only", android: "io.bearound.fixture.presence")]).validate()
    }

    @Test("Error exposes the stable cross-platform code")
    func errorCode() {
        #expect(AppPresenceConfigurationError.code == "app_presence_invalid_configuration")
        let error = AppPresenceConfigurationError(.duplicateTargetId("a"))
        #expect(error.code == "app_presence_invalid_configuration")
        #expect(error.description.hasPrefix("app_presence_invalid_configuration"))
    }

    // MARK: - JSON encoding

    @Test("Unknown result encodes explicit present:null and reason:null")
    func explicitNulls() throws {
        let date = Date(timeIntervalSince1970: 1_791_547_200.1239)
        let unknown = AppPresenceResult(targetId: "a", state: .unknown, reason: nil, checkedAt: date, detectionMethod: .none)
        let json = try jsonObject(unknown)

        #expect(Set(json.keys) == ["targetId", "state", "present", "reason", "checkedAt", "detectionMethod"])
        #expect(json["present"] is NSNull)
        #expect(json["reason"] is NSNull)
        #expect(json["state"] as? String == "unknown")
        #expect(json["detectionMethod"] as? String == "none")
        #expect(json["checkedAt"] as? String == "2026-10-09T12:00:00.123Z")
    }

    @Test("Present, absent and reasoned results encode the contract values")
    func resultValues() throws {
        let date = Date(timeIntervalSince1970: 0)
        let present = try jsonObject(AppPresenceResult(targetId: "a", state: .present, checkedAt: date, detectionMethod: .iosUrlScheme))
        #expect(present["present"] as? Bool == true)
        #expect(present["reason"] is NSNull)
        #expect(present["detectionMethod"] as? String == "ios_url_scheme")
        #expect(present["checkedAt"] as? String == "1970-01-01T00:00:00.000Z")

        let absent = try jsonObject(AppPresenceResult(targetId: "a", state: .absent, checkedAt: date, detectionMethod: .androidPackage))
        #expect(absent["present"] as? Bool == false)
        #expect(absent["detectionMethod"] as? String == "android_package")

        let budget = try jsonObject(AppPresenceResult(targetId: "a", state: .unknown, reason: .schemeBudgetExceeded, checkedAt: date, detectionMethod: .none))
        #expect(budget["present"] is NSNull)
        #expect(budget["reason"] as? String == "scheme_budget_exceeded")

        let raw: [AppPresenceReason: String] = [
            .notDeclared: "not_declared",
            .declarationUnverified: "declaration_unverified",
            .schemeBudgetExceeded: "scheme_budget_exceeded",
            .unsupportedPlatform: "unsupported_platform",
            .queryFailed: "query_failed",
        ]
        for (reason, value) in raw { #expect(reason.rawValue == value) }
    }

    @Test("Snapshot encodes the contract keys, preserves result order and round-trips")
    func snapshotEncoding() throws {
        let date = Date(timeIntervalSince1970: 1_791_547_200.5)
        let id = UUID()
        let results = [
            AppPresenceResult(targetId: "z", state: .present, checkedAt: date, detectionMethod: .iosUrlScheme),
            AppPresenceResult(targetId: "a", state: .unknown, reason: .unsupportedPlatform, checkedAt: date, detectionMethod: .none),
        ]
        let snapshot = AppPresenceSnapshot(snapshotId: id, configurationFingerprint: "abc", checkedAt: date, results: results)
        let json = try jsonObject(snapshot)

        #expect(Set(json.keys) == ["schemaVersion", "snapshotId", "configurationFingerprint", "checkedAt", "cached", "results"])
        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["snapshotId"] as? String == id.uuidString.lowercased())
        #expect(json["cached"] as? Bool == false)
        #expect(json["checkedAt"] as? String == "2026-10-09T12:00:00.500Z")
        let encodedResults = try #require(json["results"] as? [[String: Any]])
        #expect(encodedResults.map { $0["targetId"] as? String } == ["z", "a"])
        #expect(encodedResults[0]["reason"] is NSNull)

        let decoded = try JSONDecoder().decode(AppPresenceSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)

        let cached = snapshot.markedCached()
        #expect(cached.cached)
        #expect(cached.snapshotId == snapshot.snapshotId)
        #expect(cached.checkedAt == snapshot.checkedAt)
        #expect(cached.results == snapshot.results)
    }

    // MARK: - Fingerprint

    @Test("Fingerprint is SHA-256 of the canonical targets JSON")
    func fingerprintCanonicalForm() {
        let configuration = AppPresenceConfiguration(enabled: true, targets: [
            target("b", ios: "Fixture"),
            target("a", android: "io.bearound.fixture.presence"),
        ])
        let expected = #"[{"androidPackageName":"io.bearound.fixture.presence","id":"a","iosScheme":null},{"androidPackageName":null,"id":"b","iosScheme":"fixture"}]"#

        #expect(configuration.canonicalTargetsJSON == expected)
        #expect(configuration.fingerprint == sha256Hex(expected))
        #expect(configuration.fingerprint.count == 64)
    }

    @Test("Fingerprint ignores target order, scheme case and enabled; targets keep their order")
    func fingerprintOrderIndependent() {
        let first = AppPresenceConfiguration(enabled: true, targets: [target("a", ios: "one"), target("b", ios: "two")])
        let reordered = AppPresenceConfiguration(enabled: false, targets: [target("b", ios: "TWO"), target("a", ios: "One")])

        #expect(first.fingerprint == reordered.fingerprint)
        #expect(reordered.targets.map(\.id) == ["b", "a"])
    }

    @Test("Fingerprint changes when targets change")
    func fingerprintSensitive() {
        let base = AppPresenceConfiguration(enabled: true, targets: [target("a", ios: "one")])
        #expect(base.fingerprint != AppPresenceConfiguration(enabled: true, targets: [target("a", ios: "two")]).fingerprint)
        #expect(base.fingerprint != AppPresenceConfiguration(enabled: true, targets: [target("b", ios: "one")]).fingerprint)
        #expect(base.fingerprint != AppPresenceConfiguration(enabled: true, targets: [target("a", ios: "one", android: "a.b")]).fingerprint)
        #expect(base.fingerprint != AppPresenceConfiguration().fingerprint)
    }

    // MARK: - Scheme budget

    private let bundleId = "io.bearound.fixture.host"

    private func infoPlist(schemes: [String], evidence: [String: Any]?) -> [String: Any] {
        var plist: [String: Any] = ["LSApplicationQueriesSchemes": schemes]
        if let evidence { plist["BeAroundAppPresenceBuildEvidence"] = evidence }
        return plist
    }

    private func evidence(bundleId: String? = nil, major: Any = 26, schemes: [String]) -> [String: Any] {
        [
            "bundleId": bundleId ?? self.bundleId,
            "linkedSdkMajor": major,
            "schemesSha256": AppPresenceSchemeBudget.schemesSha256(schemes),
        ]
    }

    @Test("Schemes hash is order and case independent over the full list")
    func schemesHashNormalized() {
        let hash = AppPresenceSchemeBudget.schemesSha256(["b", "A"])
        #expect(hash == AppPresenceSchemeBudget.schemesSha256(["a", "B"]))
        #expect(hash == sha256Hex("a\nb"))
        #expect(hash != AppPresenceSchemeBudget.schemesSha256(["a"]))
    }

    @Test("Ceiling is 25 without evidence")
    func ceilingDefault() {
        let schemes = (0..<30).map { "s\($0)" }
        let plist = infoPlist(schemes: schemes, evidence: nil)
        #expect(AppPresenceSchemeBudget.ceiling(infoPlist: plist, bundleIdentifier: bundleId) == 25)
        #expect(AppPresenceSchemeBudget.isExceeded(infoPlist: plist, bundleIdentifier: bundleId))
        #expect(!AppPresenceSchemeBudget.isExceeded(infoPlist: infoPlist(schemes: Array(schemes.prefix(25)), evidence: nil), bundleIdentifier: bundleId))
    }

    @Test("Ceiling is 50 only with valid evidence for a pre-27 linked SDK")
    func ceilingWithValidEvidence() {
        let schemes = (0..<30).map { "s\($0)" }
        let plist = infoPlist(schemes: schemes, evidence: evidence(schemes: schemes))
        #expect(AppPresenceSchemeBudget.ceiling(infoPlist: plist, bundleIdentifier: bundleId) == 50)
        #expect(!AppPresenceSchemeBudget.isExceeded(infoPlist: plist, bundleIdentifier: bundleId))

        let fiftyOne = (0..<51).map { "s\($0)" }
        let over = infoPlist(schemes: fiftyOne, evidence: evidence(schemes: fiftyOne))
        #expect(AppPresenceSchemeBudget.isExceeded(infoPlist: over, bundleIdentifier: bundleId))
    }

    @Test("Invalid evidence falls back to 25")
    func ceilingWithInvalidEvidence() {
        let schemes = (0..<30).map { "s\($0)" }
        let cases: [[String: Any]] = [
            evidence(major: 27, schemes: schemes),
            evidence(major: 28, schemes: schemes),
            evidence(major: 0, schemes: schemes),
            evidence(major: "26", schemes: schemes),
            evidence(major: true, schemes: schemes),
            evidence(bundleId: "io.other.app", schemes: schemes),
            evidence(schemes: Array(schemes.prefix(29))),
            ["bundleId": bundleId, "linkedSdkMajor": 26],
        ]
        for value in cases {
            let plist = infoPlist(schemes: schemes, evidence: value)
            #expect(AppPresenceSchemeBudget.ceiling(infoPlist: plist, bundleIdentifier: bundleId) == 25)
        }
        let valid = infoPlist(schemes: schemes, evidence: evidence(schemes: schemes))
        #expect(AppPresenceSchemeBudget.ceiling(infoPlist: valid, bundleIdentifier: nil) == 25)
        #expect(AppPresenceSchemeBudget.ceiling(infoPlist: ["BeAroundAppPresenceBuildEvidence": "garbage"], bundleIdentifier: bundleId) == 25)
    }

    @Test("Declared schemes are read lowercased from the full Info.plist list")
    func declaredSchemes() {
        let plist: [String: Any] = ["LSApplicationQueriesSchemes": ["Fixture", "other", 42]]
        #expect(AppPresenceSchemeBudget.declaredSchemes(infoPlist: plist) == ["fixture", "other"])
        #expect(AppPresenceSchemeBudget.declaredSchemes(infoPlist: [:]).isEmpty)
    }
}
