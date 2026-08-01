//
//  APIClient.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import Foundation
import UIKit

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

    static let shared = BackgroundSessionManager()

    /// Must match the identifier the host app forwards via
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    static let backgroundSessionIdentifier = "io.bearound.sdk.upload"

    /// Serializes access to the per-task maps below.
    private let lock = NSLock()
    private var completions: [Int: (Result<Void, Error>) -> Void] = [:]
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
    /// attempts (PR #51 + #52 overlapped on the same fix; this is the reconciliation)
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
        let completion = completions.removeValue(forKey: taskId)
        let responseBody = responseData.removeValue(forKey: taskId)
        let fileURL = taskFiles.removeValue(forKey: taskId)
        lock.unlock()

        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }

        guard let completion else {
            // Orphaned task: the process that created it died and this is the
            // background-relaunch delivery. Nobody is waiting on the completion,
            // but the persisted batch still needs reconciling — on SUCCESS it
            // must be removed, or the retry drain re-sends it (duplicate event).
            // On failure we intentionally do nothing: the batch stays queued.
            let isSuccess = error == nil
                && (task.response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true
            if isSuccess, let ids = task.taskDescription?.split(separator: ",").map(String.init), !ids.isEmpty {
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

    /// Ensures the shared background session is instantiated (re-created after relaunch so
    /// pending delegate callbacks fire). Cheap and idempotent.
    func ensureBackgroundSessionAlive() {
        sessionManager.ensureSessionAlive()
    }

    /// `persistedBatchIds`: OfflineBatchStorage id(s) backing this payload. They ride on the
    /// background task's `taskDescription` so a task that outlives the process can still
    /// reconcile (remove) its batches on success after relaunch. Empty for payloads with no
    /// durable copy (e.g. register).
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
        // Empty-beacons payloads are valid: syncTrigger="register" sends beacons:[] intentionally.
        // The BearoundSDK.syncBeacons() path already guards against empty-list no-ops before
        // calling here, so removing this early-exit does not introduce spurious network requests.

        guard let url = URL(string: "\(configuration.apiBaseURL)/ingest") else {
            completion(.failure(APIError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.businessToken, forHTTPHeaderField: "Authorization")

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
            "device": buildDevicePayload(userDevice),
            "syncTrigger": syncTrigger,
        ]

        if let userProperties, userProperties.hasProperties {
            payload["userProperties"] = userProperties.toDictionary()
        }

        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(error))
            return
        }

        // Background sessions don't allow `httpBody` on upload tasks — the body must be
        // passed as `Data`. Don't set request.httpBody here.
        switch delivery {
        case .background:
            NSLog("[BeAroundSDK] Sending %d beacon(s) to %@ trigger=%@ (background upload)", beacons.count, url.absoluteString, syncTrigger)
            sessionManager.upload(request: request, bodyData: bodyData, persistedBatchIds: persistedBatchIds, completion: completion)
        case .immediateFirst:
            NSLog("[BeAroundSDK] Sending %d beacon(s) to %@ trigger=%@ (immediate upload)", beacons.count, url.absoluteString, syncTrigger)
            sendImmediate(request: request, bodyData: bodyData, persistedBatchIds: persistedBatchIds, completion: completion)
        }
    }

    /// `.immediateFirst` delivery: short-timeout data task now; background session only as
    /// the transport-failure fallback. See `DeliveryPath` for the full rationale.
    private func sendImmediate(
        request: URLRequest,
        bodyData: Data,
        persistedBatchIds: [String],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var immediateRequest = request
        immediateRequest.httpBody = bodyData

        let task = Self.immediateSession.dataTask(with: immediateRequest) { [sessionManager] responseBody, response, error in
            if let error {
                // Transport failure (offline, timeout, connection lost): the request may have
                // never reached the backend — re-queue on the durable background session.
                NSLog("[BeAroundSDK] Immediate upload transport failure (%@) — falling back to background session", error.localizedDescription)
                DetectionLogStore.append(type: "Sync", detail: "envio imediato falhou (\(error.localizedDescription)) — fallback para background session")
                sessionManager.upload(request: request, bodyData: bodyData, persistedBatchIds: persistedBatchIds, completion: completion)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(APIError.invalidResponse))
                return
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                // The backend answered — an identical retry on the background session would
                // get the same status. Surface the error; persisted-batch retry owns it.
                let body = responseBody.flatMap { String(data: $0, encoding: .utf8) }
                    .map { String($0.prefix(512)) }
                    .flatMap { $0.isEmpty ? nil : $0 }
                NSLog("[BeAroundSDK] Immediate upload: HTTP %d body=%@", httpResponse.statusCode, body ?? "—")
                completion(.failure(APIError.httpError(statusCode: httpResponse.statusCode, body: body)))
                return
            }

            NSLog("[BeAroundSDK] Immediate upload succeeded (HTTP %d)", httpResponse.statusCode)
            DetectionLogStore.append(type: "Sync", detail: "entregue via sessão imediata (HTTP \(httpResponse.statusCode))")
            completion(.success(()))
        }
        task.resume()
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

    private func buildDevicePayload(_ device: UserDevice) -> [String: Any] {
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

