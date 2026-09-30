//
//  PushTokenStore.swift
//  BearoundSDK
//
//  Created by Bearound on 02/06/26.
//

import Foundation

/// Stores the APNs push token and decides when to (re)send it: on change, every `ttl`
/// (heartbeat), or once after the SDK version changed since the last send.
enum PushTokenStore {
    private static let tokenKey = "io.bearound.sdk.pushToken"
    private static let lastSentKey = "io.bearound.sdk.pushTokenLastSent"
    private static let lastSentAtKey = "io.bearound.sdk.pushTokenLastSentAt"
    /// SDK version that rode with the last delivered token. The backend decides push
    /// capabilities (e.g. rich push) from the `sdkVersion` sent next to the token, so an
    /// upgraded SDK must re-send the token once or the device stays on its old capabilities
    /// until the token rotates, which may never happen.
    private static let lastSentVersionKey = "io.bearound.sdk.pushTokenLastSentSdkVersion"
    private static let ttl: TimeInterval = 7 * 24 * 60 * 60 // 7 days

    private static let defaults = UserDefaults.standard
    private static let lock = NSLock()

    static func setToken(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        defaults.set(token, forKey: tokenKey)
    }

    static var tokenForPayload: String? {
        lock.lock(); defer { lock.unlock() }
        guard let token = defaults.string(forKey: tokenKey), !token.isEmpty else { return nil }
        let send = shouldSend(
            token: token,
            lastSent: defaults.string(forKey: lastSentKey),
            lastSentAt: defaults.object(forKey: lastSentAtKey) as? Date,
            lastSentVersion: defaults.string(forKey: lastSentVersionKey),
            currentVersion: SDKVersion.resolved
        )
        return send ? token : nil
    }

    /// Pure send decision: a new token, an SDK version different from the one that rode
    /// with the last send (includes installs that predate this key), or the TTL heartbeat.
    static func shouldSend(
        token: String,
        lastSent: String?,
        lastSentAt: Date?,
        lastSentVersion: String?,
        currentVersion: String,
        now: Date = Date()
    ) -> Bool {
        if token != lastSent { return true }
        if lastSentVersion != currentVersion { return true }
        guard let lastSentAt else { return true }
        return now.timeIntervalSince(lastSentAt) > ttl // heartbeat: TTL elapsed since last send
    }

    /// Marks `exactToken` as delivered. Pass the token that actually RODE in the
    /// payload (`userDevice.pushToken`). A nil/empty argument is a no-op: the
    /// payload carried no token, and blindly marking the CURRENT token would
    /// (a) reset `lastSentAt` on every successful sync, so the 7-day heartbeat
    /// re-send never fires, and (b) mark a token that rotated mid-request as
    /// sent even though it never reached the server.
    static func markSent(_ exactToken: String?) {
        guard let token = exactToken, !token.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        defaults.set(token, forKey: lastSentKey)
        defaults.set(Date(), forKey: lastSentAtKey)
        defaults.set(SDKVersion.resolved, forKey: lastSentVersionKey)
    }

    static var maskedToken: String? {
        lock.lock(); defer { lock.unlock() }
        guard let t = defaults.string(forKey: tokenKey), !t.isEmpty else { return nil }
        guard t.count >= 12 else { return "\(t.prefix(2))…" }
        return "\(t.prefix(8))…\(t.suffix(4))"
    }

    static var lastSentAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return defaults.object(forKey: lastSentAtKey) as? Date
    }
}
