//
//  DeviceIdentifier.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import AdSupport
import AppTrackingTransparency
import Foundation
import UIKit

class DeviceIdentifier {
    private static let keychainKey = "io.bearound.sdk.deviceId"

    // MARK: - Cache (1-hour TTL)

    private static let cacheTTL: TimeInterval = 3600
    private static var cachedDeviceId: String?
    private static var cachedDeviceIdType: String?
    private static var cachedAdvertisingId: String?
    private static var cachedAdTrackingEnabled: Bool = false
    private static var cacheTimestamp: Date?
    private static let cacheLock = NSLock()

    private static var isCacheValid: Bool {
        guard let timestamp = cacheTimestamp else { return false }
        return Date().timeIntervalSince(timestamp) < cacheTTL
    }

    /// Refreshes the identity cache if expired (thread-safe)
    private static func refreshCacheIfNeeded() {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard !isCacheValid else { return }

        // Compute ad tracking status and IDFA
        let adTrackingEnabled: Bool
        if #available(iOS 14, *) {
            adTrackingEnabled = ATTrackingManager.trackingAuthorizationStatus == .authorized
        } else {
            adTrackingEnabled = ASIdentifierManager.shared().isAdvertisingTrackingEnabled
        }

        var idfa: String?
        if adTrackingEnabled {
            let idfaUUID = ASIdentifierManager.shared().advertisingIdentifier
            let idfaString = idfaUUID.uuidString
            if idfaString != "00000000-0000-0000-0000-000000000000" {
                idfa = idfaString
            }
        }

        // Compute device ID (priority: IDFA > Keychain > IDFV)
        let deviceId: String
        let deviceIdType: String

        if let idfa {
            deviceId = idfa
            deviceIdType = "idfa"
        } else if let keychainId = getKeychainUUID() {
            deviceId = keychainId
            deviceIdType = "keychain_uuid"
        } else {
            deviceId = getIDFV()
            deviceIdType = "idfv"
            KeychainHelper.save(deviceId, forKey: keychainKey)
        }

        cachedDeviceId = deviceId
        cachedDeviceIdType = deviceIdType
        cachedAdvertisingId = idfa
        cachedAdTrackingEnabled = adTrackingEnabled
        cacheTimestamp = Date()

        NSLog("[BeAroundSDK] Device identity cached for 1h: type=%@, adTracking=%d", deviceIdType, adTrackingEnabled ? 1 : 0)
    }

    // MARK: - Public API

    static func getDeviceId() -> String {
        refreshCacheIfNeeded()
        return cachedDeviceId ?? getIDFV()
    }

    static func getDeviceIdType() -> String {
        refreshCacheIfNeeded()
        return cachedDeviceIdType ?? "idfv"
    }

    static func getAdvertisingId() -> String? {
        refreshCacheIfNeeded()
        return cachedAdvertisingId
    }

    static func isAdTrackingEnabled() -> Bool {
        refreshCacheIfNeeded()
        return cachedAdTrackingEnabled
    }

    // MARK: - Private Helpers

    private static func getKeychainUUID() -> String? {
        if let existingId = KeychainHelper.retrieve(forKey: keychainKey) {
            return existingId
        }

        let newId = UUID().uuidString
        if KeychainHelper.save(newId, forKey: keychainKey) {
            return newId
        }

        return nil
    }

    private static func getIDFV() -> String {
        UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    }
}
