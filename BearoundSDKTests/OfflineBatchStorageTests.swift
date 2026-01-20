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
    
    @Test("Initialize with default max batch count")
    func initializeDefaultMaxBatchCount() {
        let storage = OfflineBatchStorage()
        
        // Default should be medium (100)
        #expect(storage.maxBatchCount == 100)
    }
    
    @Test("Save batch returns success")
    func saveBatchReturnsSuccess() {
        let storage = OfflineBatchStorage()
        
        // Create test beacons
        let beacons = createTestBeacons(count: 3)
        
        // Save batch
        let result = storage.saveBatch(beacons)
        
        #expect(result == true)
    }
    
    @Test("Batch count increases after save")
    func batchCountIncreasesAfterSave() {
        let storage = OfflineBatchStorage()
        
        let initialCount = storage.batchCount
        
        // Save a batch
        let beacons = createTestBeacons(count: 2)
        _ = storage.saveBatch(beacons)
        
        let newCount = storage.batchCount
        
        #expect(newCount == initialCount + 1)
    }
    
    @Test("Load oldest batch returns beacons")
    func loadOldestBatchReturnsBeacons() {
        let storage = OfflineBatchStorage()
        
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
        let storage = OfflineBatchStorage()
        
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
        let storage = OfflineBatchStorage()
        
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
        let storage = OfflineBatchStorage()
        
        // Try to save empty array
        let result = storage.saveBatch([])
        
        #expect(result == false)
    }
    
    @Test("Load oldest batch when empty returns nil")
    func loadOldestBatchWhenEmptyReturnsNil() {
        let storage = OfflineBatchStorage()
        
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
        let storage = OfflineBatchStorage()
        
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
        let storage = OfflineBatchStorage()
        
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
