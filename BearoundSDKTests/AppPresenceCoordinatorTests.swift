//
//  AppPresenceCoordinatorTests.swift
//  BearoundSDKTests
//
//  App presence lifecycle: configure never queries, start runs one round independent of
//  Bluetooth, complete ordered snapshot with unknown reasons, cooldown, stop and generation
//  cancellation, cached replay with dedupe, A/B/A token switch, opt-out, invalid
//  configuration, storage failure, app extensions and the absence of any upload path.
//

import Foundation
import Testing

@testable import BearoundSDK

/// Thread-safe sink for everything the coordinator emits.
final class AppPresenceRecorder {
    private let lock = NSLock()
    private var _snapshots: [AppPresenceSnapshot] = []
    private var _errors: [NSError] = []
    private var _queriedURLs: [URL] = []
    private var _offMainDeliveries = 0
    private var _persisted: [AppPresenceConfiguration] = []
    /// Runs inside canOpenURL (main thread), to interleave lifecycle calls with a round.
    var onQuery: (() -> Void)?

    var snapshots: [AppPresenceSnapshot] { lock.lock(); defer { lock.unlock() }; return _snapshots }
    var errors: [NSError] { lock.lock(); defer { lock.unlock() }; return _errors }
    var queriedURLs: [URL] { lock.lock(); defer { lock.unlock() }; return _queriedURLs }
    var offMainDeliveries: Int { lock.lock(); defer { lock.unlock() }; return _offMainDeliveries }
    var persisted: [AppPresenceConfiguration] { lock.lock(); defer { lock.unlock() }; return _persisted }

    func record(_ snapshot: AppPresenceSnapshot) {
        lock.lock()
        _snapshots.append(snapshot)
        if !Thread.isMainThread { _offMainDeliveries += 1 }
        lock.unlock()
    }

    func record(_ error: NSError) { lock.lock(); _errors.append(error); lock.unlock() }
    func persist(_ configuration: AppPresenceConfiguration) { lock.lock(); _persisted.append(configuration); lock.unlock() }

    func query(_ url: URL, installed: Set<String>) -> Bool {
        lock.lock()
        _queriedURLs.append(url)
        let hook = onQuery
        lock.unlock()
        hook?()
        return installed.contains(url.scheme ?? "")
    }
}

@Suite("AppPresence Coordinator Tests")
struct AppPresenceCoordinatorTests {
    private let clock = AppPresenceTestClock()
    private let directory = appPresenceTemporaryDirectory()
    private let recorder = AppPresenceRecorder()
    private static let host = "io.bearound.fixture.host"
    private static let declared = ["bearound-presence-fixture", "bearound-presence-absent"]

    private let targets = [
        AppPresenceTarget(id: "fixture", iosScheme: "bearound-presence-fixture", androidPackageName: "io.bearound.fixture.presence"),
        AppPresenceTarget(id: "absent", iosScheme: "bearound-presence-absent"),
        AppPresenceTarget(id: "android-only", androidPackageName: "io.bearound.fixture.presence"),
        AppPresenceTarget(id: "undeclared", iosScheme: "bearound-presence-undeclared"),
        AppPresenceTarget(id: "fixture-alias", iosScheme: "BEAROUND-PRESENCE-FIXTURE"),
    ]

    private var configuration: AppPresenceConfiguration {
        AppPresenceConfiguration(enabled: true, targets: targets)
    }

    private func makeStore(io: AppPresenceFileIO = AppPresenceDiskIO()) -> AppPresenceStore {
        AppPresenceStore(directory: directory, io: io, clock: clock.clock, launchMonotonic: clock.monotonic)
    }

    private func makeCoordinator(
        schemes: [String] = AppPresenceCoordinatorTests.declared,
        installed: Set<String> = ["bearound-presence-fixture"],
        isAppExtension: Bool = false,
        store: AppPresenceStore? = nil,
        initial: AppPresenceConfiguration = AppPresenceConfiguration()
    ) -> AppPresenceCoordinator {
        let recorder = recorder
        let clock = clock
        let collector = AppPresenceCollector(
            infoPlist: ["LSApplicationQueriesSchemes": schemes, "CFBundleIdentifier": Self.host],
            bundleIdentifier: Self.host,
            canOpenURL: { recorder.query($0, installed: installed) },
            now: { clock.wall }
        )
        let coordinator = AppPresenceCoordinator(
            configuration: initial,
            store: store ?? makeStore(),
            collector: collector,
            bundleIdentifier: Self.host,
            isAppExtension: isAppExtension,
            persistConfiguration: { recorder.persist($0) }
        )
        coordinator.onSnapshot = { recorder.record($0) }
        coordinator.onError = { recorder.record($0) }
        return coordinator
    }

    /// Lets every queued queue/main hop of a round settle (queue -> main -> queue -> main).
    private func settle(_ coordinator: AppPresenceCoordinator) async {
        for _ in 0..<4 {
            _ = coordinator.lastSnapshot()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Start and round

    @Test("configure alone never queries")
    func configureAloneNeverQueries() async throws {
        let coordinator = makeCoordinator()
        coordinator.setBusinessToken("token-A")
        try coordinator.configure(configuration)
        coordinator.tryRun()
        await settle(coordinator)
        #expect(recorder.queriedURLs.isEmpty)
        #expect(recorder.snapshots.isEmpty)
        #expect(coordinator.lastSnapshot() == nil)
    }

    @Test("start runs one complete ordered round on main, with unknown reasons and deduplicated schemes")
    func startDeliversCompleteSnapshot() async throws {
        let coordinator = makeCoordinator()
        coordinator.setBusinessToken("token-A")
        try coordinator.configure(configuration)
        // No Bluetooth, Location or beacon input exists in this setup: start alone suffices.
        coordinator.start()
        await settle(coordinator)

        let snapshot = try #require(recorder.snapshots.first)
        #expect(recorder.snapshots.count == 1)
        #expect(recorder.offMainDeliveries == 0)
        #expect(snapshot.cached == false)
        #expect(snapshot.configurationFingerprint == configuration.fingerprint)
        #expect(snapshot.results.map(\.targetId) == targets.map(\.id))
        #expect(snapshot.results.map(\.state) == [.present, .absent, .unknown, .unknown, .present])
        #expect(snapshot.results.map(\.reason) == [nil, nil, .unsupportedPlatform, .notDeclared, nil])
        #expect(snapshot.results.map(\.detectionMethod) == [.iosUrlScheme, .iosUrlScheme, .none, .none, .iosUrlScheme])
        #expect(snapshot.results.allSatisfy { $0.checkedAt == AppPresenceTimestamp.truncatedToMilliseconds(clock.wall) })
        // Same scheme twice (case-insensitive) is one physical query; undeclared is never queried.
        #expect(recorder.queriedURLs.map(\.absoluteString).sorted() == ["bearound-presence-absent://", "bearound-presence-fixture://"])
    }

    @Test("Scheme budget exceeded: every iOS target is unknown and nothing is queried")
    func schemeBudgetExceeded() async throws {
        let schemes = Self.declared + (1...24).map { "host-scheme-\($0)" }
        let coordinator = makeCoordinator(schemes: schemes)
        coordinator.setBusinessToken("token-A")
        try coordinator.configure(configuration)
        coordinator.start()
        await settle(coordinator)

        let snapshot = try #require(recorder.snapshots.first)
        #expect(snapshot.results.map(\.reason) == [
            .schemeBudgetExceeded, .schemeBudgetExceeded, .unsupportedPlatform, .schemeBudgetExceeded, .schemeBudgetExceeded,
        ])
        #expect(snapshot.results.allSatisfy { $0.present == nil })
        #expect(recorder.queriedURLs.isEmpty)
    }

    @Test("Triggers inside the window do not query; 3600 s later a new round runs")
    func cooldownAcrossTriggers() async throws {
        let coordinator = makeCoordinator()
        coordinator.setBusinessToken("token-A")
        try coordinator.configure(configuration)
        coordinator.start()
        await settle(coordinator)
        #expect(recorder.queriedURLs.count == 2)

        clock.advance(3599)
        coordinator.tryRun()
        coordinator.start()
        coordinator.tryRun()
        await settle(coordinator)
        #expect(recorder.queriedURLs.count == 2)
        #expect(recorder.snapshots.count == 1)

        clock.advance(1)
        coordinator.tryRun()
        await settle(coordinator)
        #expect(recorder.snapshots.count == 2)
        #expect(recorder.snapshots[0].snapshotId != recorder.snapshots[1].snapshotId)
    }

    // MARK: - Cancellation

    @Test("stop during a round cancels the delivery; a later start respects the reservation")
    func stopCancelsPendingDelivery() async throws {
        let coordinator = makeCoordinator()
        coordinator.setBusinessToken("token-A")
        try coordinator.configure(configuration)
        recorder.onQuery = { [weak coordinator] in coordinator?.stop() }
        coordinator.start()
        await settle(coordinator)
        #expect(recorder.snapshots.isEmpty)
        #expect(coordinator.lastSnapshot() == nil)

        recorder.onQuery = nil
        let queries = recorder.queriedURLs.count
        coordinator.start()
        await settle(coordinator)
        #expect(recorder.queriedURLs.count == queries)
        #expect(recorder.snapshots.isEmpty)
    }

    @Test("Reconfiguration during a round discards it by generation")
    func reconfigurationDiscardsStaleRound() async throws {
        let coordinator = makeCoordinator()
        coordinator.setBusinessToken("token-A")
        try coordinator.configure(configuration)
        let replacement = AppPresenceConfiguration(enabled: true, targets: [targets[1]])
        recorder.onQuery = { [weak coordinator] in
            try? coordinator?.configure(replacement)
        }
        coordinator.start()
        await settle(coordinator)
        recorder.onQuery = nil
        #expect(recorder.snapshots.isEmpty)
        #expect(coordinator.lastSnapshot() == nil)
    }

    // MARK: - Replay

    @Test("Replay keeps snapshotId, checkedAt and fingerprint with cached=true, also after relaunch")
    func replayIsCachedWithOriginalIdentity() async throws {
        let coordinator = makeCoordinator()
        coordinator.setBusinessToken("token-A")
        try coordinator.configure(configuration)
        coordinator.start()
        await settle(coordinator)
        let original = try #require(recorder.snapshots.first)

        let replay = try #require(coordinator.lastSnapshot())
        #expect(replay.cached)
        #expect(replay.snapshotId == original.snapshotId)
        #expect(replay.checkedAt == original.checkedAt)
        #expect(replay.configurationFingerprint == original.configurationFingerprint)
        #expect(replay.results == original.results)

        // New delegate assignment gets the replay; a further assignment gets its own.
        coordinator.subscriberChanged()
        await settle(coordinator)
        coordinator.subscriberChanged()
        await settle(coordinator)
        #expect(recorder.snapshots.count == 3)
        #expect(recorder.snapshots.dropFirst().allSatisfy { $0.cached && $0.snapshotId == original.snapshotId })
        let queries = recorder.queriedURLs.count

        // Relaunch: the persisted snapshot is replayed without any query.
        let relaunched = makeCoordinator(store: makeStore(), initial: configuration)
        relaunched.setBusinessToken("token-A")
        let restored = try #require(relaunched.lastSnapshot())
        #expect(restored.cached)
        #expect(restored.snapshotId == original.snapshotId)
        #expect(restored.checkedAt == original.checkedAt)
        #expect(recorder.queriedURLs.count == queries)
    }

    @Test("Delegate assigned while a round completes receives that snapshotId exactly once")
    func assignmentDuringRoundIsDeduplicated() async throws {
        let coordinator = makeCoordinator()
        coordinator.setBusinessToken("token-A")
        try coordinator.configure(configuration)
        recorder.onQuery = { [weak coordinator] in coordinator?.subscriberChanged() }
        coordinator.start()
        await settle(coordinator)
        recorder.onQuery = nil

        let ids = recorder.snapshots.map(\.snapshotId)
        #expect(ids.count == 1)
        // A new round, not a replay, even when the assignment's replay ran first.
        #expect(recorder.snapshots.first?.cached == false)
    }

    // MARK: - Isolation and opt-out

    @Test("A/B/A business token switch keeps A's reservation and A's snapshot")
    func tokenSwitchABA() async throws {
        let coordinator = makeCoordinator()
        coordinator.setBusinessToken("token-A")
        try coordinator.configure(configuration)
        coordinator.start()
        await settle(coordinator)
        let snapshotA = try #require(recorder.snapshots.first)

        coordinator.setBusinessToken("token-B")
        #expect(coordinator.lastSnapshot() == nil)
        coordinator.tryRun()
        await settle(coordinator)
        #expect(recorder.snapshots.count == 2)
        #expect(recorder.queriedURLs.count == 4)

        coordinator.setBusinessToken("token-A")
        coordinator.tryRun()
        await settle(coordinator)
        #expect(recorder.queriedURLs.count == 4)
        #expect(coordinator.lastSnapshot()?.snapshotId == snapshotA.snapshotId)
    }

    @Test("New targets drop the incompatible cache without restarting the cooldown")
    func reconfigurationDropsIncompatibleCache() async throws {
        let coordinator = makeCoordinator()
        coordinator.setBusinessToken("token-A")
        try coordinator.configure(configuration)
        coordinator.start()
        await settle(coordinator)

        try coordinator.configure(AppPresenceConfiguration(enabled: true, targets: [targets[0]]))
        await settle(coordinator)
        #expect(coordinator.lastSnapshot() == nil)
        #expect(recorder.snapshots.count == 1)
        #expect(recorder.queriedURLs.count == 2)

        // Back to the original targets: the old snapshot was deleted, not hidden.
        try coordinator.configure(configuration)
        #expect(coordinator.lastSnapshot() == nil)
    }

    @Test("enabled=false or empty targets deletes the snapshot but keeps the cooldown")
    func optOutDeletesSnapshotKeepsCooldown() async throws {
        let store = makeStore()
        let coordinator = makeCoordinator(store: store)
        coordinator.setBusinessToken("token-A")
        try coordinator.configure(configuration)
        coordinator.start()
        await settle(coordinator)

        let namespace = AppPresenceNamespace(bundleIdentifier: Self.host, businessToken: "token-A")
        try coordinator.configure(AppPresenceConfiguration(enabled: false, targets: targets))
        #expect(coordinator.lastSnapshot() == nil)
        #expect(store.loadSnapshot(namespace) == nil)

        try coordinator.configure(configuration)
        await settle(coordinator)
        try coordinator.configure(AppPresenceConfiguration(enabled: true, targets: []))
        try coordinator.configure(configuration)
        await settle(coordinator)
        #expect(recorder.queriedURLs.count == 2)
        #expect(store.remainingCooldown(namespace) > 0)
    }

    @Test("Invalid configuration disables only the feature, persists the disabled default and drops the cache")
    func invalidConfigurationDisablesFeature() async throws {
        let coordinator = makeCoordinator()
        coordinator.setBusinessToken("token-A")
        try coordinator.configure(configuration)
        coordinator.start()
        await settle(coordinator)
        #expect(coordinator.lastSnapshot() != nil)

        let duplicate = AppPresenceConfiguration(enabled: true, targets: [targets[0], targets[0]])
        #expect(throws: AppPresenceConfigurationError.self) {
            try coordinator.configure(duplicate)
        }
        #expect(coordinator.lastSnapshot() == nil)
        #expect(recorder.persisted.last == AppPresenceConfiguration())

        clock.advance(3600)
        coordinator.tryRun()
        await settle(coordinator)
        #expect(recorder.snapshots.count == 1)

        let error = AppPresenceCoordinator.makeError(.appPresenceInvalidConfiguration, code: AppPresenceConfigurationError.code, message: "x")
        #expect(error.domain == "BeAroundSDK")
        #expect(error.code == 12)
        #expect(error.userInfo["code"] as? String == "app_presence_invalid_configuration")
    }

    @Test("Storage unavailable cancels the round before any query and reports the error locally")
    func storageUnavailableCancelsRound() async throws {
        let coordinator = makeCoordinator(store: makeStore(io: AppPresenceFailingWriteIO()))
        coordinator.setBusinessToken("token-A")
        try coordinator.configure(configuration)
        coordinator.start()
        await settle(coordinator)

        #expect(recorder.queriedURLs.isEmpty)
        #expect(recorder.snapshots.isEmpty)
        let error = try #require(recorder.errors.first)
        #expect(recorder.errors.count == 1)
        #expect(error.code == BearoundErrorCode.appPresenceStorageUnavailable.rawValue)
        #expect(error.userInfo["code"] as? String == "app_presence_storage_unavailable")
        #expect(!error.localizedDescription.contains("token-A"))
    }

    @Test("App extensions never run the feature")
    func appExtensionIsNoOp() async throws {
        let coordinator = makeCoordinator(isAppExtension: true)
        coordinator.setBusinessToken("token-A")
        try coordinator.configure(configuration)
        coordinator.start()
        coordinator.tryRun()
        await settle(coordinator)
        #expect(recorder.queriedURLs.isEmpty)
        #expect(recorder.snapshots.isEmpty)
    }

    // MARK: - Wiring

    @Test("startScanning activates app presence before the Bluetooth and permission guards")
    func startScanningActivatesBeforeGuards() throws {
        let source = try sourceFile("BearoundSDK/BearoundSDK.swift")
        let start = try #require(source.range(of: "public func startScanning() {"))
        let body = source[start.upperBound...]
        let activation = try #require(body.range(of: "appPresence.start()"))
        let permissionGuard = try #require(body.range(of: "noScanAuthorization"))
        let bluetoothStart = try #require(body.range(of: "bluetoothManager.startScanSurfaces"))
        #expect(activation.lowerBound < permissionGuard.lowerBound)
        #expect(activation.lowerBound < bluetoothStart.lowerBound)

        let stop = try #require(source.range(of: "public func stopScanning() {"))
        let stopBody = source[stop.upperBound...].prefix(200)
        #expect(stopBody.contains("appPresence.stop()"))
    }

    @Test("No upload path: network, ingest, offline queue and telemetry never see app presence data")
    func resultsNeverReachUploads() throws {
        for path in [
            "BearoundSDK/Network/APIClient.swift",
            "BearoundSDK/Telemetry/ErrorReporter.swift",
            "BearoundSDK/Utilities/OfflineBatchStorage.swift",
            "BearoundSDK/PushEventQueue.swift",
            "BearoundSDK/Models/UserDevice.swift",
        ] {
            let source = try sourceFile(path)
            #expect(!source.localizedCaseInsensitiveContains("AppPresence"), "\(path) references app presence")
        }
        for path in [
            "BearoundSDK/AppPresence/AppPresenceCoordinator.swift",
            "BearoundSDK/Collectors/AppPresenceCollector.swift",
            "BearoundSDK/Utilities/AppPresenceStore.swift",
        ] {
            let source = try sourceFile(path)
            for forbidden in ["URLSession", "APIClient", "ErrorReporter", "OfflineBatchStorage", "NSLog", "os_log", "openURL", "open("] where !(forbidden == "open(" && path.hasSuffix("AppPresenceStore.swift")) {
                #expect(!source.contains(forbidden), "\(path) uses \(forbidden)")
            }
        }
        let sdk = try sourceFile("BearoundSDK/BearoundSDK.swift")
        let wiring = try #require(sdk.range(of: "private func setupAppPresenceCallbacks() {"))
        let wiringBody = sdk[wiring.upperBound...].prefix(400)
        #expect(!wiringBody.contains("ErrorReporter"))
    }
}
