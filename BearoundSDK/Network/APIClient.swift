//
//  APIClient.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import Foundation
import UIKit

class APIClient {
    private let configuration: SDKConfiguration
    private let session: URLSession

    init(configuration: SDKConfiguration) {
        self.configuration = configuration

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
    }

    func sendBeacons(
        _ beacons: [Beacon],
        sdkInfo: SDKInfo,
        userDevice: UserDevice,
        userProperties: UserProperties?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard !beacons.isEmpty else {
            completion(.success(()))
            return
        }

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
                case .unknown: "unknown"
                @unknown default: "unknown"
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
            "sdk": [
                "version": sdkInfo.version,
                "platform": sdkInfo.platform,
                "appId": sdkInfo.appId,
                "build": sdkInfo.build,
            ],
            "device": buildDevicePayload(userDevice),
        ]

        if let userProperties, userProperties.hasProperties {
            payload["userProperties"] = userProperties.toDictionary()
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(error))
            return
        }

        print("BeAroundSDK: Sending \(beacons.count) beacons to \(url.absoluteString)")
        let task = session.dataTask(with: request) { _, response, error in
            if let error {
                print("BeAroundSDK: Request failed - \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                print("BeAroundSDK: Invalid response received")
                completion(.failure(APIError.invalidResponse))
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                print("BeAroundSDK: HTTP error - \(httpResponse.statusCode)")
                completion(.failure(APIError.httpError(statusCode: httpResponse.statusCode)))
                return
            }

            print(
                "BeAroundSDK: Successfully sent \(beacons.count) beacons (HTTP \(httpResponse.statusCode))"
            )
            completion(.success(()))
        }

        task.resume()
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
        if let advertisingId = device.advertisingId {
            permissions["advertisingId"] = advertisingId
        }
        permissions["adTrackingEnabled"] = device.adTrackingEnabled

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

        if let location = device.deviceLocation {
            var locationDict: [String: Any] = [
                "latitude": location.latitude,
                "longitude": location.longitude,
                "timestamp": Int(location.timestamp.timeIntervalSince1970 * 1000),
            ]

            if let accuracy = location.accuracy {
                locationDict["accuracy"] = accuracy
            }
            if let altitude = location.altitude {
                locationDict["altitude"] = altitude
            }
            if let altitudeAccuracy = location.altitudeAccuracy {
                locationDict["altitudeAccuracy"] = altitudeAccuracy
            }
            if let heading = location.heading {
                locationDict["heading"] = heading
            }
            if let course = location.course {
                locationDict["course"] = course
            }
            if let courseAccuracy = location.courseAccuracy {
                locationDict["courseAccuracy"] = courseAccuracy
            }
            if let speed = location.speed {
                locationDict["speed"] = speed
            }
            if let speedAccuracy = location.speedAccuracy {
                locationDict["speedAccuracy"] = speedAccuracy
            }
            if let floor = location.floor {
                locationDict["floor"] = floor
            }
            if let sourceInfo = location.sourceInfo {
                locationDict["sourceInfo"] = sourceInfo
            }

            payload["deviceLocation"] = locationDict
        }

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

