//
//  LegacyAppPresenceCleanup.swift
//  BearoundSDK
//
//  The app presence feature shipped in 3.16.x and has been removed. This deletes what it left
//  on the device: the JSON records under `Application Support/BeAroundSDK/AppPresence/` and
//  the `app_presence_configuration` key of the SDK config suite. It runs on every SDK start and
//  is idempotent: once both are gone it only checks that they are still absent, and a deletion
//  that failed (for example on a relaunch before the first unlock) is retried on the next start.
//

import Foundation

enum LegacyAppPresenceCleanup {
    /// Suite the 3.16.x configuration was written to (the one `SDKConfigStorage` uses).
    static let configurationSuiteName = "com.bearound.sdk.config"
    /// Key the 3.16.x configuration was written under.
    static let configurationKey = "app_presence_configuration"

    /// The 3.16.x record directory, `Application Support/BeAroundSDK/AppPresence`. The
    /// temporary-directory fallback is the one 3.16.x used when Application Support was missing.
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("BeAroundSDK", isDirectory: true)
            .appendingPathComponent("AppPresence", isDirectory: true)
    }

    /// Deletes the configuration key and the record directory, then the `BeAroundSDK` parent
    /// directory when that removal left it empty (3.16.x was its only writer). Never throws.
    /// - Returns: `true` when something was deleted.
    @discardableResult
    static func run(
        defaults: UserDefaults? = UserDefaults(suiteName: LegacyAppPresenceCleanup.configurationSuiteName),
        directory: URL = LegacyAppPresenceCleanup.defaultDirectory(),
        fileManager: FileManager = .default
    ) -> Bool {
        var deleted = false

        if let defaults, defaults.object(forKey: configurationKey) != nil {
            defaults.removeObject(forKey: configurationKey)
            defaults.synchronize()
            deleted = true
        }

        if fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.removeItem(at: directory)
                deleted = true
                let parent = directory.deletingLastPathComponent()
                if let remaining = try? fileManager.contentsOfDirectory(atPath: parent.path), remaining.isEmpty {
                    try? fileManager.removeItem(at: parent)
                }
            } catch {
                NSLog("[BeAroundSDK] Legacy app presence records not deleted, retrying on next start: %@",
                      error.localizedDescription)
            }
        }

        if deleted {
            NSLog("[BeAroundSDK] Deleted data stored by the removed app presence feature")
        }
        return deleted
    }
}
