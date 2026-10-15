//
//  AppPresenceStoreTests.swift
//  BearoundSDKTests
//
//  App presence store: durable reservation, 3600 s cooldown decided by monotonic time,
//  restart in the same boot, quarantine on clock change / reboot / corruption, write
//  failure fail-closed, namespace isolation and snapshot retention.
//

import Foundation
import Testing

@testable import BearoundSDK

/// Clock whose wall and monotonic readings move independently.
final class AppPresenceTestClock {
    var wall: Date
    var monotonic: TimeInterval

    init(wall: Date = Date(timeIntervalSince1970: 1_800_000_000), monotonic: TimeInterval = 10_000) {
        self.wall = wall
        self.monotonic = monotonic
    }

    /// Normal passage of time: both clocks move together.
    func advance(_ seconds: TimeInterval) {
        wall = wall.addingTimeInterval(seconds)
        monotonic += seconds
    }

    var clock: AppPresenceClock {
        AppPresenceClock(wallNow: { self.wall }, monotonicNow: { self.monotonic })
    }
}

/// Reads from disk, refuses every write.
struct AppPresenceFailingWriteIO: AppPresenceFileIO {
    func read(_ url: URL) throws -> Data? { try AppPresenceDiskIO().read(url) }
    func writeAtomically(_ data: Data, to url: URL) throws {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    }
}

func appPresenceTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("bearound-app-presence-tests-\(UUID().uuidString)", isDirectory: true)
}

@Suite("AppPresence Store Tests")
struct AppPresenceStoreTests {
    private let directory = appPresenceTemporaryDirectory()
    private let clock = AppPresenceTestClock()
    private let namespaceA = AppPresenceNamespace(bundleIdentifier: "io.bearound.fixture.host", businessToken: "token-A")
    private let namespaceB = AppPresenceNamespace(bundleIdentifier: "io.bearound.fixture.host", businessToken: "token-B")

    /// A new instance models a new process launched at the current monotonic time.
    private func launchStore(io: AppPresenceFileIO = AppPresenceDiskIO()) -> AppPresenceStore {
        AppPresenceStore(directory: directory, io: io, clock: clock.clock, launchMonotonic: clock.monotonic)
    }

    private func remaining(_ reservation: AppPresenceReservation) -> TimeInterval? {
        if case .notEligible(let remaining) = reservation { return remaining }
        return nil
    }

    private func record(_ store: AppPresenceStore, _ namespace: AppPresenceNamespace) throws -> AppPresenceRecord {
        let data = try Data(contentsOf: store.fileURL(for: namespace))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(AppPresenceRecord.self, from: data)
    }

    private func snapshot() -> AppPresenceSnapshot {
        AppPresenceSnapshot(
            configurationFingerprint: "fingerprint-1",
            checkedAt: clock.wall,
            results: [AppPresenceResult(targetId: "a", state: .absent, checkedAt: clock.wall, detectionMethod: .iosUrlScheme)]
        )
    }

    // MARK: - Cooldown

    @Test("First install reserves immediately and the reservation is on disk before returning")
    func firstInstallReservesImmediately() throws {
        let store = launchStore()
        #expect(try store.reserve(namespaceA) == .reserved)
        let persisted = try record(store, namespaceA)
        #expect(persisted.hasReservation)
        #expect(persisted.reservedMonotonic == clock.monotonic)
        #expect(persisted.bootEpochEstimate == clock.wall.timeIntervalSince1970 - clock.monotonic)
        #expect(persisted.namespaceHash == namespaceA.hash)
    }

    @Test("Cooldown boundary: 3599 s is not eligible, 3600 s is")
    func cooldownBoundary() throws {
        let store = launchStore()
        #expect(try store.reserve(namespaceA) == .reserved)
        clock.advance(3599)
        #expect(remaining(try store.reserve(namespaceA)) == 1)
        clock.advance(1)
        #expect(try store.reserve(namespaceA) == .reserved)
    }

    @Test("Restart in the same boot reuses the elapsed interval instead of quarantining")
    func restartInSameBootReusesInterval() throws {
        #expect(try launchStore().reserve(namespaceA) == .reserved)
        clock.advance(1800)
        let relaunched = launchStore()
        #expect(remaining(try relaunched.reserve(namespaceA)) == 1800)
        clock.advance(1800)
        #expect(try relaunched.reserve(namespaceA) == .reserved)
    }

    @Test("Wall clock moved forward does not release the window, in process or after relaunch")
    func wallClockForwardDoesNotRelease() throws {
        let store = launchStore()
        #expect(try store.reserve(namespaceA) == .reserved)
        clock.advance(60)
        clock.wall = clock.wall.addingTimeInterval(7200)
        #expect(remaining(try store.reserve(namespaceA)) == 3540)

        // Relaunch after the change: boot estimate no longer matches, quarantine from launch.
        let relaunched = launchStore()
        #expect(remaining(try relaunched.reserve(namespaceA)) == 3600)
        clock.advance(3599)
        #expect(remaining(try relaunched.reserve(namespaceA)) == 1)
        clock.advance(1)
        #expect(try relaunched.reserve(namespaceA) == .reserved)
    }

    @Test("Wall clock moved back does not release the window, in process or after relaunch")
    func wallClockBackDoesNotRelease() throws {
        let store = launchStore()
        #expect(try store.reserve(namespaceA) == .reserved)
        clock.advance(3000)
        clock.wall = clock.wall.addingTimeInterval(-86_400)
        #expect(remaining(try store.reserve(namespaceA)) == 600)

        let relaunched = launchStore()
        #expect(remaining(try relaunched.reserve(namespaceA)) == 3600)
    }

    @Test("Reboot (monotonic regressive) quarantines 3600 s from launch")
    func rebootQuarantines() throws {
        #expect(try launchStore().reserve(namespaceA) == .reserved)
        clock.wall = clock.wall.addingTimeInterval(600)
        clock.monotonic = 30
        let rebooted = launchStore()
        #expect(remaining(try rebooted.reserve(namespaceA)) == 3600)
        // The quarantine is persisted: a second relaunch in this boot counts from the first.
        clock.advance(1000)
        #expect(remaining(try launchStore().reserve(namespaceA)) == 2600)
    }

    @Test("Crash right after the reservation consumes the window")
    func crashAfterReservationConsumesWindow() throws {
        let store = launchStore()
        #expect(try store.reserve(namespaceA) == .reserved)
        // Process dies before any snapshot is written.
        clock.advance(10)
        #expect(remaining(try launchStore().reserve(namespaceA)) == 3590)
        #expect(launchStore().loadSnapshot(namespaceA) == nil)
    }

    @Test("Corrupt record quarantines from launch and is rewritten as a valid record")
    func corruptRecordQuarantinesAndRewrites() throws {
        let store = launchStore()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.fileURL(for: namespaceA))

        #expect(remaining(try store.reserve(namespaceA)) == 3600)
        let rewritten = try record(store, namespaceA)
        #expect(rewritten.hasReservation)
        #expect(rewritten.reservedMonotonic == clock.monotonic)
    }

    @Test("Write failure throws storage unavailable and stays closed for the process")
    func writeFailureFailsClosed() throws {
        let store = launchStore(io: AppPresenceFailingWriteIO())
        #expect(throws: AppPresenceStorageUnavailableError.self) {
            try store.reserve(namespaceA)
        }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: namespaceA).path))
        // No retry loop: the next trigger in the same process is not eligible.
        clock.advance(15)
        #expect(remaining(try store.reserve(namespaceA)) != nil)
    }

    // MARK: - Isolation and snapshot

    @Test("A/B/A business token switch keeps A's reservation")
    func tokenSwitchKeepsReservation() throws {
        let store = launchStore()
        #expect(try store.reserve(namespaceA) == .reserved)
        #expect(try store.reserve(namespaceB) == .reserved)
        clock.advance(100)
        #expect(remaining(try store.reserve(namespaceA)) == 3500)
        #expect(remaining(try launchStore().reserve(namespaceA)) == 3500)
    }

    @Test("Business token never appears in file names or file contents")
    func tokenNeverPersisted() throws {
        let token = "secret-business-token-123"
        let namespace = AppPresenceNamespace(bundleIdentifier: "io.bearound.fixture.host", businessToken: token)
        let store = launchStore()
        #expect(try store.reserve(namespace) == .reserved)
        try store.saveSnapshot(snapshot(), namespace)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 1)
        for file in files {
            #expect(!file.contains(token))
            let contents = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            #expect(!contents.contains(token))
        }
    }

    @Test("Snapshot survives relaunch; clearing it keeps the cooldown marker")
    func snapshotRetentionAndClear() throws {
        let store = launchStore()
        #expect(try store.reserve(namespaceA) == .reserved)
        let saved = snapshot()
        try store.saveSnapshot(saved, namespaceA)
        #expect(launchStore().loadSnapshot(namespaceA) == saved)

        store.clearSnapshot(namespaceA)
        #expect(store.loadSnapshot(namespaceA) == nil)
        let persisted = try record(store, namespaceA)
        #expect(persisted.hasReservation)
        #expect(persisted.lastSnapshot == nil)
        clock.advance(5)
        #expect(remaining(try launchStore().reserve(namespaceA)) == 3595)
    }
}
