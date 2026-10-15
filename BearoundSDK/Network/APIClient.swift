//
//  APIClient.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import Foundation
import UIKit

struct ObservationDeliveryReconciliation: Codable {
    let storageIds: [String]
    let tenantFingerprint: String?
    let adaptiveBatchId: String?
    var requestContentEncoding: String? = nil
}

struct RequestSubmissionContext {
    let policy: DataCollectionPolicy
    var gzipLease: RequestEncodingLease? = nil
    var maximumJSONBytes = 524_288
    var adaptiveAllowed = true
    var liveEvidenceMaxAgeMs: Int64 = 30_000
    var isCurrent: () -> Bool = { true }
    var adaptiveAllowedAtSubmission: (() -> Bool)? = nil
}

/// Owns the single background `URLSession` used to upload beacon batches.
///
/// A background session survives app suspension and termination: the OS continues the
/// upload and relaunches the app to deliver the completion. Two background sessions created
/// with the SAME identifier crash the process, so this manager guarantees the session is
/// created exactly once and retained for the process lifetime (it is the session delegate).
///
/// Per-task completion handlers are NOT supported on background sessions, so we keep a
/// thread-safe map of `taskIdentifier → completion` and accumulate response bytes per task,
/// then finalize in `urlSession(_:task:didCompleteWithError:)`.
final class BackgroundSessionManager: NSObject {
    private static let identityLock = NSLock()
    private static var identityRequired: Set<String> = []

    private static func identityKeys(_ descriptor: ObservationDeliveryReconciliation) -> [String] {
        guard let tenant = descriptor.tenantFingerprint else { return [] }
        return (descriptor.adaptiveBatchId.map { [$0] } ?? descriptor.storageIds).map { tenant + ":" + $0 }
    }

    static func requiresIdentity(_ descriptor: ObservationDeliveryReconciliation) -> Bool {
        identityLock.lock(); defer { identityLock.unlock() }
        return identityKeys(descriptor).contains { identityRequired.contains($0) }
    }

    static func stageUploadBody(_ body: Data, directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let file = directory.appendingPathComponent("bearound-upload-\(UUID().uuidString).json")
        try body.write(to: file, options: .atomic)
        return file
    }

    static let shared = BackgroundSessionManager()

    /// Must match the identifier the host app forwards via
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    static let backgroundSessionIdentifier = "io.bearound.sdk.upload"

    /// Serializes access to the per-task maps below.
    private let lock = NSLock()
    private var completions: [Int: (Result<Void, Error>) -> Void] = [:]
    private var observationCompletions: [Int: (Result<Data, Error>) -> Void] = [:]
    private var responseData: [Int: Data] = [:]
    /// Temp file backing each upload task — background sessions require a file body, not Data.
    private var taskFiles: [Int: URL] = [:]

    /// System-provided completion handler stored when the app is relaunched to finish
    /// background events. Must be invoked on the main thread once events drain.
    private var systemEventsCompletionHandler: (() -> Void)?

    /// Set when urlSessionDidFinishEvents fired BEFORE the handler was stored (the two
    /// arrive on independent queues, so both orders happen). Without it that ordering
    /// permanently leaked the system assertion — the handler arrived, was stored, and
    /// nobody ever called it.
    private var eventsFinishedBeforeHandler = false

    /// The single background session. Created ONCE in init — `shared` being a `static
    /// let` makes that thread-safe via the Swift runtime. The previous `lazy var` was
    /// not: `lazy` has no lock, so two threads racing the first access could run the
    /// initializer twice — and two live background URLSessions with the SAME identifier
    /// is undefined behavior at the daemon level.
    private(set) var session: URLSession!

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(
            withIdentifier: BackgroundSessionManager.backgroundSessionIdentifier
        )
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.timeoutIntervalForResource = 86400
        NSLog("[BeAroundSDK] Created background URLSession '%@'", BackgroundSessionManager.backgroundSessionIdentifier)
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    init(ephemeralConfiguration: URLSessionConfiguration) {
        precondition(ephemeralConfiguration.identifier == nil)
        super.init()
        session = URLSession(configuration: ephemeralConfiguration, delegate: self, delegateQueue: nil)
    }

    /// Touching the singleton instantiates it (and therefore the session, created in
    /// init) so pending delegate callbacks from a background-relaunch are delivered.
    /// Safe to call repeatedly — `static let shared` guarantees a single instance.
    func ensureSessionAlive() {
        _ = session
    }

    /// Stores the system completion handler delivered on background-relaunch and makes sure
    /// the session is reconstructed so the OS can hand us the pending events. If the events
    /// already finished before the handler arrived, it is invoked immediately.
    func setSystemEventsCompletionHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        let finishedAlready = eventsFinishedBeforeHandler
        eventsFinishedBeforeHandler = false
        if !finishedAlready {
            systemEventsCompletionHandler = handler
        }
        lock.unlock()

        if finishedAlready {
            NSLog("[BeAroundSDK] Background events finished before handler arrived — calling it now")
            DispatchQueue.main.async { handler() }
            return
        }
        ensureSessionAlive()
    }

    /// Uploads `bodyData` to `request` on the background session — the DURABLE path.
    ///
    /// This is pure background-session by design: the immediate-first attempt lives in
    /// `APIClient.sendBeacons(delivery: .immediateFirst)`, which falls back HERE on
    /// transport failure. Keeping this layer background-only avoids double immediate
    /// attempts
    /// and preserves an honest `.background` mode for callers without an execution
    /// window. Background sessions reject `httpBody` on upload tasks, so the body is
    /// staged to a temp file (deleted in didCompleteWithError).
    func upload(
        request: URLRequest,
        bodyData: Data,
        persistedBatchIds: [String] = [],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bearound-upload-\(UUID().uuidString).json")
        do {
            try bodyData.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[BeAroundSDK] Failed to stage upload body: %@", error.localizedDescription)
            completion(.failure(error))
            return
        }

        let task = session.uploadTask(with: request, fromFile: fileURL)
        // taskDescription survives process death with the task (the background
        // daemon persists it). It carries the persisted-batch id(s) this upload
        // represents, so didCompleteWithError can reconcile OfflineBatchStorage
        // even when the in-memory `completions` map died with the old process.
        if !persistedBatchIds.isEmpty {
            task.taskDescription = persistedBatchIds.joined(separator: ",")
        }
        lock.lock()
        completions[task.taskIdentifier] = completion
        responseData[task.taskIdentifier] = Data()
        taskFiles[task.taskIdentifier] = fileURL
        lock.unlock()
        task.resume()
    }

    func uploadObservation(
        request: URLRequest, bodyData: Data, reconciliation: ObservationDeliveryReconciliation,
        stagingDirectory: URL = FileManager.default.temporaryDirectory,
        willSubmit: (() -> Bool)? = nil,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let file: URL
        do { file = try Self.stageUploadBody(bodyData, directory: stagingDirectory) }
        catch { completion(.failure(error)); return }
        guard willSubmit?() != false else {
            try? FileManager.default.removeItem(at: file)
            completion(.failure(APIError.invalidResponse)); return
        }
        let task = session.uploadTask(with: request, fromFile: file)
        if let encoded = try? JSONEncoder().encode(reconciliation) { task.taskDescription = String(data: encoded, encoding: .utf8) }
        lock.lock()
        observationCompletions[task.taskIdentifier] = completion
        taskFiles[task.taskIdentifier] = file
        responseData[task.taskIdentifier] = Data()
        lock.unlock()
        task.resume()
    }

    static func reconcileObservation(description: String, responseBody: Data, successful: Bool,
        statusCode: Int? = nil, storage: OfflineBatchStorage = .shared) -> Int {
        guard let data = description.data(using: .utf8),
              let reconciliation = try? JSONDecoder().decode(ObservationDeliveryReconciliation.self, from: data) else { return 0 }
        if statusCode == 415 && reconciliation.requestContentEncoding == "gzip" {
            let retainedKeys = Set(storage.observationRecords(includeQuarantined: true).flatMap { record in
                identityKeys(ObservationDeliveryReconciliation(storageIds: [record.storageId],
                    tenantFingerprint: record.envelope.tenantFingerprint,
                    adaptiveBatchId: record.envelope.deliveryProtocol == .adaptive ? record.envelope.batchId : nil))
            })
            identityLock.lock()
            identityRequired.formIntersection(retainedKeys)
            identityRequired.formUnion(identityKeys(reconciliation).filter { retainedKeys.contains($0) })
            identityLock.unlock()
            return 0
        }
        guard successful else { return 0 }
        if let batchId = reconciliation.adaptiveBatchId, let tenant = reconciliation.tenantFingerprint {
            guard AdaptiveSamplingResponse.decode(responseBody)?.samplingAck?.confirms(batchId) == true else { return 0 }
            identityLock.lock(); identityRequired.subtract(identityKeys(reconciliation)); identityLock.unlock()
            return storage.acknowledge(batchIds: [batchId], tenantFingerprint: tenant)
        }
        identityLock.lock(); identityRequired.subtract(identityKeys(reconciliation)); identityLock.unlock()
        return storage.removeBatches(ids: reconciliation.storageIds)
    }
}

extension BackgroundSessionManager: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        responseData[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }
}

extension BackgroundSessionManager: URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskId = task.taskIdentifier

        lock.lock()
        let observationCompletion = observationCompletions.removeValue(forKey: taskId)
        let completion = completions.removeValue(forKey: taskId)
        let responseBody = responseData.removeValue(forKey: taskId)
        let fileURL = taskFiles.removeValue(forKey: taskId)
        lock.unlock()

        let status = (task.response as? HTTPURLResponse)?.statusCode
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }

        if let observationCompletion {
            if let error { observationCompletion(.failure(error)); return }
            guard let http = task.response as? HTTPURLResponse else { observationCompletion(.failure(APIError.invalidResponse)); return }
            guard (200 ..< 300).contains(http.statusCode) else {
                observationCompletion(.failure(APIError.httpError(statusCode: http.statusCode))); return
            }
            observationCompletion(.success(responseBody ?? Data()))
            return
        }

        guard let completion else {
            // Orphaned task: the process that created it died and this is the
            // background-relaunch delivery. Nobody is waiting on the completion,
            // but the persisted batch still needs reconciling — on SUCCESS it
            // must be removed, or the retry drain re-sends it (duplicate event).
            // On failure we intentionally do nothing: the batch stays queued.
            let isSuccess = error == nil
                && (task.response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true
            if let description = task.taskDescription, description.hasPrefix("{") {
                _ = Self.reconcileObservation(description: description, responseBody: responseBody ?? Data(), successful: isSuccess, statusCode: status)
            } else if isSuccess, let ids = task.taskDescription?.split(separator: ",").map(String.init), !ids.isEmpty {
                let removed = OfflineBatchStorage.shared.removeBatches(ids: ids)
                NSLog("[BeAroundSDK] Orphaned upload task %d succeeded after relaunch — reconciled %d persisted batch(es)", taskId, removed)
            } else {
                NSLog("[BeAroundSDK] Orphaned upload task %d completed (success=%d, no batch ids) — nothing to reconcile", taskId, isSuccess ? 1 : 0)
            }
            return
        }

        if let error {
            NSLog("[BeAroundSDK] Upload task %d failed: %@", taskId, error.localizedDescription)
            completion(.failure(error))
            return
        }

        guard let httpResponse = task.response as? HTTPURLResponse else {
            NSLog("[BeAroundSDK] Upload task %d: invalid response", taskId)
            completion(.failure(APIError.invalidResponse))
            return
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            // Capture a bounded slice of the response body so the delegate error carries
            // the server's explanation (e.g. an auth/validation message) instead of just a
            // bare status code. Bodies are typically tiny JSON error envelopes.
            let body = responseBody.flatMap { String(data: $0, encoding: .utf8) }
                .map { String($0.prefix(512)) }
                .flatMap { $0.isEmpty ? nil : $0 }
            NSLog("[BeAroundSDK] Upload task %d: HTTP %d body=%@", taskId, httpResponse.statusCode, body ?? "—")
            completion(.failure(APIError.httpError(statusCode: httpResponse.statusCode, body: body)))
            return
        }

        NSLog("[BeAroundSDK] Upload task %d succeeded (HTTP %d)", taskId, httpResponse.statusCode)
        completion(.success(()))
    }
}

extension BackgroundSessionManager: URLSessionDelegate {
    /// Called when all background events for the session have been delivered (after relaunch).
    /// Invoke the stored system handler on the main thread to let the OS snapshot the app.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = systemEventsCompletionHandler
        systemEventsCompletionHandler = nil
        if handler == nil {
            // Events drained before the app layer delivered the handler — remember it
            // so setSystemEventsCompletionHandler() can complete immediately on arrival.
            eventsFinishedBeforeHandler = true
        }
        lock.unlock()

        if let handler {
            NSLog("[BeAroundSDK] Background URLSession finished events — calling system handler")
            DispatchQueue.main.async {
                handler()
            }
        } else {
            NSLog("[BeAroundSDK] Background URLSession finished events before handler arrived — flagged for immediate completion")
        }
    }
}

/// How a batch should reach the ingester.
///
/// `.background` — hand the upload to the background `URLSession` (survives suspension and
/// termination; the system daemon decides WHEN it runs — for a suspended app that can be
/// minutes). `.immediateFirst` — try a short-timeout foreground-class session first, inside
/// the caller's execution window (foreground or an active background-task assertion), and
/// fall back to the background session ONLY on a transport failure. Server HTTP errors do
/// not fall back: the request reached the backend, retrying the same payload on another
/// session would fail identically (the persisted batch/retry path owns that case).
enum DeliveryPath {
    case background
    case immediateFirst
}

class APIClient {
    private let configuration: SDKConfiguration
    var responseObserver: ((Data, SamplingClock, SamplingClock) -> Void)?
    var submissionContextProvider: ((@escaping (RequestSubmissionContext?) -> Void) -> Void)?
    var gzipRejectionObserver: ((RequestEncodingLease, @escaping () -> Void) -> Void)?
    var bodyAttemptObserver: ((Int) -> Void)?
    var budgetRejectionObserver: ((Int) -> Void)?
    var clockProvider: () -> SamplingClock = { SamplingClock.now() }
    typealias Transport = (URLRequest, Data, DeliveryPath, ObservationDeliveryReconciliation,
        @escaping () -> Bool, @escaping (Result<Data, Error>) -> Void) -> Void
    var transport: Transport?

    /// Short-timeout session for `.immediateFirst` deliveries. Ephemeral: no cache/cookies,
    /// nothing persisted — the durable path is the background session + OfflineBatchStorage.
    /// 8s request timeout keeps the attempt well inside a ~30s background-task assertion.
    private static let immediateSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.allowsCellularAccess = true
        return URLSession(configuration: config)
    }()

    /// The background session is shared process-wide and created exactly once.
    private var sessionManager: BackgroundSessionManager { BackgroundSessionManager.shared }

    init(configuration: SDKConfiguration) {
        self.configuration = configuration
    }

    static func observationPayload(_ envelope: StoredObservationEnvelope, manifest: SamplingReplayManifest? = nil,
        policy: DataCollectionPolicy = DataCollectionPolicyStore.current) throws -> [String: Any] {
        let filtered = envelope.filtered(policy: policy)
        if let manifest {
            guard let payload = try filtered.replayPayload(manifest: manifest) else { throw APIError.invalidResponse }
            return payload
        }
        var payload = filtered.originalPayload.mapValues { $0.foundationValue }
        if filtered.deliveryProtocol == .adaptive, let sampling = filtered.sampling {
            payload["sampling"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sampling))
        }
        return payload
    }

    func sendObservation(
        _ envelope: StoredObservationEnvelope, storageId: String?, manifest: SamplingReplayManifest? = nil,
        delivery: DeliveryPath = .immediateFirst, attemptObserver: (() -> Void)? = nil,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard let deviceId = envelope.originalPayload["device"]?.object?["deviceId"]?.foundationValue as? String,
              envelope.tenantFingerprint == SamplingTenantFingerprint.make(endpoint: configuration.apiBaseURL,
                  appID: configuration.appId, deviceID: deviceId, businessToken: configuration.businessToken)
        else { completion(.failure(APIError.invalidURL)); return }
        let reconciliation = ObservationDeliveryReconciliation(storageIds: storageId.map { [$0] } ?? [],
            tenantFingerprint: envelope.tenantFingerprint,
            adaptiveBatchId: envelope.deliveryProtocol == .adaptive ? envelope.batchId : nil)
        let eligible: (RequestSubmissionContext, SamplingClock) -> Bool = { context, now in
            guard envelope.deliveryProtocol == .adaptive else { return true }
            guard context.adaptiveAllowedAtSubmission?() ?? context.adaptiveAllowed else { return false }
            return manifest != nil || envelope.sampling?.kind != .live
                || AdaptiveSamplingRuntime.isCurrentLive(envelope, at: now, maxAgeMs: context.liveEvidenceMaxAgeMs)
        }
        submitObservation(delivery: delivery, reconciliation: reconciliation, attemptObserver: attemptObserver,
            isEligible: eligible, body: { context, now in
                if envelope.deliveryProtocol == .adaptive {
                    guard context.adaptiveAllowed else { throw APIError.invalidResponse }
                    if manifest == nil, envelope.sampling?.kind == .live {
                        guard AdaptiveSamplingRuntime.isCurrentLive(envelope, at: now,
                            maxAgeMs: context.liveEvidenceMaxAgeMs) else { throw APIError.invalidResponse }
                    }
                }
                return try JSONSerialization.data(withJSONObject: Self.observationPayload(envelope,
                    manifest: manifest, policy: context.policy))
            }, completion: { result in
                if case .success(let data) = result, envelope.deliveryProtocol == .adaptive,
                   AdaptiveSamplingResponse.decode(data)?.samplingAck?.confirms(envelope.batchId) != true {
                    completion(.failure(APIError.invalidResponse)); return
                }
                completion(result)
            })
    }

    private func submitObservation(delivery: DeliveryPath, reconciliation: ObservationDeliveryReconciliation,
        forceIdentity: Bool = false, attemptObserver: (() -> Void)? = nil,
        isEligible: @escaping (RequestSubmissionContext, SamplingClock) -> Bool = { _, _ in true },
        body: @escaping (RequestSubmissionContext, SamplingClock) throws -> Data,
        completion: @escaping (Result<Data, Error>) -> Void) {
        guard let url = URL(string: "\(configuration.apiBaseURL)/ingest") else {
            completion(.failure(APIError.invalidURL)); return
        }
        var submittedLogicalOperation = false
        func attempt(_ path: DeliveryPath, identityRetry: Bool = false, forceAttemptIdentity: Bool = false) {
            let prepare: (RequestSubmissionContext?) -> Void = { context in
                guard let context else { completion(.failure(APIError.invalidResponse)); return }
                let requestedAt = self.clockProvider()
                let encoded: EncodedRequestBody
                do {
                    let original = try body(context, requestedAt)
                    guard !original.isEmpty, original.count <= min(524_288, context.maximumJSONBytes) else {
                        self.budgetRejectionObserver?(original.count)
                        throw RequestBodyEncoding.Failure.invalidBudget
                    }
                    encoded = try RequestBodyEncoding.encode(original,
                        gzipAllowed: !forceIdentity && !identityRetry && !forceAttemptIdentity && requestedAt.isReliable
                            && context.gzipLease?.bootIdentifier == requestedAt.bootIdentifier
                            && (context.gzipLease?.expiresAtMonotonicMs ?? 0) > requestedAt.monotonicTimeMs
                            && !BackgroundSessionManager.requiresIdentity(reconciliation),
                        maximumJSONBytes: context.maximumJSONBytes)
                } catch { completion(.failure(error)); return }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue(encoded.contentType, forHTTPHeaderField: "Content-Type")
                request.setValue(encoded.contentEncoding, forHTTPHeaderField: "Content-Encoding")
                request.setValue(self.configuration.businessToken, forHTTPHeaderField: "Authorization")
                var descriptor = reconciliation
                descriptor.requestContentEncoding = encoded.contentEncoding
                var preparedEncodingExpired = false
                let submitted: () -> Bool = {
                    let submissionClock = self.clockProvider()
                    guard context.isCurrent(), isEligible(context, submissionClock) else { return false }
                    if encoded.contentEncoding == "gzip" {
                        guard submissionClock.isReliable,
                              context.gzipLease?.bootIdentifier == submissionClock.bootIdentifier,
                              (context.gzipLease?.expiresAtMonotonicMs ?? 0) > submissionClock.monotonicTimeMs else {
                            preparedEncodingExpired = true
                            return false
                        }
                    }
                    if !submittedLogicalOperation {
                        submittedLogicalOperation = true
                        attemptObserver?()
                    }
                    self.bodyAttemptObserver?(encoded.data.count)
                    return true
                }
                self.perform(request, body: encoded.data, path: path, reconciliation: descriptor,
                    willSubmit: submitted) { result in
                    if preparedEncodingExpired {
                        attempt(path, identityRetry: identityRetry, forceAttemptIdentity: true)
                        return
                    }
                    if case .failure(APIError.httpError(let status, _)) = result,
                       status == 415, encoded.contentEncoding == "gzip", !identityRetry,
                       let lease = context.gzipLease {
                        let retry = { attempt(path, identityRetry: true) }
                        if let reject = self.gzipRejectionObserver { reject(lease, retry) } else { retry() }
                        return
                    }
                    if case .failure(let error) = result, path == .immediateFirst, !identityRetry,
                       !(error is APIError) {
                        attempt(.background, forceAttemptIdentity: forceAttemptIdentity)
                        return
                    }
                    if case .success(let data) = result {
                        self.responseObserver?(data, requestedAt, self.clockProvider())
                    }
                    completion(result)
                }
            }
            if let provider = self.submissionContextProvider { provider(prepare) }
            else { prepare(RequestSubmissionContext(policy: DataCollectionPolicyStore.current)) }
        }
        attempt(delivery)
    }

    private func perform(_ request: URLRequest, body: Data, path: DeliveryPath,
        reconciliation: ObservationDeliveryReconciliation, willSubmit: @escaping () -> Bool,
        completion: @escaping (Result<Data, Error>) -> Void) {
        if let transport { transport(request, body, path, reconciliation, willSubmit, completion); return }
        if path == .background {
            sessionManager.uploadObservation(request: request, bodyData: body, reconciliation: reconciliation,
                willSubmit: willSubmit, completion: completion)
            return
        }
        var immediateRequest = request
        immediateRequest.httpBody = body
        guard willSubmit() else { completion(.failure(APIError.invalidResponse)); return }
        let task = Self.immediateSession.dataTask(with: immediateRequest) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse else { completion(.failure(APIError.invalidResponse)); return }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(APIError.httpError(statusCode: http.statusCode))); return
            }
            completion(.success(data ?? Data()))
        }
        task.resume()
    }

    /// Ensures the shared background session is instantiated (re-created after relaunch so
    /// pending delegate callbacks fire). Cheap and idempotent.
    func ensureBackgroundSessionAlive() {
        sessionManager.ensureSessionAlive()
    }

    /// `persistedBatchIds`: OfflineBatchStorage id(s) backing this payload. They ride on the
    /// background task's `taskDescription` so a task that outlives the process can still
    /// reconcile (remove) its batches on success after relaunch. Empty for payloads with no
    /// durable copy (e.g. register).
    /// Which payloads the ingest accepts with an empty `beacons` array.
    ///
    /// Mirrors the ingest payload rules: `register` needs no beacons; other triggers need
    /// encounters, location or Wi-Fi. Anything else gets `400 Missing beacons in payload`.
    ///
    /// Named (rather than inlined) so the rule lives in one place.
    static func acceptsEmptyBeacons(
        syncTrigger: String,
        hasEncounters: Bool,
        hasLocation: Bool = false,
        hasWifis: Bool = false
    ) -> Bool {
        syncTrigger == "register" || hasEncounters || hasLocation || hasWifis
    }

    func sendBeacons(
        _ beacons: [Beacon],
        sdkInfo: SDKInfo,
        userDevice: UserDevice,
        userProperties: UserProperties?,
        syncTrigger: String = "unknown",
        delivery: DeliveryPath = .background,
        persistedBatchIds: [String] = [],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        // A payload with no beacons is sent only when it still carries something the ingest
        // accepts: `register`, encounters, the device's own location, or Wi-Fi. Anything else
        // is answered 400 "Missing beacons in payload". Enforced here, at the boundary.
        //
        // Completes as SUCCESS on purpose: reaching here is an SDK-side mistake, not a delivery
        // failure. Reporting it as a failure would bump `consecutiveFailures` and push the retry
        // drain into exponential backoff — punishing real batches for a request that was never
        // sent. Telemetry carries the signal instead, so the mistake is still visible.
        guard
            !beacons.isEmpty
                || Self.acceptsEmptyBeacons(
                    syncTrigger: syncTrigger,
                    hasEncounters: !userDevice.encounters.isEmpty,
                    hasLocation: userDevice.location != nil,
                    hasWifis: !userDevice.wifis.isEmpty
                )
        else {
            NSLog("[BeAroundSDK] Upload sem beacons bloqueado (syncTrigger=%@) — o ingest só aceita vazio em register", syncTrigger)
            ErrorReporter.shared.report(
                NSError(
                    domain: "BeAroundSDK",
                    code: BearoundErrorCode.invalidPayload.rawValue,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Upload com beacons vazio bloqueado (syncTrigger=\(syncTrigger))"
                    ]
                ),
                context: "sendBeacons.emptyBeacons"
            )
            completion(.success(()))
            return
        }

        let payload = Self.makeObservationPayload(beacons, sdkInfo: sdkInfo, userDevice: userDevice,
            userProperties: userProperties, syncTrigger: syncTrigger)
        let snapshot: StoredObservationEnvelope
        do {
            snapshot = try StoredObservationEnvelope(batchId: UUID().uuidString,
                storedAtMs: clockProvider().wallTimeMs, tenantFingerprint: nil, originalPayload: payload,
                sampling: nil, deliveryProtocol: .legacy)
        } catch { completion(.failure(error)); return }
        submitObservation(delivery: delivery,
            reconciliation: ObservationDeliveryReconciliation(storageIds: persistedBatchIds,
                tenantFingerprint: nil, adaptiveBatchId: nil), forceIdentity: syncTrigger == "register",
            body: { context, _ in
                try JSONSerialization.data(withJSONObject: Self.observationPayload(snapshot, policy: context.policy))
            }, completion: { result in completion(result.map { _ in () }) })
    }

    /// The `sdk` block of the /ingest payload. Extracted so a unit test can assert
    /// exactly what goes on the wire (version + technology). No behavior change.
    static func makeSdkPayload(_ sdkInfo: SDKInfo) -> [String: Any] {
        return [
            "version": sdkInfo.version,
            "platform": sdkInfo.platform,
            "appId": sdkInfo.appId,
            "build": sdkInfo.build,
            "technology": sdkInfo.technology,
        ]
    }

    static func makeObservationPayload(
        _ beacons: [Beacon], sdkInfo: SDKInfo, userDevice: UserDevice,
        userProperties: UserProperties?, syncTrigger: String
    ) -> [String: Any] {
        let beaconsPayload = beacons.map { beacon -> [String: Any] in
            let proximityString: String =
                switch beacon.proximity {
                case .immediate: "immediate"
                case .near: "near"
                case .far: "far"
                case .bt: "bt"
                case .unknown: "unknown"
                }

            var beaconData: [String: Any] = [
                "uuid": beacon.uuid.uuidString,
                "major": beacon.major,
                "minor": beacon.minor,
                "rssi": beacon.rssi,
                "accuracy": beacon.accuracy,
                "proximity": proximityString,
                "timestamp": Int(beacon.timestamp.timeIntervalSince1970 * 1000),
            ]

            if let txPower = beacon.txPower {
                beaconData["txPower"] = txPower
            }

            if let metadata = beacon.metadata {
                var metadataDict: [String: Any] = [
                    "battery": metadata.batteryLevel,
                    "firmware": metadata.firmwareVersion,
                    "movements": metadata.movements,
                    "temperature": metadata.temperature,
                ]

                if let txPower = metadata.txPower {
                    metadataDict["txPower"] = txPower
                }

                if let rssiFromBLE = metadata.rssiFromBLE {
                    metadataDict["rssiFromBLE"] = rssiFromBLE
                }

                if let isConnectable = metadata.isConnectable {
                    metadataDict["isConnectable"] = isConnectable
                }

                beaconData["metadata"] = metadataDict
            }

            return beaconData
        }

        var payload: [String: Any] = [
            "beacons": beaconsPayload,
            "sdk": Self.makeSdkPayload(sdkInfo),
            "device": Self.buildDevicePayload(userDevice),
            "syncTrigger": syncTrigger,
        ]

        if let userProperties, userProperties.hasProperties {
            payload["userProperties"] = userProperties.toDictionary()
        }

        // Wi-Fi observations and location ride at the TOP of the envelope, beside
        // `beacons`, because they describe the sighting — not the device. Both are omitted
        // entirely when unavailable, so a host without the capability sends exactly the
        // payload it sends today.
        if !userDevice.wifis.isEmpty {
            payload["wifis"] = userDevice.wifis.map { $0.toDictionary() }
        }
        if let location = userDevice.location {
            payload["location"] = location.toDictionary()
        }
        // Encounters (same additive contract as `wifis`): omitted entirely when empty.
        if !userDevice.encounters.isEmpty {
            payload["encounters"] = userDevice.encounters.map { $0.toDictionary() }
        }
        if !userDevice.encounterIds.isEmpty {
            payload["encounterIds"] = userDevice.encounterIds
        }

        return payload
    }

    private static func buildDevicePayload(_ device: UserDevice) -> [String: Any] {
        let hardware: [String: Any] = [
            "manufacturer": device.manufacturer,
            "model": device.model,
            "os": device.os ?? "iOS",
            "osVersion": device.osVersion,
        ]

        let screen: [String: Any] = [
            "width": device.screenWidth,
            "height": device.screenHeight,
        ]

        var battery: [String: Any] = [
            "level": device.batteryLevel,
            "isCharging": device.isCharging,
        ]
        if let lowPowerMode = device.lowPowerMode {
            battery["lowPowerMode"] = lowPowerMode
        }

        var network: [String: Any] = [
            "type": device.networkType
        ]
        if let cellularGeneration = device.cellularGeneration {
            network["cellularGeneration"] = cellularGeneration
        }
        if let apId = device.apId {
            network["apId"] = apId
        }
        // Network name — part of the contract, see WifiObservation.ssid.
        if let wifiSSID = device.wifiSSID {
            network["wifiSSID"] = wifiSSID
        }

        var permissions: [String: Any] = [
            "location": device.locationPermission,
            "notifications": device.notificationsPermission,
            "bluetooth": device.bluetoothState,
        ]
        if let locationAccuracy = device.locationAccuracy {
            permissions["locationAccuracy"] = locationAccuracy
        }
        // Advertising ID is sent under `device.permissions.advertisingId`.
        if let advertisingId = device.advertisingId {
            permissions["advertisingId"] = advertisingId
        }
        if let trackingAuthorization = device.trackingAuthorization {
            permissions["trackingAuthorization"] = trackingAuthorization
        }

        let memory: [String: Any] = [
            "totalMb": device.ramTotalMb,
            "availableMb": device.ramAvailableMb,
        ]

        let appState: [String: Any] = [
            "inForeground": device.appInForeground,
            "uptimeMs": device.appUptimeMs,
            "coldStart": device.coldStart,
        ]

        var payload: [String: Any] = [
            "deviceId": device.deviceId,
            "timestamp": device.timestamp,
            "timezone": device.timezone,
            "hardware": hardware,
            "screen": screen,
            "battery": battery,
            "network": network,
            "permissions": permissions,
            "memory": memory,
            "appState": appState,
            "deviceName": device.deviceName,
            "systemLanguage": device.systemLanguage,
            "thermalState": device.thermalState,
            "systemUptimeMs": device.systemUptimeMs,
        ]

        if let carrierName = device.carrierName {
            payload["carrierName"] = carrierName
        }

        if let availableStorageMb = device.availableStorageMb {
            payload["availableStorageMb"] = availableStorageMb
        }

        // Push token (APNs) — the address the backend uses to deliver push to this device.
        // Present only while it still needs syncing (sent once, re-sent only on rotation).
        if let pushToken = device.pushToken {
            payload["pushToken"] = pushToken
        }
        // Native SDK version, always sent in every userDevice payload (with or without a push
        // token): the backend gates rich push (which needs the notification extensions shipped
        // from 3.13.0) on it. Capped at the API's 32 chars.
        payload["sdkVersion"] = String(SDKVersion.resolved.prefix(32))
        // Which APNs endpoint the token targets (sandbox vs production) — so the backend routes right.
        payload["apnsEnvironment"] = device.apnsEnvironment

        return payload
    }
}

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int, body: String? = nil)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid API URL"
        case .invalidResponse:
            "Invalid server response"
        case .httpError(let code, let body):
            if let body, !body.isEmpty {
                "HTTP error: \(code) — \(body)"
            } else {
                "HTTP error: \(code)"
            }
        }
    }
}

