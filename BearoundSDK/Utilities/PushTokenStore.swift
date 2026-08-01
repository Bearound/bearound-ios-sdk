//
//  PushTokenStore.swift
//  BearoundSDK
//
//  Created by Bearound on 02/06/26.
//

import Foundation

/// Stores the APNs push token and decides when to (re)send it: on change or every `ttl` (heartbeat).
enum PushTokenStore {
    private static let tokenKey = "io.bearound.sdk.pushToken"
    private static let lastSentKey = "io.bearound.sdk.pushTokenLastSent"
    private static let lastSentAtKey = "io.bearound.sdk.pushTokenLastSentAt"
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
        let lastSent = defaults.string(forKey: lastSentKey)
        if token != lastSent { return token }
        if let at = defaults.object(forKey: lastSentAtKey) as? Date,
           Date().timeIntervalSince(at) <= ttl {
            return nil
        }
        return token // heartbeat: TTL elapsed since last send → re-send
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
