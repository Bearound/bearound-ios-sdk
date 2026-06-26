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

    /// The single background session. Lazily created exactly once, then retained forever.
    private(set) lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: BackgroundSessionManager.backgroundSessionIdentifier
        )
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.timeoutIntervalForResource = 86400
        NSLog("[BeAroundSDK] Created background URLSession '%@'", BackgroundSessionManager.backgroundSessionIdentifier)
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    /// Touching `.session` forces the lazy session to instantiate so pending delegate
    /// callbacks (from a background-relaunch) are delivered. Safe to call repeatedly — the
    /// lazy guarantees only one session per identifier is ever created.
    func ensureSessionAlive() {
        _ = session
    }

    /// Stores the system completion handler delivered on background-relaunch and makes sure
    /// the session is reconstructed so the OS can hand us the pending events.
    func setSystemEventsCompletionHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        systemEventsCompletionHandler = handler
        lock.unlock()
        ensureSessionAlive()
    }

    /// Uploads `bodyData` to `request` on the background session.
    /// Background sessions reject `httpBody` on upload tasks, so the body is passed as `Data`.
    func upload(
        request: URLRequest,
        bodyData: Data,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        // Background sessions reject in-memory NSData uploads ("Upload tasks from NSData are
        // not supported in background sessions") — the body MUST be a file. Write it to a temp
        // file and upload fromFile; the file is deleted in didCompleteWithError.
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
        responseData.removeValue(forKey: taskId)
        let fileURL = taskFiles.removeValue(forKey: taskId)
        lock.unlock()

        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }

        guard let completion else { return }

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
            NSLog("[BeAroundSDK] Upload task %d: HTTP %d", taskId, httpResponse.statusCode)
            completion(.failure(APIError.httpError(statusCode: httpResponse.statusCode)))
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
        lock.unlock()

        if let handler {
            NSLog("[BeAroundSDK] Background URLSession finished events — calling system handler")
            DispatchQueue.main.async {
                handler()
            }
        }
    }
}

class APIClient {
    private let configuration: SDKConfiguration

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

    func sendBeacons(
        _ beacons: [Beacon],
        sdkInfo: SDKInfo,
        userDevice: UserDevice,
        userProperties: UserProperties?,
        syncTrigger: String = "unknown",
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
        NSLog("[BeAroundSDK] Sending %d beacon(s) to %@ trigger=%@ (background upload)", beacons.count, url.absoluteString, syncTrigger)
        sessionManager.upload(request: request, bodyData: bodyData, completion: completion)
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
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid API URL"
        case .invalidResponse:
            "Invalid server response"
        case .httpError(let code):
            "HTTP error: \(code)"
        }
    }
}

