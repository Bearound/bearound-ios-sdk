//
//  AppPresenceStore.swift
//  BearoundSDK
//
//  Durable, private storage for the app presence feature: one JSON record per namespace
//  (host bundle + business token hash) holding the cooldown reservation and the latest
//  snapshot. The reservation is written atomically (temp file + fsync + rename) before any
//  platform query, and eligibility is decided by monotonic time, never by the wall clock.
//

import Foundation

// MARK: - Clock

/// Time sources used by the store. Injected so tests can move each clock independently.
struct AppPresenceClock {
    /// Wall clock (UTC). Only used for the informative `reservedAt` and the boot estimate.
    var wallNow: () -> Date
    /// Seconds since boot, including time spent asleep (`mach_continuous_time`).
    var monotonicNow: () -> TimeInterval

    static let system = AppPresenceClock(
        wallNow: { Date() },
        monotonicNow: { AppPresenceClock.continuousSeconds() }
    )

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func continuousSeconds() -> TimeInterval {
        let ticks = mach_continuous_time()
        let nanoseconds = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
        return nanoseconds / 1_000_000_000
    }
}

// MARK: - File I/O

/// File operations used by the store. Injected so tests can simulate failures.
protocol AppPresenceFileIO {
    /// Returns nil when the file does not exist.
    func read(_ url: URL) throws -> Data?
    /// Must be durable when it returns: temp file, fsync, rename.
    func writeAtomically(_ data: Data, to url: URL) throws
}

struct AppPresenceDiskIO: AppPresenceFileIO {
    func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(excluded)

        let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(tempURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        var closed = false
        defer {
            if !closed { close(descriptor) }
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else {
            let error = posixError()
            unlink(tempURL.path)
            throw error
        }
        close(descriptor)
        closed = true
        guard rename(tempURL.path, url.path) == 0 else {
            let error = posixError()
            unlink(tempURL.path)
            throw error
        }
        // Persist the directory entry of the rename as well.
        let directoryDescriptor = open(directory.path, O_RDONLY)
        if directoryDescriptor >= 0 {
            fsync(directoryDescriptor)
            close(directoryDescriptor)
        }
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

// MARK: - Record

/// On-disk record for one namespace. Holds a single reservation and the latest snapshot,
/// never a history of results.
struct AppPresenceRecord: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var namespaceHash: String
    var hasReservation: Bool
    /// Informative only: the wall clock never releases the cooldown.
    var reservedAt: Date?
    /// `mach_continuous_time` seconds at reservation time.
    var reservedMonotonic: TimeInterval?
    /// Wall clock minus uptime at reservation time (seconds since 1970).
    var bootEpochEstimate: TimeInterval?
    var lastSnapshot: AppPresenceSnapshot?
    var fingerprint: String?

    init(namespaceHash: String) {
        schemaVersion = Self.currentSchemaVersion
        self.namespaceHash = namespaceHash
        hasReservation = false
    }
}

// MARK: - Namespace

/// Isolation key: host bundle + SHA-256 of the business token. Only its hash is ever
/// written (file name and record); the token itself never leaves memory.
struct AppPresenceNamespace: Equatable {
    let hash: String

    init(bundleIdentifier: String?, businessToken: String) {
        let tokenHash = AppPresenceHashing.sha256Hex(Data(businessToken.utf8))
        let raw = "\(bundleIdentifier ?? "")\n\(tokenHash)"
        hash = AppPresenceHashing.sha256Hex(Data(raw.utf8))
    }
}

// MARK: - Store

enum AppPresenceReservation: Equatable {
    case reserved
    /// Cooldown (or quarantine) still running; seconds until eligible.
    case notEligible(remaining: TimeInterval)
}

struct AppPresenceStorageUnavailableError: Error, Equatable {
    static let code = "app_presence_storage_unavailable"
}

/// Thread-safe (serial queue) store. One instance per process in production.
final class AppPresenceStore {
    /// Minimum interval between reservations of the same namespace.
    static let minimumInterval: TimeInterval = 3600
    /// Tolerance when comparing the boot epoch estimate across launches.
    static let bootEpochTolerance: TimeInterval = 2

    private let directory: URL
    private let io: AppPresenceFileIO
    private let clock: AppPresenceClock
    /// Monotonic time of this process launch (or of store creation, which is later and
    /// therefore more conservative).
    private let launchMonotonic: TimeInterval
    private let queue = DispatchQueue(label: "com.bearound.sdk.appPresenceStore")

    /// Per-namespace monotonic anchor of the running cooldown, resolved once per process.
    /// `.some(nil)` means "eligible now"; a missing key means "not loaded yet".
    private var anchors: [String: TimeInterval?] = [:]

    init(
        directory: URL = AppPresenceStore.defaultDirectory(),
        io: AppPresenceFileIO = AppPresenceDiskIO(),
        clock: AppPresenceClock = .system,
        launchMonotonic: TimeInterval? = nil
    ) {
        self.directory = directory
        self.io = io
        self.clock = clock
        self.launchMonotonic = launchMonotonic ?? clock.monotonicNow()
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("BeAroundSDK", isDirectory: true)
            .appendingPathComponent("AppPresence", isDirectory: true)
    }

    func fileURL(for namespace: AppPresenceNamespace) -> URL {
        directory.appendingPathComponent("\(namespace.hash).json")
    }

    // MARK: Reservation

    /// Reserves the next window when eligible. The reservation is durable on disk before this
    /// returns `.reserved`. A write failure throws and keeps the window closed for this
    /// process (fail-closed), so callers never query without a durable reservation.
    func reserve(_ namespace: AppPresenceNamespace) throws -> AppPresenceReservation {
        try queue.sync {
            let now = clock.monotonicNow()
            let anchor = resolveAnchor(namespace, now: now)
            if let anchor {
                let elapsed = now - anchor
                if elapsed < Self.minimumInterval {
                    return .notEligible(remaining: Self.minimumInterval - elapsed)
                }
            }
            var record = (try? loadRecord(namespace)) ?? AppPresenceRecord(namespaceHash: namespace.hash)
            let wall = clock.wallNow()
            record.hasReservation = true
            record.reservedAt = wall
            record.reservedMonotonic = now
            record.bootEpochEstimate = wall.timeIntervalSince1970 - now
            // Consumed in memory first: a failed write must not allow a retry loop.
            anchors[namespace.hash] = .some(now)
            do {
                try write(record, namespace)
            } catch {
                throw AppPresenceStorageUnavailableError()
            }
            return .reserved
        }
    }

    /// Seconds until the namespace is eligible (0 when eligible now). Never writes, except
    /// for the quarantine rewrite of a corrupt or ambiguous record.
    func remainingCooldown(_ namespace: AppPresenceNamespace) -> TimeInterval {
        queue.sync {
            let now = clock.monotonicNow()
            guard let anchor = resolveAnchor(namespace, now: now) else { return 0 }
            return max(0, Self.minimumInterval - (now - anchor))
        }
    }

    // MARK: Snapshot

    /// Persists the latest snapshot, keeping the reservation untouched.
    func saveSnapshot(_ snapshot: AppPresenceSnapshot, _ namespace: AppPresenceNamespace) throws {
        try queue.sync {
            var record = (try? loadRecord(namespace)) ?? AppPresenceRecord(namespaceHash: namespace.hash)
            record.lastSnapshot = snapshot
            record.fingerprint = snapshot.configurationFingerprint
            do {
                try write(record, namespace)
            } catch {
                throw AppPresenceStorageUnavailableError()
            }
        }
    }

    /// Latest snapshot, or nil when absent or unreadable (a read error never fabricates data).
    func loadSnapshot(_ namespace: AppPresenceNamespace) -> AppPresenceSnapshot? {
        queue.sync {
            guard let record = try? loadRecord(namespace),
                  let snapshot = record.lastSnapshot,
                  snapshot.configurationFingerprint == record.fingerprint else { return nil }
            return snapshot
        }
    }

    /// Removes the snapshot and keeps the cooldown marker (prevents an A/B/A or
    /// disable/enable bypass of the window).
    func clearSnapshot(_ namespace: AppPresenceNamespace) {
        queue.sync {
            guard var record = try? loadRecord(namespace),
                  record.lastSnapshot != nil || record.fingerprint != nil else { return }
            record.lastSnapshot = nil
            record.fingerprint = nil
            try? write(record, namespace)
        }
    }

    // MARK: Internals (queue only)

    /// Decides the cooldown anchor once per process and namespace:
    /// - no record: first install, eligible now;
    /// - corrupt record: quarantine from launch and rewrite;
    /// - same boot (epoch estimate within tolerance, monotonic not regressive): reuse the
    ///   persisted reservation;
    /// - anything else (reboot, clock change): quarantine from launch.
    /// After that, only monotonic time in this process moves the anchor.
    private func resolveAnchor(_ namespace: AppPresenceNamespace, now: TimeInterval) -> TimeInterval? {
        if let cached = anchors[namespace.hash] { return cached }

        let anchor: TimeInterval?
        let data: Data?
        do {
            data = try io.read(fileURL(for: namespace))
        } catch {
            // Unreadable file: fail-closed, but do not rewrite what we could not read.
            anchors[namespace.hash] = .some(launchMonotonic)
            return launchMonotonic
        }

        if let data {
            if let record = decode(data, namespace) {
                if !record.hasReservation {
                    anchor = nil
                } else if let reservedMonotonic = record.reservedMonotonic,
                          let storedEpoch = record.bootEpochEstimate,
                          reservedMonotonic <= now,
                          abs(currentBootEpoch(atMonotonic: now) - storedEpoch) <= Self.bootEpochTolerance {
                    anchor = reservedMonotonic
                } else {
                    anchor = quarantine(namespace, keeping: record)
                }
            } else {
                anchor = quarantine(namespace, keeping: nil)
            }
        } else {
            anchor = nil
        }
        anchors[namespace.hash] = .some(anchor)
        return anchor
    }

    /// Re-anchors the reservation at this launch and persists it, so later relaunches in the
    /// same boot count the quarantine from the first launch. A failed rewrite still keeps
    /// the in-memory quarantine (fail-closed).
    private func quarantine(_ namespace: AppPresenceNamespace, keeping record: AppPresenceRecord?) -> TimeInterval {
        var rewritten = AppPresenceRecord(namespaceHash: namespace.hash)
        rewritten.lastSnapshot = record?.lastSnapshot
        rewritten.fingerprint = record?.fingerprint
        rewritten.hasReservation = true
        rewritten.reservedMonotonic = launchMonotonic
        let launchWall = clock.wallNow().addingTimeInterval(launchMonotonic - clock.monotonicNow())
        rewritten.reservedAt = launchWall
        rewritten.bootEpochEstimate = launchWall.timeIntervalSince1970 - launchMonotonic
        try? write(rewritten, namespace)
        return launchMonotonic
    }

    private func currentBootEpoch(atMonotonic monotonic: TimeInterval) -> TimeInterval {
        clock.wallNow().timeIntervalSince1970 - monotonic
    }

    private func loadRecord(_ namespace: AppPresenceNamespace) throws -> AppPresenceRecord? {
        guard let data = try io.read(fileURL(for: namespace)) else { return nil }
        return decode(data, namespace)
    }

    private func decode(_ data: Data, _ namespace: AppPresenceNamespace) -> AppPresenceRecord? {
        guard let record = try? Self.decoder.decode(AppPresenceRecord.self, from: data),
              record.schemaVersion == AppPresenceRecord.currentSchemaVersion,
              record.namespaceHash == namespace.hash else { return nil }
        return record
    }

    private func write(_ record: AppPresenceRecord, _ namespace: AppPresenceNamespace) throws {
        let data = try Self.encoder.encode(record)
        try io.writeAtomically(data, to: fileURL(for: namespace))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
