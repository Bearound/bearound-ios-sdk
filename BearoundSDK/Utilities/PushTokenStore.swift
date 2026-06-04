//
//  PushTokenStore.swift
//  BearoundSDK
//
//  Created by Bearound on 02/06/26.
//

import Foundation

/// Stores the device's push token (APNs) and whether it has already been synced to the backend.
///
/// The token is the address used to deliver push to this device. It is sent **once** with the
/// next sync and re-sent **only if it changes** (APNs tokens rotate on reinstall, restore, etc.).
/// The stable identity remains `DeviceIdentifier.getDeviceId()` — the token is a mutable attribute.
enum PushTokenStore {
    private static let tokenKey = "io.bearound.sdk.pushToken"
    private static let syncedKey = "io.bearound.sdk.pushTokenSynced"
    private static let defaults = UserDefaults.standard
    private static let lock = NSLock()

    /// Registers a push token. If it differs from the stored one, marks it unsynced so the next
    /// sync includes it. No-op when the token is unchanged (idempotent — safe to call every launch).
    static func setToken(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        guard token != defaults.string(forKey: tokenKey) else { return }
        defaults.set(token, forKey: tokenKey)
        defaults.set(false, forKey: syncedKey)
    }

    /// The token to include in the payload — non-nil only while it hasn't been synced yet.
    /// Returns nil once the token has been delivered, so it stops riding along on every request.
    static var unsyncedToken: String? {
        lock.lock(); defer { lock.unlock() }
        guard let token = defaults.string(forKey: tokenKey), !token.isEmpty else { return nil }
        return defaults.bool(forKey: syncedKey) ? nil : token
    }

    /// Marks the current token as synced so it stops being included in future payloads.
    /// Called after a successful sync.
    static func markSynced() {
        lock.lock(); defer { lock.unlock() }
        guard defaults.string(forKey: tokenKey) != nil else { return }
        defaults.set(true, forKey: syncedKey)
    }
}
