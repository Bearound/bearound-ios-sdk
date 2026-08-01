//
//  OfflineBatchStorage.swift
//  BearoundSDK
//
//  Created by Bearound on 17/01/26.
//  Persistent storage for failed beacon batches that survives app restarts
//

import Foundation

/// Manages persistent storage of failed beacon batches
/// Stores batches as JSON files in Application Support directory
/// Features:
/// - FIFO ordering (oldest batch sent first)
/// - Auto-cleanup of batches older than 7 days
/// - Respects maximum queue size from configuration
///
/// Thread-safety: every public entry point runs on the serial `storageQueue`
/// (callers come from beaconQueue, the URLSession delegate queue and the host's
/// main thread via the public diagnostics API — unserialized, two of them could
/// interleave directory listing with file removal). Internal `_`-prefixed
/// helpers assume they are already on the queue and must NOT call the public
/// wrappers (re-entrant `sync` on a serial queue deadlocks).
class OfflineBatchStorage {

    // MARK: - Configuration

    /// Maximum age for stored batches (7 days)
    private let maxBatchAge: TimeInterval = 7 * 24 * 60 * 60

    /// Default directory name for batch storage
    private static let defaultDirectoryName = "com.bearound.sdk.batches"

    /// Directory name for this instance's batch storage. Injectable so unit tests
    /// can isolate each case in its own directory (the default is production).
    private let directoryName: String

    // MARK: - Codable Types for JSON Serialization

    private struct StoredBatch: Codable {
        let id: String
        let timestamp: Date
        let beacons: [StoredBeacon]
    }

    private struct StoredBeacon: Codable {
        let uuid: String
        let major: Int
        let minor: Int
        let rssi: Int
        let proximity: Int  // BeaconProximity raw value
        let accuracy: Double
        let timestamp: Date
        let metadata: StoredBeaconMetadata?
        let txPower: Int?

        init(from beacon: Beacon) {
            self.uuid = beacon.uuid.uuidString
            self.major = beacon.major
            self.minor = beacon.minor
            self.rssi = beacon.rssi
            self.proximity = beacon.proximity.rawValue
            self.accuracy = beacon.accuracy
            self.timestamp = beacon.timestamp
            self.txPower = beacon.txPower

            if let meta = beacon.metadata {
                self.metadata = StoredBeaconMetadata(from: meta)
            } else {
                self.metadata = nil
            }
        }

        /// Returns nil for a corrupted record instead of masking it: the previous
        /// `UUID(uuidString:) ?? UUID()` fallback invented a brand-new random UUID,
        /// which then shipped to the ingester as a legitimate-looking beacon from a
        /// namespace that never existed.
        func toBeacon() -> Beacon? {
            guard let beaconUUID = UUID(uuidString: uuid) else { return nil }
            let beaconProximity = BeaconProximity(rawValue: proximity) ?? .unknown

            var beaconMetadata: BeaconMetadata?
            if let meta = metadata {
                beaconMetadata = meta.toBeaconMetadata()
            }

            return Beacon(
                uuid: beaconUUID,
                major: major,
                minor: minor,
                rssi: rssi,
                proximity: beaconProximity,
                accuracy: accuracy,
                timestamp: timestamp,
                metadata: beaconMetadata,
                txPower: txPower
            )
        }
    }

    private struct StoredBeaconMetadata: Codable {
        let firmwareVersion: String
        let batteryLevel: Int
        let movements: Int
        let temperature: Int
        let txPower: Int?
        let rssiFromBLE: Int?
        let isConnectable: Bool?

        init(from metadata: BeaconMetadata) {
            self.firmwareVersion = metadata.firmwareVersion
            self.batteryLevel = metadata.batteryLevel
            self.movements = metadata.movements
            self.temperature = metadata.temperature
            self.txPower = metadata.txPower
            self.rssiFromBLE = metadata.rssiFromBLE
            self.isConnectable = metadata.isConnectable
        }

        func toBeaconMetadata() -> BeaconMetadata {
            BeaconMetadata(
                firmwareVersion: firmwareVersion,
                batteryLevel: batteryLevel,
                movements: movements,
                temperature: temperature,
                txPower: txPower,
                rssiFromBLE: rssiFromBLE,
                isConnectable: isConnectable
            )
        }
    }

    /// A stored batch identified by its on-disk id — lets the retry drain remove
    /// EXACTLY the batches it sent, instead of "the N oldest at removal time"
    /// (which may differ from the N oldest at load time if a save/enforce/expiry
    /// ran in between — the positional pair could delete an unsent batch).
    struct StoredBatchRecord {
        let id: String
        let beacons: [Beacon]
    }

    /// Process-wide instance over the default directory. All production code MUST
    /// use this one: the store's thread-safety comes from its per-instance serial
    /// queue, so two instances over the same directory would race each other.
    /// (The `init(directoryName:)` stays available for tests over isolated dirs.)
    static let shared = OfflineBatchStorage()

    // MARK: - Properties

    private let fileManager = FileManager.default
    /// Serializes every filesystem operation of this store.
    private let storageQueue = DispatchQueue(label: "com.bearound.sdk.batchStorage", qos: .utility)

    /// Maximum number of batches to store (default from MaxQueuedPayloads.medium).
    /// Backed by the queue: written from configure(), read inside enforcement.
    private var _maxBatchCount: Int = MaxQueuedPayloads.medium.value
    var maxBatchCount: Int {
        get { storageQueue.sync { _maxBatchCount } }
        set { storageQueue.sync { _maxBatchCount = newValue } }
    }

    /// Storage directory URL
    private var storageDirectory: URL? {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            NSLog("[BeAroundSDK] Failed to get Application Support directory")
            return nil
        }
        return appSupport.appendingPathComponent(directoryName)
    }

    // MARK: - Initialization

    init(directoryName: String = OfflineBatchStorage.defaultDirectoryName) {
        self.directoryName = directoryName
        // Init runs before any concurrent access — call internals directly.
        _createStorageDirectoryIfNeeded()
        _cleanupExpiredBatches()
    }

    // MARK: - Public Methods (queue-serialized wrappers)

    /// Returns the number of stored batches
    var batchCount: Int {
        storageQueue.sync { _batchCount() }
    }

    /// Saves a batch of beacons to persistent storage
    @discardableResult
    func saveBatch(_ beacons: [Beacon]) -> Bool {
        storageQueue.sync { _save(beacons) != nil }
    }

    /// Saves a batch and returns its persistent identifier (the on-disk filename), so the
    /// caller can remove exactly this batch later (used by persist-before-send: persist
    /// before the upload starts, remove THIS batch on success, leave it on failure).
    func saveBatchReturningId(_ beacons: [Beacon]) -> String? {
        storageQueue.sync { _save(beacons) }
    }

    /// Removes a specific batch by its identifier (filename). Call after the batch was
    /// successfully delivered so it is not re-sent on the next drain.
    @discardableResult
    func removeBatch(id: String) -> Bool {
        storageQueue.sync { _removeBatch(id: id) }
    }

    /// Removes several batches by id. Returns how many were actually removed.
    @discardableResult
    func removeBatches(ids: [String]) -> Int {
        storageQueue.sync { ids.reduce(0) { $0 + (_removeBatch(id: $1) ? 1 : 0) } }
    }

    /// Loads the oldest batch from storage (FIFO)
    func loadOldestBatch() -> [Beacon]? {
        storageQueue.sync { _loadOldestRecords(1).first?.beacons }
    }

    /// Loads the N oldest batches from storage (FIFO)
    func loadOldestBatches(_ count: Int) -> [[Beacon]] {
        storageQueue.sync { _loadOldestRecords(count).map { $0.beacons } }
    }

    /// Loads the N oldest batches WITH their on-disk ids — the id-addressed pair
    /// of `loadOldestBatches`/`removeOldestBatches` for exact removal.
    func loadOldestBatchesWithIds(_ count: Int) -> [StoredBatchRecord] {
        storageQueue.sync { _loadOldestRecords(count) }
    }

    /// Removes the oldest batch from storage. Legacy positional API — prefer
    /// `removeBatches(ids:)` with the ids returned by `loadOldestBatchesWithIds`.
    @discardableResult
    func removeOldestBatch() -> Bool {
        storageQueue.sync { _removeOldest(1) == 1 }
    }

    /// Removes the N oldest batches. Legacy positional API — see `removeOldestBatch`.
    @discardableResult
    func removeOldestBatches(_ count: Int) -> Int {
        storageQueue.sync { _removeOldest(count) }
    }

    /// Loads all batches from storage (for migration or debugging)
    func loadAllBatches() -> [[Beacon]] {
        storageQueue.sync { _loadOldestRecords(Int.max).map { $0.beacons } }
    }

    /// Clears all stored batches
    func clearAllBatches() {
        storageQueue.sync { _clearAll() }
    }

    // MARK: - Internals (must already be on storageQueue)

    private func _batchCount() -> Int {
        guard let directory = storageDirectory,
              let files = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return 0
        }
        return files.filter { $0.hasSuffix(".json") }.count
    }

    private func _save(_ beacons: [Beacon]) -> String? {
        guard let directory = storageDirectory else { return nil }
        guard !beacons.isEmpty else { return nil }

        let batchId = UUID().uuidString
        let timestamp = Date()

        let storedBeacons = beacons.map { StoredBeacon(from: $0) }
        let batch = StoredBatch(id: batchId, timestamp: timestamp, beacons: storedBeacons)

        // Filename format: timestamp_uuid.json for sorting
        let timestampInt = Int(timestamp.timeIntervalSince1970)
        let filename = "\(timestampInt)_\(batchId).json"
        let fileURL = directory.appendingPathComponent(filename)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(batch)
            try data.write(to: fileURL, options: .atomic)
            NSLog("[BeAroundSDK] Persisted batch with %d beacons to %@", beacons.count, filename)

            _enforceMaxBatchCount()
            return filename
        } catch {
            NSLog("[BeAroundSDK] Failed to persist batch: %@", error.localizedDescription)
            return nil
        }
    }

    private func _removeBatch(id: String) -> Bool {
        guard let directory = storageDirectory else { return false }
        guard !id.isEmpty else { return false }

        let fileURL = directory.appendingPathComponent(id)
        guard fileManager.fileExists(atPath: fileURL.path) else { return false }

        do {
            try fileManager.removeItem(at: fileURL)
            NSLog("[BeAroundSDK] Removed delivered batch %@", id)
            return true
        } catch {
            NSLog("[BeAroundSDK] Failed to remove batch %@: %@", id, error.localizedDescription)
            return false
        }
    }

    private func _loadOldestRecords(_ count: Int) -> [StoredBatchRecord] {
        guard let directory = storageDirectory else { return [] }

        guard let files = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }

        let jsonFiles = files.filter { $0.hasSuffix(".json") }.sorted()
        var records: [StoredBatchRecord] = []

        for filename in jsonFiles.prefix(count) {
            let fileURL = directory.appendingPathComponent(filename)

            do {
                let data = try Data(contentsOf: fileURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let batch = try decoder.decode(StoredBatch.self, from: data)

                // Quarantine corruption instead of masking it (see StoredBeacon.toBeacon):
                // drop unparseable beacons; a batch left with none is deleted outright.
                let beacons = batch.beacons.compactMap { $0.toBeacon() }
                let dropped = batch.beacons.count - beacons.count
                if dropped > 0 {
                    NSLog("[BeAroundSDK] Dropped %d corrupted beacon(s) from batch %@", dropped, filename)
                    DiagnosticsStore.shared.recordError("Corrupted beacon(s) dropped from stored batch \(filename)")
                }
                guard !beacons.isEmpty else {
                    try? fileManager.removeItem(at: fileURL)
                    continue
                }
                records.append(StoredBatchRecord(id: filename, beacons: beacons))
            } catch {
                NSLog("[BeAroundSDK] Failed to load batch %@: %@", filename, error.localizedDescription)
                try? fileManager.removeItem(at: fileURL)
            }
        }

        return records
    }

    private func _removeOldest(_ count: Int) -> Int {
        guard let directory = storageDirectory else { return 0 }

        guard let files = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return 0
        }

        let jsonFiles = files.filter { $0.hasSuffix(".json") }.sorted()
        var removedCount = 0

        for filename in jsonFiles.prefix(count) {
            let fileURL = directory.appendingPathComponent(filename)
            do {
                try fileManager.removeItem(at: fileURL)
                removedCount += 1
            } catch {
                NSLog("[BeAroundSDK] Failed to remove batch %@: %@", filename, error.localizedDescription)
            }
        }

        if removedCount > 0 {
            NSLog("[BeAroundSDK] Removed %d oldest batches", removedCount)
        }
        return removedCount
    }

    private func _clearAll() {
        guard let directory = storageDirectory else { return }

        guard let files = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return
        }

        for filename in files where filename.hasSuffix(".json") {
            let fileURL = directory.appendingPathComponent(filename)
            try? fileManager.removeItem(at: fileURL)
        }

        NSLog("[BeAroundSDK] Cleared all stored batches")
    }

    private func _createStorageDirectoryIfNeeded() {
        guard let directory = storageDirectory else { return }

        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                NSLog("[BeAroundSDK] Created batch storage directory")
            } catch {
                NSLog("[BeAroundSDK] Failed to create storage directory: %@", error.localizedDescription)
            }
        }
    }

    private func _cleanupExpiredBatches() {
        guard let directory = storageDirectory else { return }

        guard let files = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return
        }

        let now = Date()
        var removedCount = 0

        for filename in files where filename.hasSuffix(".json") {
            // Extract timestamp from filename (format: timestamp_uuid.json)
            let components = filename.split(separator: "_")
            guard let timestampString = components.first,
                  let timestamp = TimeInterval(timestampString) else {
                continue
            }

            let batchDate = Date(timeIntervalSince1970: timestamp)
            let age = now.timeIntervalSince(batchDate)

            if age > maxBatchAge {
                let fileURL = directory.appendingPathComponent(filename)
                try? fileManager.removeItem(at: fileURL)
                removedCount += 1
            }
        }

        if removedCount > 0 {
            NSLog("[BeAroundSDK] Cleaned up %d expired batches", removedCount)
        }
    }

    private func _enforceMaxBatchCount() {
        guard let directory = storageDirectory else { return }

        guard let files = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return
        }

        var jsonFiles = files.filter { $0.hasSuffix(".json") }.sorted()

        while jsonFiles.count > _maxBatchCount {
            // Remove oldest file (first in sorted list)
            if let oldestFile = jsonFiles.first {
                let fileURL = directory.appendingPathComponent(oldestFile)
                try? fileManager.removeItem(at: fileURL)
                jsonFiles.removeFirst()
                NSLog("[BeAroundSDK] Removed oldest batch due to max count exceeded: %@", oldestFile)
            }
        }
    }
}
