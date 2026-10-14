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
    private let now: () -> Date
    private var lastFileOrder: Int64 = 0

    // MARK: - Codable Types for JSON Serialization

    private struct StoredBatch: Codable {
        let id: String
        let timestamp: Date
        let beacons: [StoredBeacon]
        var tenantFingerprint: String? = nil
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

    struct ObservationRecord {
        let storageId: String
        let envelope: StoredObservationEnvelope
    }

    struct ReplayRecord {
        let storageId: String
        let envelope: StoredObservationEnvelope
        let manifest: SamplingReplayManifest
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
        set { storageQueue.sync { _maxBatchCount = max(1, newValue); _enforceMaxBatchCount() } }
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

    init(directoryName: String = OfflineBatchStorage.defaultDirectoryName, now: @escaping () -> Date = Date.init) {
        self.directoryName = directoryName
        self.now = now
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

    /// Takes a backend-REJECTED batch out of the send queue (renamed to `<id>.rejected` —
    /// kept for diagnosis, swept by the same 7-day expiry). Without this, one poison
    /// batch at the head of the FIFO blocked every batch behind it until expiry.
    @discardableResult
    func quarantineBatch(id: String) -> Bool {
        storageQueue.sync {
            guard let directory = storageDirectory, _validFilename(id) else { return false }
            let source = directory.appendingPathComponent(id)
            guard fileManager.fileExists(atPath: source.path) else { return false }
            do {
                try fileManager.moveItem(at: source, to: directory.appendingPathComponent("\(id).rejected"))
                NSLog("[BeAroundSDK] Quarantined rejected batch %@", id)
                return true
            } catch {
                NSLog("[BeAroundSDK] Failed to quarantine batch %@: %@", id, error.localizedDescription)
                return false
            }
        }
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
        storageQueue.sync {
            // This legacy drain rebuilds context and combines batches. Keep its API but
            // prevent either incomplete legacy records or v2 envelopes entering that path.
            for record in _observationRecords(includeQuarantined: false) {
                if record.envelope.migratedFromVersion == 1 {
                    _ = _quarantineBatch(id: record.storageId, reason: "legacy_context_unavailable")
                }
            }
            return []
        }
    }

    func saveObservation(
        _ envelope: StoredObservationEnvelope, policy: DataCollectionPolicy = .allEnabled
    ) -> String? {
        storageQueue.sync { _saveObservation(envelope.filtered(policy: policy)) }
    }

    func observationRecords(includeQuarantined: Bool = false) -> [ObservationRecord] {
        storageQueue.sync { _observationRecords(includeQuarantined: includeQuarantined) }
    }

    func applyCollectionPolicy(_ policy: DataCollectionPolicy) {
        storageQueue.sync {
            for record in _observationRecords(includeQuarantined: true) {
                let filtered = record.envelope.filtered(policy: policy)
                if filtered != record.envelope { _ = _writeEnvelope(filtered, filename: record.storageId) }
            }
        }
    }

    func loadReplayGroup(
        tenantFingerprint: String, policy: DataCollectionPolicy = .allEnabled,
        capabilityAvailable: Bool, limit: Int = 128, excludingBatchIds: Set<String> = []
    ) -> [ReplayRecord] {
        storageQueue.sync {
            guard SamplingTenantFingerprint.isValid(tenantFingerprint) else { return [] }
            let pending = _observationRecords(includeQuarantined: false)
            var eligible: [ObservationRecord] = []
            for record in pending {
                guard !excludingBatchIds.contains(record.envelope.batchId) else { continue }
                guard record.envelope.tenantFingerprint != nil else {
                    _ = _quarantineBatch(id: record.storageId, reason: "tenant_unverifiable")
                    continue
                }
                guard record.envelope.canReplay else {
                    _ = _quarantineBatch(id: record.storageId, reason: "original_context_unavailable")
                    continue
                }
                guard record.envelope.tenantFingerprint == tenantFingerprint else { continue }
                let filtered = record.envelope.filtered(policy: policy)
                if filtered != record.envelope, !_writeEnvelope(filtered, filename: record.storageId) { continue }
                if capabilityAvailable || filtered.deliveryProtocol == .legacy {
                    eligible.append(ObservationRecord(storageId: record.storageId, envelope: filtered))
                }
            }
            guard limit > 0, !eligible.isEmpty else { return [] }
            var firstIndex = 0
            for (index, record) in eligible.enumerated() where record.envelope.sampling?.kind == .transition {
                let stream = record.envelope.sampling?.captureStreamId
                if !eligible.prefix(index).contains(where: { $0.envelope.sampling?.captureStreamId == stream }) {
                    firstIndex = index
                    break
                }
            }
            let first = eligible[firstIndex].envelope
            if let manifest = first.replayManifest {
                guard manifest.batchIds.count <= 128, manifest.count == manifest.batchIds.count,
                      Set(manifest.batchIds).count == manifest.batchIds.count,
                      manifest.batchIds.contains(first.batchId) else { return [] }
                let existingGroup = manifest.batchIds.compactMap { id in
                    eligible.first { $0.envelope.batchId == id
                        && $0.envelope.tenantFingerprint == first.tenantFingerprint
                        && $0.envelope.deliveryProtocol == first.deliveryProtocol
                        && $0.envelope.sampling?.captureStreamId == first.sampling?.captureStreamId
                        && $0.envelope.contextFingerprint == first.contextFingerprint }
                }
                return _prepareReplayRecords(existingGroup, drainId: manifest.drainId, batchIds: manifest.batchIds)
            }
            var group: [ObservationRecord] = []
            for record in eligible.dropFirst(firstIndex) {
                guard record.envelope.tenantFingerprint == first.tenantFingerprint,
                      record.envelope.deliveryProtocol == first.deliveryProtocol,
                      record.envelope.replayManifest == nil,
                      record.envelope.sampling?.captureStreamId == first.sampling?.captureStreamId,
                      record.envelope.contextFingerprint == first.contextFingerprint else { break }
                group.append(record)
                if group.count == min(128, limit) { break }
            }
            let ids = group.map { $0.envelope.batchId }
            return _prepareReplayRecords(group, drainId: UUID().uuidString, batchIds: ids)
        }
    }

    @discardableResult
    func acknowledge(batchIds: [String], tenantFingerprint: String) -> Int {
        storageQueue.sync {
            let ids = Set(batchIds)
            return _observationRecords(includeQuarantined: false).reduce(0) { removed, record in
                guard record.envelope.tenantFingerprint == tenantFingerprint, ids.contains(record.envelope.batchId) else { return removed }
                return removed + (_removeBatch(id: record.storageId) ? 1 : 0)
            }
        }
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
        let timestamp = now()

        let storedBeacons = beacons.map { StoredBeacon(from: $0) }
        let batch = StoredBatch(id: batchId, timestamp: timestamp, beacons: storedBeacons)

        // Filename format: timestamp_uuid.json for sorting
        let filename = _nextFilename(batchId: batchId)
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
        guard _validFilename(id) else { return false }

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

        guard count > 0 else { return [] }
        let jsonFiles = _sortedFilenames(files.filter { $0.hasSuffix(".json") })
        var records: [StoredBatchRecord] = []

        for filename in jsonFiles.prefix(count) {
            let fileURL = directory.appendingPathComponent(filename)

            do {
                let data = try Data(contentsOf: fileURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if (try? decoder.decode(StoredObservationEnvelope.self, from: data)) != nil { continue }
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
                _ = _quarantineBatch(id: filename, reason: "invalid_storage_format")
            }
        }

        return records
    }

    private func _removeOldest(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        guard let directory = storageDirectory else { return 0 }

        guard let files = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return 0
        }

        let jsonFiles = _sortedFilenames(files.filter { $0.hasSuffix(".json") })
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

        for filename in files where filename.hasSuffix(".json") || filename.hasSuffix(".rejected") {
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

        let currentDate = now()
        var removedCount = 0

        // .json = pending; .rejected = backend-refused quarantine. Both carry the
        // timestamp in the filename and expire on the same 7-day clock.
        for filename in files where filename.hasSuffix(".json") || filename.hasSuffix(".rejected") {
            // Extract timestamp from filename (format: timestamp_uuid.json[.rejected])
            let components = filename.split(separator: "_")
            guard let timestampString = components.first,
                  let timestamp = TimeInterval(timestampString) else {
                continue
            }

            let url = directory.appendingPathComponent(filename)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = try? Data(contentsOf: url)
            let envelope = data.flatMap { try? decoder.decode(StoredObservationEnvelope.self, from: $0) }
            let legacy = data.flatMap { try? decoder.decode(StoredBatch.self, from: $0) }
            let batchDate = envelope.map { Date(timeIntervalSince1970: Double($0.retentionStartMs) / 1_000) }
                ?? legacy?.timestamp ?? Date(timeIntervalSince1970: timestamp > 100_000_000_000 ? timestamp / 1_000 : timestamp)
            let age = currentDate.timeIntervalSince(batchDate)

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

        var jsonFiles = _sortedFilenames(files.filter { $0.hasSuffix(".json") || $0.hasSuffix(".rejected") })

        while jsonFiles.count > _maxBatchCount {
            // Remove oldest file (first in sorted list)
            let decoder = JSONDecoder()
            let unprotected = jsonFiles.first { filename in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(filename)),
                      let envelope = try? decoder.decode(StoredObservationEnvelope.self, from: data) else { return true }
                return envelope.sampling?.kind != .transition
            }
            if let oldestFile = unprotected ?? jsonFiles.first {
                let fileURL = directory.appendingPathComponent(oldestFile)
                try? fileManager.removeItem(at: fileURL)
                jsonFiles.removeAll { $0 == oldestFile }
                NSLog("[BeAroundSDK] Removed oldest batch due to max count exceeded: %@", oldestFile)
                DiagnosticsStore.shared.recordError("Offline observation evicted at queue capacity")
            }
        }
    }

    private func _validFilename(_ id: String) -> Bool {
        !id.isEmpty && (id as NSString).lastPathComponent == id && !id.contains("\\") && id != "." && id != ".."
    }

    private func _sortedFilenames(_ files: [String]) -> [String] {
        func order(_ filename: String) -> Int64 {
            guard let prefix = filename.split(separator: "_").first, let timestamp = Int64(prefix),
                  timestamp > 0 else { return 0 }
            return timestamp > 100_000_000_000 ? timestamp : timestamp * 1_000
        }
        return files.sorted {
            let first = order($0), second = order($1)
            return first == second ? $0 < $1 : first < second
        }
    }

    private func _nextFilename(batchId: String) -> String {
        if let directory = storageDirectory, let files = try? fileManager.contentsOfDirectory(atPath: directory.path) {
            for filename in files {
                if let prefix = filename.split(separator: "_").first, let timestamp = Int64(prefix) {
                    lastFileOrder = max(lastFileOrder, timestamp > 100_000_000_000 ? timestamp : timestamp * 1_000)
                }
            }
        }
        lastFileOrder = max(lastFileOrder + 1, Int64(now().timeIntervalSince1970 * 1_000))
        return "\(lastFileOrder)_\(batchId).json"
    }

    private func _quarantineBatch(id: String, reason: String) -> Bool {
        guard _validFilename(id), let directory = storageDirectory else { return false }
        do {
            try fileManager.moveItem(at: directory.appendingPathComponent(id),
                                     to: directory.appendingPathComponent("\(id).rejected"))
            DiagnosticsStore.shared.recordError("Offline observation quarantined: \(reason)")
            return true
        } catch { return false }
    }

    private func _writeEnvelope(_ envelope: StoredObservationEnvelope, filename: String) -> Bool {
        guard let directory = storageDirectory, _validFilename(filename) else { return false }
        do {
            let data = try JSONEncoder().encode(envelope)
            guard data.count <= 524_288 else { return false }
            try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
            return true
        } catch {
            DiagnosticsStore.shared.recordError("Offline observation atomic write failed")
            return false
        }
    }

    private func _saveObservation(_ envelope: StoredObservationEnvelope) -> String? {
        _cleanupExpiredBatches()
        guard envelope.version == 2, envelope.storedAtMs > 0, UUID(uuidString: envelope.batchId) != nil,
              envelope.retentionStartMs >= Int64(now().timeIntervalSince1970 * 1_000) - 604_800_000,
              envelope.sampling == nil || envelope.sampling?.hasValidIdentityAndWindow == true,
              envelope.sampling == nil || envelope.sampling?.batchId == envelope.batchId,
              let beacons = envelope.originalPayload["beacons"]?.array, beacons.count <= 100,
              !beacons.isEmpty || envelope.originalPayload["location"]?.object != nil
                || !(envelope.originalPayload["wifis"]?.array ?? []).isEmpty
                || !(envelope.originalPayload["encounters"]?.array ?? []).isEmpty,
              beacons.allSatisfy({ ($0.object?["temporalBuckets"]?.array?.count ?? 0) <= 40 }) else { return nil }
        if let existing = _observationRecords(includeQuarantined: true).first(where: { $0.envelope.batchId == envelope.batchId }) {
            var stored = existing.envelope, incoming = envelope
            stored.replayManifest = nil
            incoming.replayManifest = nil
            return stored == incoming ? existing.storageId : nil
        }
        let filename = _nextFilename(batchId: envelope.batchId)
        guard _writeEnvelope(envelope, filename: filename) else { return nil }
        _enforceMaxBatchCount()
        guard let directory = storageDirectory, fileManager.fileExists(atPath: directory.appendingPathComponent(filename).path) else { return nil }
        return filename
    }

    private func _prepareReplayRecords(
        _ group: [ObservationRecord], drainId: String, batchIds: [String]
    ) -> [ReplayRecord] {
        var prepared: [ReplayRecord] = []
        for record in group {
            guard let index = batchIds.firstIndex(of: record.envelope.batchId) else { return [] }
            let manifest = SamplingReplayManifest(drainId: drainId, batchIds: batchIds, index: index, count: batchIds.count)
            var envelope = record.envelope
            if envelope.replayManifest != manifest {
                envelope.replayManifest = manifest
                guard _writeEnvelope(envelope, filename: record.storageId) else { return [] }
            }
            prepared.append(ReplayRecord(storageId: record.storageId, envelope: envelope, manifest: manifest))
        }
        return prepared
    }

    private func _observationRecords(includeQuarantined: Bool) -> [ObservationRecord] {
        _cleanupExpiredBatches()
        guard let directory = storageDirectory,
              let files = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [ObservationRecord] = []
        for filename in _sortedFilenames(files) where filename.hasSuffix(".json") || (includeQuarantined && filename.hasSuffix(".rejected")) {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(filename)), data.count <= 524_288 else {
                _ = _quarantineBatch(id: filename, reason: "invalid_storage_size")
                continue
            }
            if let envelope = try? decoder.decode(StoredObservationEnvelope.self, from: data), envelope.version == 2 {
                records.append(ObservationRecord(storageId: filename, envelope: envelope))
                continue
            }
            guard let legacy = try? decoder.decode(StoredBatch.self, from: data), UUID(uuidString: legacy.id) != nil else {
                if filename.hasSuffix(".json") { _ = _quarantineBatch(id: filename, reason: "invalid_storage_format") }
                continue
            }
            let beacons: [[String: Any]] = legacy.beacons.compactMap { saved in
                guard let beacon = saved.toBeacon() else { return nil }
                let proximity: String
                switch beacon.proximity {
                case .immediate: proximity = "immediate"
                case .near: proximity = "near"
                case .far: proximity = "far"
                case .bt: proximity = "bt"
                case .unknown: proximity = "unknown"
                }
                var value: [String: Any] = ["uuid": beacon.uuid.uuidString, "major": beacon.major, "minor": beacon.minor,
                    "rssi": beacon.rssi, "proximity": proximity, "accuracy": beacon.accuracy,
                    "timestamp": Int64(beacon.timestamp.timeIntervalSince1970 * 1_000)]
                if let txPower = beacon.txPower { value["txPower"] = txPower }
                if let metadata = beacon.metadata {
                    var meta: [String: Any] = ["firmware": metadata.firmwareVersion, "battery": metadata.batteryLevel,
                                             "movements": metadata.movements, "temperature": metadata.temperature]
                    if let txPower = metadata.txPower { meta["txPower"] = txPower }
                    if let rssi = metadata.rssiFromBLE { meta["rssiFromBLE"] = rssi }
                    if let connectable = metadata.isConnectable { meta["isConnectable"] = connectable }
                    value["metadata"] = meta
                }
                return value
            }
            let fingerprint = SamplingTenantFingerprint.isValid(legacy.tenantFingerprint) ? legacy.tenantFingerprint : nil
            if let migrated = try? StoredObservationEnvelope(batchId: legacy.id,
                storedAtMs: Int64(legacy.timestamp.timeIntervalSince1970 * 1_000), tenantFingerprint: fingerprint,
                originalPayload: ["beacons": beacons], sampling: nil, migratedFromVersion: 1),
               _writeEnvelope(migrated, filename: filename) {
                records.append(ObservationRecord(storageId: filename, envelope: migrated))
            }
        }
        return records
    }
}
