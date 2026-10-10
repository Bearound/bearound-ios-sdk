//
//  AppPresenceCoordinator.swift
//  BearoundSDK
//
//  Lifecycle of the app presence feature: configuration, namespace (business token),
//  start/stop, one serial round per namespace, cooldown reservation, local delivery and
//  cached replay. Results are delivered only to the host through the delegate; nothing here
//  touches the network, the ingest payloads or the error telemetry.
//

import Foundation

final class AppPresenceCoordinator {
    static let errorDomain = "BeAroundSDK"
    /// `userInfo` key carrying the stable string code of app presence errors.
    static let errorCodeUserInfoKey = "code"

    private let store: AppPresenceStore
    private let collector: AppPresenceCollector
    private let bundleIdentifier: String?
    private let isAppExtension: Bool
    private let persistConfiguration: (AppPresenceConfiguration) -> Void
    private let queue = DispatchQueue(label: "com.bearound.sdk.appPresence")

    /// Delivery sink, always invoked on the main thread.
    var onSnapshot: ((AppPresenceSnapshot) -> Void)?
    /// Error sink, always invoked on the main thread. Never wired to telemetry.
    var onError: ((NSError) -> Void)?

    // MARK: State (queue only)

    private var configuration: AppPresenceConfiguration
    private var namespace: AppPresenceNamespace?
    /// Bumped on every reconfiguration, namespace change and stop: rounds and deliveries of
    /// an older generation are discarded.
    private var generation = 0
    private var isActive = false
    private var roundInFlight = false
    /// Latest snapshot compatible with the current namespace and configuration.
    private var cache: AppPresenceSnapshot?

    // MARK: Subscriber dedupe

    private let epochLock = NSLock()
    /// Incremented synchronously on every delegate assignment, from any thread.
    private var subscriberEpoch = 0
    // Main thread only.
    private var deliveredEpoch = -1
    private var deliveredIds = Set<UUID>()

    init(
        configuration: AppPresenceConfiguration,
        store: AppPresenceStore,
        collector: AppPresenceCollector,
        bundleIdentifier: String?,
        isAppExtension: Bool,
        persistConfiguration: @escaping (AppPresenceConfiguration) -> Void
    ) {
        self.configuration = configuration
        self.store = store
        self.collector = collector
        self.bundleIdentifier = bundleIdentifier
        self.isAppExtension = isAppExtension
        self.persistConfiguration = persistConfiguration
    }

    static func live() -> AppPresenceCoordinator {
        AppPresenceCoordinator(
            configuration: SDKConfigStorage.loadAppPresenceConfiguration(),
            store: AppPresenceStore(),
            collector: .live(),
            bundleIdentifier: Bundle.main.bundleIdentifier,
            isAppExtension: Bundle.main.bundlePath.hasSuffix(".appex"),
            persistConfiguration: { SDKConfigStorage.saveAppPresenceConfiguration($0) }
        )
    }

    // MARK: - Public surface (any thread)

    /// Sets the client namespace. The token is hashed immediately and never stored.
    func setBusinessToken(_ businessToken: String) {
        guard !isAppExtension else { return }
        let next = AppPresenceNamespace(bundleIdentifier: bundleIdentifier, businessToken: businessToken)
        let shouldRun: Bool = queue.sync {
            guard next != namespace else { return false }
            namespace = next
            generation += 1
            reconcileCache()
            return isActive
        }
        // A new client during an active session may be eligible right away.
        if shouldRun { tryRun() }
    }

    /// Validates and applies a configuration. An invalid one disables only this feature,
    /// drops the cached snapshot and is rethrown for the caller to report.
    func configure(_ newConfiguration: AppPresenceConfiguration) throws {
        do {
            try newConfiguration.validate()
        } catch {
            let disabled = AppPresenceConfiguration()
            persistConfiguration(disabled)
            queue.sync {
                configuration = disabled
                generation += 1
                reconcileCache()
            }
            throw error
        }
        persistConfiguration(newConfiguration)
        let shouldRun: Bool = queue.sync {
            configuration = newConfiguration
            generation += 1
            reconcileCache()
            return isActive
        }
        if shouldRun { tryRun() }
    }

    /// Called by `startScanning`, before any Bluetooth or permission guard.
    func start() {
        guard !isAppExtension else { return }
        queue.sync { isActive = true }
        tryRun()
    }

    /// Called by `stopScanning`: pauses the feature and cancels pending deliveries.
    /// The reservation is kept, so a later start respects the running window.
    func stop() {
        queue.sync {
            isActive = false
            generation += 1
        }
    }

    /// Foreground and active-execution timer trigger. Cheap when not eligible.
    func tryRun() {
        guard !isAppExtension else { return }
        queue.async { self.runIfEligible() }
    }

    /// Latest compatible snapshot with `cached = true`. Never queries.
    func lastSnapshot() -> AppPresenceSnapshot? {
        queue.sync { compatibleCache()?.markedCached() }
    }

    /// Delegate assignment: the new subscriber gets the cached snapshot as a replay, and a
    /// round completing concurrently is delivered once (snapshotId dedupe per assignment).
    func subscriberChanged() {
        epochLock.lock()
        subscriberEpoch += 1
        epochLock.unlock()
        DispatchQueue.main.async {
            guard let snapshot = self.lastSnapshot() else { return }
            self.deliverOnMain(snapshot, generation: nil)
        }
    }

    // MARK: - Round (queue)

    private func runIfEligible() {
        guard isActive, !roundInFlight, configuration.enabled, !configuration.targets.isEmpty,
              let namespace else { return }

        let reservation: AppPresenceReservation
        do {
            reservation = try store.reserve(namespace)
        } catch {
            // No durable reservation, no query.
            report(.appPresenceStorageUnavailable, code: AppPresenceStorageUnavailableError.code,
                   message: "App presence storage is unavailable; the round was cancelled.")
            return
        }
        guard reservation == .reserved else { return }

        roundInFlight = true
        let roundGeneration = generation
        let targets = configuration.targets
        let fingerprint = configuration.fingerprint
        DispatchQueue.main.async {
            guard self.isCurrent(roundGeneration) else {
                self.queue.async { self.roundInFlight = false }
                return
            }
            let results = self.collector.collect(targets)
            self.queue.async {
                self.finishRound(results, fingerprint: fingerprint, generation: roundGeneration, namespace: namespace)
            }
        }
    }

    private func finishRound(
        _ results: [AppPresenceResult],
        fingerprint: String,
        generation roundGeneration: Int,
        namespace roundNamespace: AppPresenceNamespace
    ) {
        roundInFlight = false
        guard roundGeneration == generation, isActive else { return }
        let snapshot = AppPresenceSnapshot(
            configurationFingerprint: fingerprint,
            checkedAt: collector.now(),
            results: results
        )
        // Persisted before dispatch, so a late subscriber can replay it.
        do {
            try store.saveSnapshot(snapshot, roundNamespace)
        } catch {
            report(.appPresenceStorageUnavailable, code: AppPresenceStorageUnavailableError.code,
                   message: "App presence storage is unavailable; the snapshot was not persisted.")
        }
        cache = snapshot
        DispatchQueue.main.async {
            self.deliverOnMain(snapshot, generation: roundGeneration)
        }
    }

    // MARK: - Helpers

    private func isCurrent(_ roundGeneration: Int) -> Bool {
        queue.sync { roundGeneration == generation && isActive }
    }

    private func deliverOnMain(_ snapshot: AppPresenceSnapshot, generation roundGeneration: Int?) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let roundGeneration, !isCurrent(roundGeneration) { return }
        epochLock.lock()
        let epoch = subscriberEpoch
        epochLock.unlock()
        if epoch != deliveredEpoch {
            deliveredEpoch = epoch
            deliveredIds = []
        }
        // A snapshotId reaches a given delegate assignment at most once (event/replay race).
        guard deliveredIds.insert(snapshot.snapshotId).inserted else { return }
        onSnapshot?(snapshot)
    }

    /// Keeps only a snapshot compatible with the current namespace and configuration.
    /// Disabled or empty configurations and fingerprint changes delete the persisted
    /// snapshot; the cooldown marker always stays.
    private func reconcileCache() {
        guard let namespace else {
            cache = nil
            return
        }
        guard configuration.enabled, !configuration.targets.isEmpty else {
            cache = nil
            store.clearSnapshot(namespace)
            return
        }
        let stored = store.loadSnapshot(namespace)
        if let stored, stored.configurationFingerprint == configuration.fingerprint {
            cache = stored
        } else {
            cache = nil
            if stored != nil { store.clearSnapshot(namespace) }
        }
    }

    private func compatibleCache() -> AppPresenceSnapshot? {
        guard namespace != nil, configuration.enabled, !configuration.targets.isEmpty,
              let cache, cache.configurationFingerprint == configuration.fingerprint else { return nil }
        return cache
    }

    private func report(_ errorCode: BearoundErrorCode, code: String, message: String) {
        let error = Self.makeError(errorCode, code: code, message: message)
        DispatchQueue.main.async { self.onError?(error) }
    }

    static func makeError(_ errorCode: BearoundErrorCode, code: String, message: String) -> NSError {
        NSError(
            domain: errorDomain,
            code: errorCode.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message, errorCodeUserInfoKey: code]
        )
    }
}
