//
//  DeviceIdentifier.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import Foundation
import UIKit

/// Device identifier — stable for the lifetime of the install, stored in **UserDefaults**
/// (simple local storage).
///
/// Priority on first generation: IDFV (`identifierForVendor`) > generated UUID.
/// Persisted only in UserDefaults — so it is wiped when the user deletes the app (we no longer
/// keep it in the Keychain across reinstalls). IDFV may still survive a reinstall while the vendor
/// has other apps installed; otherwise a fresh id is generated on reinstall.
class DeviceIdentifier {

    // MARK: - Persistent Cache (UserDefaults)

    private enum StorageKey {
        static let deviceId = "io.bearound.sdk.persistent.deviceId"
        static let deviceIdType = "io.bearound.sdk.persistent.deviceIdType"
    }

    private static var _deviceId: String?
    private static var _deviceIdType: String?

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

        if let id = _deviceId {
            NSLog("[BeAroundSDK] Device identity loaded from storage: type=%@, id=%@...",
                  _deviceIdType ?? "unknown", String(id.prefix(8)))
        }
    }

    // MARK: - Device ID

    /// Initializes deviceId if it doesn't exist yet. Must be called within lock.
    private static func initializeDeviceIdIfNeeded() {
        loadFromStorage()

        guard _deviceId == nil else { return }

        // First time on this install: compute and persist to UserDefaults.
        // Priority: IDFV > Generated UUID (never null).
        let id: String
        let type: String

        if let idfv = UIDevice.current.identifierForVendor?.uuidString {
            id = idfv
            type = "idfv"
        } else {
            // Device locked on first boot — IDFV unavailable; generate one.
            id = UUID().uuidString
            type = "generated"
        }

        _deviceId = id
        _deviceIdType = type

        let defaults = UserDefaults.standard
        defaults.set(id, forKey: StorageKey.deviceId)
        defaults.set(type, forKey: StorageKey.deviceIdType)

        NSLog("[BeAroundSDK] Device ID set: type=%@, id=%@...", type, String(id.prefix(8)))
    }

    // MARK: - Public API

    /// Device ID — stable for the lifetime of the install (stored in UserDefaults).
    static func getDeviceId() -> String {
        lock.lock()
        defer { lock.unlock() }
        initializeDeviceIdIfNeeded()
        return _deviceId!
    }

    /// Type of device ID (`idfv`, `generated`).
    static func getDeviceIdType() -> String {
        lock.lock()
        defer { lock.unlock() }
        initializeDeviceIdIfNeeded()
        return _deviceIdType ?? "unknown"
    }
}
