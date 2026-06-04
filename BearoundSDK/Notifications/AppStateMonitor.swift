//
//  AppStateMonitor.swift
//  BearoundSDK
//
//  Observes UIApplication lifecycle + data-protection notifications to expose
//  the current process state without ever blocking the main thread.
//
//  Possible states (mapped 1:1 with the Android `DetectionLogStore` tags):
//
//  - `foreground` — app is active and on screen
//  - `background` — app is in background, device screen UNLOCKED
//  - `backgroundLocked` — app is in background, device screen LOCKED
//  - `terminated` — process just relaunched (cold start) and the UI has not
//    yet reached `didBecomeActive`. Typical when the system wakes the SDK
//    via BLE state restoration or region monitoring while the app is killed.
//
//  Why a dedicated monitor:
//  - `DispatchQueue.main.sync` from a background callback can deadlock.
//  - iOS reports `.background` both for "user backgrounded" and for "system
//    relaunched a terminated app" — the two are indistinguishable via
//    `applicationState`. We track `wasEverActive` to separate them.
//  - Screen-lock state is exposed via `isProtectedDataAvailable` plus the
//    `applicationProtectedDataDidBecomeUnavailable/Available` notifications.
//

import Foundation
import UIKit

public enum AppStateMonitor {
    private static let lock = NSLock()
    private static var initialized = false
    private static var cachedState: UIApplication.State = .background
    private static var wasEverActive = false
    private static var screenLocked = false

    /// State tag persisted by `DetectionLogStore`.
    public enum Tag: String {
        case foreground
        case background
        case backgroundLocked
        case terminated
    }

    /// Best-effort tag of the current process state. Safe from any thread.
    public static func currentTag() -> Tag {
        ensureInitialized()
        lock.lock()
        let state = cachedState
        let active = wasEverActive
        let locked = screenLocked
        lock.unlock()

        // The process just relaunched (cold start) and the UI never became
        // active — treat events as "terminated" rather than "background".
        if !active {
            return .terminated
        }

        switch state {
        case .active:
            return .foreground
        case .background, .inactive:
            return locked ? .backgroundLocked : .background
        @unknown default:
            return .background
        }
    }

    private static func ensureInitialized() {
        lock.lock()
        let already = initialized
        if !already {
            initialized = true
        }
        lock.unlock()
        guard !already else { return }

        if Thread.isMainThread {
            seedFromMain()
        } else {
            DispatchQueue.main.async { seedFromMain() }
        }

        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            lock.lock()
            cachedState = .active
            wasEverActive = true
            // didBecomeActive implies the device is unlocked.
            screenLocked = false
            lock.unlock()
        }
        center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            lock.lock()
            cachedState = .inactive
            lock.unlock()
        }
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            lock.lock()
            cachedState = .background
            lock.unlock()
        }
        center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            lock.lock()
            cachedState = .inactive
            lock.unlock()
        }
        // Protected data — best available proxy for "device locked".
        // `unavailable` fires ~10s after the user locks the screen.
        center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { _ in
            lock.lock()
            screenLocked = false
            lock.unlock()
        }
        center.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil,
            queue: .main
        ) { _ in
            lock.lock()
            screenLocked = true
            lock.unlock()
        }
    }

    private static func seedFromMain() {
        let state = UIApplication.shared.applicationState
        let locked = !UIApplication.shared.isProtectedDataAvailable
        lock.lock()
        cachedState = state
        screenLocked = locked
        if state == .active { wasEverActive = true }
        lock.unlock()
    }
}

// MARK: - Internal detection log (UserDefaults-backed JSON)

/// Persisted detection log. Survives foreground/background/closed/terminated
/// transitions (UserDefaults persists across cold starts). Each entry is tagged
/// with the process state at write-time via `AppStateMonitor` — including a
/// `"terminated"` tag for events that fire during a system-initiated relaunch
/// (BLE state restoration / region monitoring) before the app becomes active.
///
/// This is an internal diagnostic log surfaced to host apps via
/// `BeAroundSDK.getDetectionLogJson()` / `clearDetectionLog()`. It is NOT a
/// user-facing notification mechanism — it only records detection events.
///
/// Mirrors the Android `DetectionLogStore`.
public enum DetectionLogStore {
    private static let storageKey = "bearound_sdk_log"
    private static let maxEntries = 500
    private static let writeLock = NSLock()

    public static func append(type: String, detail: String) {
        // Tag computed BEFORE acquiring the storage lock so multiple
        // concurrent writes don't reorder relative to UIApplication state.
        let tag = AppStateMonitor.currentTag().rawValue

        writeLock.lock()
        defer { writeLock.unlock() }

        let defaults = UserDefaults.standard
        var arr = (defaults.array(forKey: storageKey) as? [[String: Any]]) ?? []
        let entry: [String: Any] = [
            "id": "\(Date().timeIntervalSince1970)-\(Int.random(in: 0...9999))",
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "state": tag,
            "type": type,
            "detail": detail,
        ]
        arr.insert(entry, at: 0)
        if arr.count > maxEntries { arr = Array(arr.prefix(maxEntries)) }
        defaults.set(arr, forKey: storageKey)
        // Force a flush so terminated-relaunch entries survive an immediate
        // process exit by the system right after the wake-up callback.
        defaults.synchronize()
    }

    public static func readJSON() -> String {
        let arr = (UserDefaults.standard.array(forKey: storageKey) as? [[String: Any]]) ?? []
        guard
            let data = try? JSONSerialization.data(withJSONObject: arr),
            let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
