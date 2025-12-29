//
//  UserDevice.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import Foundation

struct DeviceLocation {
    let latitude: Double
    let longitude: Double
    let accuracy: Double?
    let altitude: Double?
    let altitudeAccuracy: Double?
    let heading: Double?
    let speed: Double?
    let speedAccuracy: Double?
    let course: Double?
    let courseAccuracy: Double?
    let floor: Int?
    let timestamp: Date
    let sourceInfo: String?
}

struct UserDevice {
    let deviceId: String
    let manufacturer: String
    let model: String
    let osVersion: String
    let timestamp: Int
    let timezone: String
    let batteryLevel: Int
    let isCharging: Bool
    let bluetoothState: String
    let locationPermission: String
    let notificationsPermission: String
    let networkType: String
    let cellularGeneration: String?
    let isRoaming: Bool?
    let ramTotalMb: Int
    let ramAvailableMb: Int
    let screenWidth: Int
    let screenHeight: Int
    let adTrackingEnabled: Bool
    let appInForeground: Bool
    let appUptimeMs: Int
    let coldStart: Bool
    let advertisingId: String?
    let lowPowerMode: Bool?
    let locationAccuracy: String?
    let wifiSSID: String?
    let connectionMetered: Bool?
    let connectionExpensive: Bool?
    let os: String?
    let deviceLocation: DeviceLocation?
    let deviceName: String
    let carrierName: String?
    let availableStorageMb: Int?
    let systemLanguage: String
    let thermalState: String
    let systemUptimeMs: Int
}
