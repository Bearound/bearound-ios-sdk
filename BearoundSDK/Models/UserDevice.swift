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
    /// "sandbox" | "production" — which APNs endpoint the token targets (from the app's entitlement).
    let apnsEnvironment: String
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
    /// Hash of the connected access point's BSSID — the identity the backend uses.
    let apId: String?
    /// Name of the connected network.
    ///
    /// **Temporary — kept for validating the collection while the access-point map is being
    /// built.** `apId` is the field that matters; remove this one (and
    /// `WifiObservation.ssid`) once the collection is trusted.
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
    /// Access points visible at collection time. On iOS this is at most one — the access
    /// point the device is joined to — and empty when the host app lacks the Access WiFi
    /// Information capability or location authorisation.
    var wifis: [WifiObservation] = []
    /// Cached fix, as context for `wifis` and for the beacons in the same payload. The SDK
    /// never starts a location request of its own.
    var location: DeviceLocation? = nil
    /// IDFA — present only after the user authorises tracking via App Tracking Transparency.
    var advertisingId: String? = nil
    /// ATT status: `authorized`, `denied`, `restricted`, `notDetermined`, or `unavailable`
    /// below iOS 14. Reported alongside the id so a refusal is distinguishable from a prompt
    /// that was never shown.
    var trackingAuthorization: String? = nil
}
