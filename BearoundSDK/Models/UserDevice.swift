//
//  UserDevice.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import Foundation

struct UserDevice {
    let deviceId: String
    /// APNs push token — the address used to deliver push. Nil unless it still needs syncing.
    let pushToken: String?
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
    let ramTotalMb: Int
    let ramAvailableMb: Int
    let screenWidth: Int
    let screenHeight: Int
    let appInForeground: Bool
    let appUptimeMs: Int
    let coldStart: Bool
    let lowPowerMode: Bool?
    let locationAccuracy: String?
    let wifiSSID: String?
    let connectionMetered: Bool?
    let connectionExpensive: Bool?
    let os: String?
    let deviceName: String
    let carrierName: String?
    let availableStorageMb: Int?
    let systemLanguage: String
    let thermalState: String
    let systemUptimeMs: Int
}
