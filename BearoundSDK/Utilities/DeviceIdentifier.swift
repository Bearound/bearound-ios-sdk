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

    // MARK: - Persistent Cache (UserDefaults)

    private enum StorageKey {
        static let deviceId = "io.bearound.sdk.persistent.deviceId"
        static let deviceIdType = "io.bearound.sdk.persistent.deviceIdType"
        static let advertisingId = "io.bearound.sdk.persistent.advertisingId"
    }

    private static var _deviceId: String?
    private static var _deviceIdType: String?
    private static var _advertisingId: String?

    private static let lock = NSLock()
    private static var loaded = false

    // MARK: - Storage

    /// Load persisted values into memory (once per process)
    private static func loadFromStorage() {
        guard !loaded else { return }
        loaded = true

        let defaults = UserDefaults.standard
        _deviceId = defaults.string(forKey: StorageKey.deviceId)
        _deviceIdType = defaults.string(forKey: StorageKey.deviceIdType)
        _advertisingId = defaults.string(forKey: StorageKey.advertisingId)

        if let id = _deviceId {
            NSLog("[BeAroundSDK] Device identity loaded from storage: type=%@, id=%@...",
                  _deviceIdType ?? "unknown", String(id.prefix(8)))
        }
    }

    // MARK: - Device ID (permanent — never changes once set)

    /// Initializes deviceId if it doesn't exist yet. Must be called within lock.
    private static func initializeDeviceIdIfNeeded() {
        loadFromStorage()

        guard _deviceId == nil else { return }

        // First time ever: compute and persist forever
        // Priority: Keychain UUID > IDFV > Generated UUID > IDFA (last resort)
        let id: String
        let type: String

        if let keychainId = getKeychainUUID() {
            id = keychainId
            type = "keychain_uuid"
        } else if let idfv = UIDevice.current.identifierForVendor?.uuidString {
            id = idfv
            type = "idfv"
            KeychainHelper.save(id, forKey: keychainKey)
        } else if let idfa = computeIDFA() {
            id = idfa
            type = "idfa"
            KeychainHelper.save(id, forKey: keychainKey)
        } else {
            // Last resort (device locked on first boot) — generate and persist
            let uuid = UUID().uuidString
            id = uuid
            type = "generated"
            KeychainHelper.save(id, forKey: keychainKey)
        }

        _deviceId = id
        _deviceIdType = type

        let defaults = UserDefaults.standard
        defaults.set(id, forKey: StorageKey.deviceId)
        defaults.set(type, forKey: StorageKey.deviceIdType)

        NSLog("[BeAroundSDK] Device ID set permanently: type=%@, id=%@...", type, String(id.prefix(8)))
    }

    // MARK: - IDFA (cached, updated only when system value changes)

    /// Checks current system IDFA and updates cache if it changed.
    /// Must be called within lock.
    private static func refreshAdvertisingIdIfNeeded() {
        let currentIdfa = computeIDFA()

        if currentIdfa != _advertisingId {
            _advertisingId = currentIdfa
            UserDefaults.standard.set(currentIdfa, forKey: StorageKey.advertisingId)

            if let idfa = currentIdfa {
                NSLog("[BeAroundSDK] IDFA updated in cache: %@...", String(idfa.prefix(8)))
            } else {
                NSLog("[BeAroundSDK] IDFA removed from cache (tracking revoked)")
            }
        }
    }

    // MARK: - Public API

    /// Device ID — permanent, never changes once generated
    static func getDeviceId() -> String {
        lock.lock()
        defer { lock.unlock() }
        initializeDeviceIdIfNeeded()
        return _deviceId!
    }

    /// Type of device ID (idfa, keychain_uuid, idfv, generated)
    static func getDeviceIdType() -> String {
        lock.lock()
        defer { lock.unlock() }
        initializeDeviceIdIfNeeded()
        return _deviceIdType ?? "unknown"
    }

    /// IDFA — cached, updated only when the system value differs
    static func getAdvertisingId() -> String? {
        lock.lock()
        defer { lock.unlock() }
        loadFromStorage()
        refreshAdvertisingIdIfNeeded()
        return _advertisingId
    }

    /// Live check of ad tracking authorization
    static func isAdTrackingEnabled() -> Bool {
        if #available(iOS 14, *) {
            return ATTrackingManager.trackingAuthorizationStatus == .authorized
        } else {
            return ASIdentifierManager.shared().isAdvertisingTrackingEnabled
        }
    }

    // MARK: - Private Helpers

    private static func computeIDFA() -> String? {
        let enabled: Bool
        if #available(iOS 14, *) {
            enabled = ATTrackingManager.trackingAuthorizationStatus == .authorized
        } else {
            enabled = ASIdentifierManager.shared().isAdvertisingTrackingEnabled
        }

        guard enabled else { return nil }

        let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        guard idfa != "00000000-0000-0000-0000-000000000000" else { return nil }
        return idfa
    }

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
}
