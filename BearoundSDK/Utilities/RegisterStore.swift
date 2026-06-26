//
//  RegisterStore.swift
//  BearoundSDK
//
//  Created by Bearound on 26/06/26.
//

import Foundation

/// Persists the device-register heartbeat and decides when a register POST is due.
///
/// A register is sent once at SDK start and repeated when:
/// - It has never been sent (first launch).
/// - The device fingerprint changed (different businessToken, appId, sdkVersion, osVersion,
///   or appBuild) — meaning the device identity or SDK installation changed.
/// - More than `ttl` (24 h) have elapsed since the last successful register.
///
/// The fingerprint covers only stable fields so routine runtime changes (network type, battery,
/// permissions) do NOT trigger a re-register.
enum RegisterStore {
    private static let lastSentAtKey   = "io.bearound.sdk.register.lastSentAt"
    private static let lastFingerprintKey = "io.bearound.sdk.register.lastFingerprint"
    private static let ttl: TimeInterval = 24 * 60 * 60 // 24 hours

    private static let defaults = UserDefaults.standard
    private static let lock = NSLock()

    // MARK: - Decision

    /// Returns `true` when the SDK should send a register POST.
    ///
    /// Criteria (any one is sufficient):
    /// 1. Never registered before (`lastSentAt` absent).
    /// 2. The fingerprint changed (businessToken / appId / sdkVersion / osVersion / appBuild
    ///    differ from what was recorded on the last successful register).
    /// 3. More than 24 h elapsed since the last successful register.
    static func shouldRegister(currentFingerprint: String) -> Bool {
        lock.lock(); defer { lock.unlock() }

        guard let lastSentAt = defaults.object(forKey: lastSentAtKey) as? Date else {
            return true // never registered
        }

        if defaults.string(forKey: lastFingerprintKey) != currentFingerprint {
            return true // fingerprint changed
        }

        return Date().timeIntervalSince(lastSentAt) > ttl // TTL elapsed
    }

    // MARK: - Persistence

    /// Records a successful register. Must be called only on HTTP 200.
    static func markRegistered(fingerprint: String) {
        lock.lock(); defer { lock.unlock() }
        defaults.set(Date(), forKey: lastSentAtKey)
        defaults.set(fingerprint, forKey: lastFingerprintKey)
    }

    // MARK: - Fingerprint builder

    /// Builds the fingerprint string from stable device/SDK identity fields.
    ///
    /// Uses the same `deviceId` sourced from `DeviceIdentifier`, so if the keychain UUID
    /// ever changes (e.g., reinstall on a device that lost keychain access), the fingerprint
    /// changes and a re-register is triggered automatically.
    static func fingerprint(
        deviceId: String,
        appId: String,
        businessToken: String,
        sdkVersion: String,
        osVersion: String,
        appBuild: String
    ) -> String {
        "\(deviceId)|\(appId)|\(businessToken)|\(sdkVersion)|\(osVersion)|\(appBuild)"
    }

    // MARK: - Test helpers

    /// Wipes persisted state. Used by unit tests only.
    static func _clearForTesting() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: lastSentAtKey)
        defaults.removeObject(forKey: lastFingerprintKey)
    }

    static var lastSentAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return defaults.object(forKey: lastSentAtKey) as? Date
    }

    static var lastFingerprint: String? {
        lock.lock(); defer { lock.unlock() }
        return defaults.string(forKey: lastFingerprintKey)
    }
}
