//
//  LegacyAppPresenceCleanupTests.swift
//  BearoundSDKTests
//
//  Every test runs on its own UserDefaults suite and temporary directory, so none of them
//  touches the shared "com.bearound.sdk.config" suite or the real Application Support.
//

import Foundation
import Testing

@testable import BearoundSDK

@Suite("LegacyAppPresenceCleanup Tests")
struct LegacyAppPresenceCleanupTests {
    /// Stands in for the config suite and Application Support of a device that ran 3.16.x.
    private struct Sandbox {
        let suiteName = "io.bearound.sdk.tests.legacy-cleanup.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-cleanup-\(UUID().uuidString)", isDirectory: true)
        let defaults: UserDefaults

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
        }

        var parent: URL { root.appendingPathComponent("BeAroundSDK", isDirectory: true) }
        var directory: URL { parent.appendingPathComponent("AppPresence", isDirectory: true) }

        /// Writes what 3.16.x left: the configuration key, one namespace record and the
        /// leftover of an interrupted atomic write.
        func seedLegacyData() throws {
            defaults.set(Data(#"{"enabled":true,"targets":[]}"#.utf8), forKey: LegacyAppPresenceCleanup.configurationKey)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(#"{"schemaVersion":1}"#.utf8)
                .write(to: directory.appendingPathComponent("\(String(repeating: "a", count: 64)).json"))
            try Data().write(to: directory.appendingPathComponent(".record.json.tmp"))
        }

        func run() -> Bool {
            LegacyAppPresenceCleanup.run(defaults: defaults, directory: directory)
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("Deletes the stored configuration key and the record directory left by 3.16.x")
    func deletesLegacyData() throws {
        let sandbox = Sandbox()
        defer { sandbox.tearDown() }
        try sandbox.seedLegacyData()

        #expect(sandbox.run())

        #expect(sandbox.defaults.object(forKey: LegacyAppPresenceCleanup.configurationKey) == nil)
        #expect(!FileManager.default.fileExists(atPath: sandbox.directory.path))
        // 3.16.x was the only writer of the parent directory: nothing of it is left behind.
        #expect(!FileManager.default.fileExists(atPath: sandbox.parent.path))
    }

    @Test("Keeps the other configuration keys and any other file in the SDK directory")
    func keepsUnrelatedData() throws {
        let sandbox = Sandbox()
        defer { sandbox.tearDown() }
        try sandbox.seedLegacyData()
        sandbox.defaults.set("token", forKey: "business_token")
        let sibling = sandbox.parent.appendingPathComponent("other.json")
        try Data("{}".utf8).write(to: sibling)

        #expect(sandbox.run())

        #expect(sandbox.defaults.string(forKey: "business_token") == "token")
        #expect(FileManager.default.fileExists(atPath: sibling.path))
        #expect(!FileManager.default.fileExists(atPath: sandbox.directory.path))
    }

    @Test("A second run, or a run on an install without the data, deletes nothing")
    func idempotent() throws {
        let sandbox = Sandbox()
        defer { sandbox.tearDown() }
        try sandbox.seedLegacyData()

        #expect(sandbox.run())
        #expect(!sandbox.run())

        let clean = Sandbox()
        defer { clean.tearDown() }
        clean.defaults.set("token", forKey: "business_token")
        #expect(!clean.run())
        #expect(clean.defaults.string(forKey: "business_token") == "token")
        #expect(!FileManager.default.fileExists(atPath: clean.root.path))
    }

    @Test("Default targets are the 3.16.x record directory and config suite")
    func defaultLocations() throws {
        let appSupport = try #require(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        #expect(LegacyAppPresenceCleanup.defaultDirectory().path
            == appSupport.appendingPathComponent("BeAroundSDK/AppPresence").path)
        #expect(LegacyAppPresenceCleanup.configurationSuiteName == "com.bearound.sdk.config")
        #expect(LegacyAppPresenceCleanup.configurationKey == "app_presence_configuration")
    }
}
