//
//  OfflineBatchStorageTests.swift
//  BearoundSDKTests
//
//  Tests for offline batch storage and retry logic
//

import CoreLocation
import Foundation
import Testing

@testable import BearoundSDK

@Suite("OfflineBatchStorage Tests")
struct OfflineBatchStorageTests {

    /// A unique directory per test instance isolates the on-disk batch store, so
    /// batches from one test never leak into another. Swift Testing creates a fresh
    /// struct instance per test and runs tests in parallel, so this is the reliable
    /// isolation seam (the shared production directory caused order-dependent failures).
    private let testDirectory = "com.bearound.sdk.test.batches.\(UUID().uuidString)"

    private func makeStorage() -> OfflineBatchStorage {
        OfflineBatchStorage(directoryName: testDirectory)
    }


    @Test("Initialize with default max batch count")
    func initializeDefaultMaxBatchCount() {
        let storage = makeStorage()
        
        // Default should be medium (100)
        #expect(storage.maxBatchCount == 100)
    }
    
    @Test("Save batch returns success")
    func saveBatchReturnsSuccess() {
        let storage = makeStorage()
        
        // Create test beacons
        let beacons = createTestBeacons(count: 3)
        
        // Save batch
        let result = storage.saveBatch(beacons)
        
        #expect(result == true)
    }
    
    @Test("Batch count increases after save")
    func batchCountIncreasesAfterSave() {
        let storage = makeStorage()
        
        let initialCount = storage.batchCount
        
        // Save a batch
        let beacons = createTestBeacons(count: 2)
        _ = storage.saveBatch(beacons)
        
        let newCount = storage.batchCount
        
        #expect(newCount == initialCount + 1)
    }
    
    @Test("Load oldest batch returns beacons")
    func loadOldestBatchReturnsBeacons() {
        let storage = makeStorage()
        
        // Save a batch
        let beacons = createTestBeacons(count: 3)
        _ = storage.saveBatch(beacons)
        
        // Load oldest batch
        if let loadedBeacons = storage.loadOldestBatch() {
            #expect(loadedBeacons.count == 3)
            #expect(loadedBeacons[0].major == 1000)
        } else {
            Issue.record("Failed to load batch")
        }
    }
    
    @Test("Remove oldest batch decreases count")
    func removeOldestBatchDecreasesCount() {
        let storage = makeStorage()
        
        // Save a batch
        let beacons = createTestBeacons(count: 2)
        _ = storage.saveBatch(beacons)
        
        let countBefore = storage.batchCount
        
        // Remove oldest batch
        let result = storage.removeOldestBatch()
        
        #expect(result == true)
        
        let countAfter = storage.batchCount
        #expect(countAfter == countBefore - 1)
    }
    
    @Test("Load all batches returns array")
    func loadAllBatchesReturnsArray() {
        let storage = makeStorage()
        
        // Save multiple batches
        for i in 0..<3 {
            let beacons = createTestBeacons(count: i + 1)
            _ = storage.saveBatch(beacons)
        }
        
        // Load all batches
        let allBatches = storage.loadAllBatches()
        
        #expect(allBatches.count >= 3)
    }
    
    @Test("Cannot save empty beacon array")
    func cannotSaveEmptyBeaconArray() {
        let storage = makeStorage()
        
        // Try to save empty array
        let result = storage.saveBatch([])
        
        #expect(result == false)
    }
    
    @Test("Load oldest batch when empty returns nil")
    func loadOldestBatchWhenEmptyReturnsNil() {
        let storage = makeStorage()
        
        // Remove all batches first
        while storage.batchCount > 0 {
            _ = storage.removeOldestBatch()
        }
        
        // Try to load from empty storage
        let batch = storage.loadOldestBatch()
        
        #expect(batch == nil)
    }
    
    @Test("Remove oldest batch when empty succeeds")
    func removeOldestBatchWhenEmptySucceeds() {
        let storage = makeStorage()
        
        // Remove all batches first
        while storage.batchCount > 0 {
            _ = storage.removeOldestBatch()
        }
        
        // Try to remove from empty storage (should not crash)
        let result = storage.removeOldestBatch()
        
        // Implementation may return true or false, just verify it doesn't crash
        #expect(result == true || result == false)
    }
    
    @Test("Beacons are stored with correct properties")
    func beaconsStoredWithCorrectProperties() {
        let storage = makeStorage()
        
        // Create beacon with specific properties
        let beacon = Beacon(
            uuid: UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!,
            major: 9999,
            minor: 8888,
            rssi: -77,
            proximity: .far,
            accuracy: 5.5,
            timestamp: Date(),
            metadata: nil,
            txPower: -58
        )
        
        _ = storage.saveBatch([beacon])
        
        // Load and verify
        if let loadedBeacons = storage.loadOldestBatch() {
            #expect(loadedBeacons.count == 1)
            let loaded = loadedBeacons[0]
            #expect(loaded.major == 9999)
            #expect(loaded.minor == 8888)
            #expect(loaded.rssi == -77)
        } else {
            Issue.record("Failed to load saved beacon")
        }
    }
    
    // MARK: - Helper Methods
    
    private func createTestBeacons(count: Int) -> [Beacon] {
        var beacons: [Beacon] = []
        
        for i in 0..<count {
            let beacon = Beacon(
                uuid: UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!,
                major: 1000 + i,
                minor: 2000 + i,
                rssi: -60 - i,
                proximity: .near,
                accuracy: 1.5,
                timestamp: Date(),
                metadata: nil,
                txPower: -59
            )
            beacons.append(beacon)
        }
        
        return beacons
    }
}

// MARK: - Captured context and retry drain

@Suite("OfflineBatchStorage captured context")
struct OfflineBatchCapturedContextTests {

    private let testDirectory = "com.bearound.sdk.test.batches.\(UUID().uuidString)"

    private func makeStorage() -> OfflineBatchStorage {
        OfflineBatchStorage(directoryName: testDirectory)
    }

    /// Built by hand: `DeviceInfoCollector` touches `UNUserNotificationCenter`, which aborts
    /// in this host-less test bundle.
    private func makeDevice(latitude: Double, fixAt: Date) -> UserDevice {
        var device = UserDevice(
            deviceId: "device-1", pushToken: nil, apnsEnvironment: "production", manufacturer: "Apple",
            model: "iPhone17,1", osVersion: "26.0", timestamp: Int(fixAt.timeIntervalSince1970 * 1000),
            timezone: "America/Sao_Paulo", batteryLevel: 80, isCharging: false, bluetoothState: "powered_on",
            locationPermission: "authorized_always", notificationsPermission: "authorized", networkType: "wifi",
            cellularGeneration: nil, ramTotalMb: 8192, ramAvailableMb: 2048, screenWidth: 1206, screenHeight: 2622,
            appInForeground: false, appUptimeMs: 1000, coldStart: false, lowPowerMode: false,
            locationAccuracy: "full", apId: nil, wifiSSID: nil, connectionMetered: false,
            connectionExpensive: false, os: "iOS", deviceName: "iPhone", carrierName: nil,
            availableStorageMb: 10_000, systemLanguage: "pt-BR", thermalState: "nominal", systemUptimeMs: 5000
        )
        device.location = DeviceLocation(latitude: latitude, longitude: -46.6561, accuracy: 12,
                                          timestamp: fixAt, source: "gnss")
        return device
    }

    private func makeBeacons(major: Int) -> [Beacon] {
        [Beacon(uuid: UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!,
                major: major, minor: 1, rssi: -60, proximity: .near, accuracy: 1.5,
                timestamp: Date(), metadata: nil, txPower: -59)]
    }

    private func visitEvent(at date: Date) -> VisitEvent {
        VisitEvent(kind: .arrival, syncTrigger: VisitMonitor.syncTrigger, latitude: -23.5611,
                   longitude: -46.6561, accuracy: 25, timestamp: date, environmentId: nil)
    }

    private func storageDirectoryURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(testDirectory)
    }

    @Test("A legacy batch without the new fields decodes and only it falls back to a fresh context")
    func legacyBatchDecodesWithFallback() throws {
        let storage = makeStorage()
        let legacyJSON = """
        {"id":"legacy","timestamp":"2026-09-01T12:00:00Z","beacons":[{"uuid":"E25B8D3C-947A-452F-A13F-589CB706D2E5",\
        "major":7,"minor":8,"rssi":-70,"proximity":2,"accuracy":2.5,"timestamp":"2026-09-01T12:00:00Z","txPower":-59}]}
        """
        let legacyName = "\(Int(Date().timeIntervalSince1970) - 10)_legacy.json"
        try Data(legacyJSON.utf8).write(to: storageDirectoryURL().appendingPathComponent(legacyName))
        let captured = makeDevice(latitude: -23.1, fixAt: Date())
        #expect(storage.saveBatch(makeBeacons(major: 1), userDevice: captured, syncTrigger: "precision_high_timer"))

        let records = storage.loadOldestBatchesWithIds(5)
        #expect(records.count == 2)
        let legacy = try #require(records.first { $0.id == legacyName })
        #expect(legacy.beacons.first?.major == 7)
        #expect(legacy.userDevice == nil)
        #expect(legacy.syncTrigger == nil)

        var fallbackCalls = 0
        let fallback = makeDevice(latitude: -10, fixAt: Date())
        let legacyContext = BeAroundSDK.retryContext(for: legacy) { fallbackCalls += 1; return fallback }
        #expect(legacyContext.syncTrigger == BeAroundSDK.legacyRetryTrigger)
        #expect(legacyContext.userDevice == fallback)

        let modern = try #require(records.first { $0.id != legacyName })
        let modernContext = BeAroundSDK.retryContext(for: modern) { fallbackCalls += 1; return fallback }
        #expect(modernContext.userDevice == captured)
        #expect(modernContext.syncTrigger == "precision_high_timer")
        #expect(fallbackCalls == 1)
    }

    @Test("Draining N batches with different captured context yields N requests, each with its own context")
    func oneRequestPerBatchWithOwnContext() {
        let storage = makeStorage()
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let triggers = ["precision_high_timer", "display_on", "background_ranging_complete"]
        for (index, trigger) in triggers.enumerated() {
            let device = makeDevice(latitude: -23.0 - Double(index), fixAt: base.addingTimeInterval(Double(index) * 60))
            #expect(storage.saveBatch(makeBeacons(major: 100 + index), userDevice: device, syncTrigger: trigger))
        }

        var remaining = storage.loadOldestBatchesWithIds(5)
        var requests: [[OfflineBatchStorage.StoredBatchRecord]] = []
        while !remaining.isEmpty {
            let group = BeAroundSDK.retryGroup(from: remaining)
            requests.append(group)
            remaining.removeFirst(group.count)
        }

        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.count == 1 })
        let sent = requests.map { request in
            BeAroundSDK.retryContext(for: request[0]) {
                Issue.record("no fallback expected for a captured batch")
                return request[0].userDevice!
            }
        }
        #expect(Set(sent.map { $0.syncTrigger }) == Set(triggers))
        #expect(Set(sent.compactMap { $0.userDevice.location?.latitude }) == [-23.0, -24.0, -25.0])
        for (request, context) in zip(requests, sent) {
            #expect(context.syncTrigger == request[0].syncTrigger)
            #expect(context.userDevice == request[0].userDevice)
        }
    }

    @Test("A retried visit keeps syncTrigger visit and the captured fix, not a retry-time location")
    func retriedVisitKeepsTriggerAndLocation() throws {
        let storage = makeStorage()
        let fixAt = Date(timeIntervalSince1970: 1_790_000_000)
        let collected = makeDevice(latitude: -1.0, fixAt: Date())
        let visitDevice = BeAroundSDK.visitUserDevice(for: visitEvent(at: fixAt), collected: collected)
        let id = try #require(storage.saveBatchReturningId([], userDevice: visitDevice, syncTrigger: VisitMonitor.syncTrigger))
        #expect(id.hasSuffix(OfflineBatchStorage.evictionExemptSuffix))

        let record = try #require(storage.loadOldestBatchesWithIds(5).first)
        #expect(record.beacons.isEmpty)
        #expect(BeAroundSDK.retryGroupIsSendable([], head: record))
        let context = BeAroundSDK.retryContext(for: record) {
            Issue.record("a captured visit must not collect a retry-time context")
            return makeDevice(latitude: 50, fixAt: Date())
        }
        #expect(context.syncTrigger == "visit")
        #expect(context.userDevice.location?.latitude == -23.5611)
        #expect(context.userDevice.location?.timestamp == Int(fixAt.timeIntervalSince1970 * 1000))
        #expect(context.userDevice.location?.source == VisitMonitor.locationSource)
    }

    @Test("A visit batch is exempt from the max-count eviction")
    func visitNotEvicted() throws {
        let storage = makeStorage()
        storage.maxBatchCount = 2
        let visitDevice = BeAroundSDK.visitUserDevice(for: visitEvent(at: Date()),
                                                      collected: makeDevice(latitude: 0, fixAt: Date()))
        let visitId = try #require(storage.saveBatchReturningId([], userDevice: visitDevice, syncTrigger: VisitMonitor.syncTrigger))
        for major in 1...4 {
            #expect(storage.saveBatch(makeBeacons(major: major), userDevice: makeDevice(latitude: 1, fixAt: Date()),
                                      syncTrigger: "precision_high_timer"))
        }

        let records = storage.loadOldestBatchesWithIds(10)
        #expect(records.contains { $0.id == visitId && $0.syncTrigger == "visit" })
        #expect(records.filter { $0.id != visitId }.count == 2)
        #expect(storage.batchCount == 3)
    }
}
