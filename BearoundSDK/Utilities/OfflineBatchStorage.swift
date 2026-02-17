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
class OfflineBatchStorage {

    // MARK: - Configuration

    /// Maximum age for stored batches (7 days)
    private let maxBatchAge: TimeInterval = 7 * 24 * 60 * 60

    /// Directory name for batch storage
    private static let directoryName = "com.bearound.sdk.batches"

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

        func toBeacon() -> Beacon {
            let beaconUUID = UUID(uuidString: uuid) ?? UUID()
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

    // MARK: - Properties

    private let fileManager = FileManager.default
    private let storageQueue = DispatchQueue(label: "com.bearound.sdk.batchStorage", qos: .utility)

    /// Maximum number of batches to store (default from MaxQueuedPayloads.medium)
    var maxBatchCount: Int = MaxQueuedPayloads.medium.value

    /// Storage directory URL
    private var storageDirectory: URL? {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            NSLog("[BeAroundSDK] Failed to get Application Support directory")
            return nil
        }
        return appSupport.appendingPathComponent(Self.directoryName)
    }

    // MARK: - Initialization

    init() {
        createStorageDirectoryIfNeeded()
        cleanupExpiredBatches()
    }

    // MARK: - Public Methods

    /// Returns the number of stored batches
    var batchCount: Int {
        guard let directory = storageDirectory,
              let files = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return 0
        }
        return files.filter { $0.hasSuffix(".json") }.count
    }

    /// Saves a batch of beacons to persistent storage
    /// - Parameter beacons: Array of beacons to store
    /// - Returns: true if saved successfully
    @discardableResult
    func saveBatch(_ beacons: [Beacon]) -> Bool {
        guard let directory = storageDirectory else { return false }
        guard !beacons.isEmpty else { return false }

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
            NSLog("[BeAroundSDK] Saved batch with %d beacons to %@", beacons.count, filename)

            // Enforce max batch count (remove oldest if exceeded)
            enforceMaxBatchCount()

            return true
        } catch {
            NSLog("[BeAroundSDK] Failed to save batch: %@", error.localizedDescription)
            return false
        }
    }

    /// Loads the oldest batch from storage (FIFO)
    /// - Returns: Array of beacons or nil if no batches available
    func loadOldestBatch() -> [Beacon]? {
        guard let directory = storageDirectory else { return nil }

        guard let files = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }

        // Filter JSON files and sort by name (timestamp prefix ensures oldest first)
        let jsonFiles = files.filter { $0.hasSuffix(".json") }.sorted()

        guard let oldestFile = jsonFiles.first else {
            return nil
        }

        let fileURL = directory.appendingPathComponent(oldestFile)

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let batch = try decoder.decode(StoredBatch.self, from: data)

            let beacons = batch.beacons.map { $0.toBeacon() }
            NSLog("[BeAroundSDK] Loaded oldest batch with %d beacons from %@", beacons.count, oldestFile)
            return beacons
        } catch {
            NSLog("[BeAroundSDK] Failed to load batch %@: %@", oldestFile, error.localizedDescription)
            // Remove corrupted file
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
    }

    /// Removes the oldest batch from storage (call after successful sync)
    /// - Returns: true if removed successfully
    @discardableResult
    func removeOldestBatch() -> Bool {
        guard let directory = storageDirectory else { return false }

        guard let files = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return false
        }

        let jsonFiles = files.filter { $0.hasSuffix(".json") }.sorted()

        guard let oldestFile = jsonFiles.first else {
            return false
        }

        let fileURL = directory.appendingPathComponent(oldestFile)

        do {
            try fileManager.removeItem(at: fileURL)
            NSLog("[BeAroundSDK] Removed batch file: %@", oldestFile)
            return true
        } catch {
            NSLog("[BeAroundSDK] Failed to remove batch %@: %@", oldestFile, error.localizedDescription)
            return false
        }
    }

    /// Loads all batches from storage (for migration or debugging)
    /// - Returns: Array of beacon arrays, ordered oldest first
    func loadAllBatches() -> [[Beacon]] {
        guard let directory = storageDirectory else { return [] }

        guard let files = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }

        let jsonFiles = files.filter { $0.hasSuffix(".json") }.sorted()
        var allBatches: [[Beacon]] = []

        for filename in jsonFiles {
            let fileURL = directory.appendingPathComponent(filename)

            do {
                let data = try Data(contentsOf: fileURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let batch = try decoder.decode(StoredBatch.self, from: data)
                let beacons = batch.beacons.map { $0.toBeacon() }
                allBatches.append(beacons)
            } catch {
                NSLog("[BeAroundSDK] Failed to load batch %@: %@", filename, error.localizedDescription)
                // Remove corrupted file
                try? fileManager.removeItem(at: fileURL)
            }
        }

        NSLog("[BeAroundSDK] Loaded %d batches from storage", allBatches.count)
        return allBatches
    }

    /// Clears all stored batches
    func clearAllBatches() {
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

    // MARK: - Private Methods

    private func createStorageDirectoryIfNeeded() {
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

    private func cleanupExpiredBatches() {
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

    private func enforceMaxBatchCount() {
        guard let directory = storageDirectory else { return }

        guard let files = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return
        }

        var jsonFiles = files.filter { $0.hasSuffix(".json") }.sorted()

        while jsonFiles.count > maxBatchCount {
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
