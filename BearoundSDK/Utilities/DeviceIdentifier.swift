//
//  DeviceIdentifier.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import Foundation

/// Device identifier — the most stable id available on iOS.
///
/// It is a UUID **generated once and stored in the Keychain**, which survives app reinstalls
/// (Keychain items persist across uninstall). It is NOT derived from IDFA/IDFV — those can reset
/// (IDFA is user-resettable; IDFV resets when all of the vendor's apps are removed), so they are
/// not stable enough to be the device identity. UserDefaults is kept only as a fast read cache.
class DeviceIdentifier {
    private static let keychainKey = "io.bearound.sdk.deviceId"

    private enum StorageKey {
        static let deviceId = "io.bearound.sdk.persistent.deviceId"
        static let deviceIdType = "io.bearound.sdk.persistent.deviceIdType"
    }

    private static var _deviceId: String?
    private static var _deviceIdType: String?
    private static let lock = NSLock()

    /// Resolves (and persists) the deviceId once. Must be called within `lock`.
    private static func initializeDeviceIdIfNeeded() {
        guard _deviceId == nil else { return }

        let defaults = UserDefaults.standard
        let id: String

        // The Keychain is the durable source of truth — it survives reinstall, so the deviceId
        // stays the same across delete + reinstall.
        if let keychainId = KeychainHelper.retrieve(forKey: keychainKey) {
            id = keychainId
        } else if let cached = defaults.string(forKey: StorageKey.deviceId) {
            // Migrate an id that previously lived only in UserDefaults into the Keychain,
            // so from now on it survives the next reinstall.
            id = cached
            KeychainHelper.save(id, forKey: keychainKey)
        } else {
            // First time ever on this device — generate and persist to the Keychain.
            id = UUID().uuidString
            KeychainHelper.save(id, forKey: keychainKey)
        }

        _deviceId = id
        _deviceIdType = "keychain_uuid"

        defaults.set(id, forKey: StorageKey.deviceId)
        defaults.set(_deviceIdType, forKey: StorageKey.deviceIdType)

        NSLog("[BeAroundSDK] Device ID (keychain): %@...", String(id.prefix(8)))
    }

    // MARK: - Public API

    /// Device ID — stable UUID kept in the Keychain (survives reinstall). Never null.
    static func getDeviceId() -> String {
        lock.lock()
        defer { lock.unlock() }
        initializeDeviceIdIfNeeded()
        return _deviceId!
    }

    /// Type of device ID (always `keychain_uuid` in the current implementation).
    static func getDeviceIdType() -> String {
        lock.lock()
        defer { lock.unlock() }
        initializeDeviceIdIfNeeded()
        return _deviceIdType ?? "unknown"
    }
}
