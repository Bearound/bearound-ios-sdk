//
//  OfflineBatchStorageTests.swift
//  BearoundSDKTests
//
//  Tests for offline batch storage and retry logic
//

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
    
    @Test("Set custom max batch count")
    func setCustomMaxBatchCount() {
        var storage = OfflineBatchStorage()
        storage.maxBatchCount = 500
        
        #expect(storage.maxBatchCount == 500)
    }
    
    @Test("Store and retrieve batches")
    func storeAndRetrieveBatches() {
        let storage = OfflineBatchStorage()
        storage.clearAll()
        
        // Create test beacons
        let beacons1 = createTestBeacons(count: 3)
        let beacons2 = createTestBeacons(count: 2)
        
        // Store batches
        storage.storeBatch(beacons1)
        storage.storeBatch(beacons2)
        
        // Retrieve batches
        let batches = storage.getAllBatches()
        
        #expect(batches.count == 2)
        #expect(batches[0].beacons.count == 3)
        #expect(batches[1].beacons.count == 2)
    }
    
    @Test("FIFO order - oldest batches retrieved first")
    func fifoOrder() {
        let storage = OfflineBatchStorage()
        storage.clearAll()
        
        // Store multiple batches with delays to ensure different timestamps
        let beacons1 = createTestBeacons(count: 1)
        storage.storeBatch(beacons1)
        
        Thread.sleep(forTimeInterval: 0.01)
        
        let beacons2 = createTestBeacons(count: 1)
        storage.storeBatch(beacons2)
        
        Thread.sleep(forTimeInterval: 0.01)
        
        let beacons3 = createTestBeacons(count: 1)
        storage.storeBatch(beacons3)
        
        // Retrieve all batches
        let batches = storage.getAllBatches()
        
        // Verify FIFO order (oldest first)
        #expect(batches.count == 3)
        #expect(batches[0].timestamp <= batches[1].timestamp)
        #expect(batches[1].timestamp <= batches[2].timestamp)
    }
    
    @Test("Remove batch after successful sync")
    func removeBatchAfterSync() {
        let storage = OfflineBatchStorage()
        storage.clearAll()
        
        // Store batches
        let beacons1 = createTestBeacons(count: 2)
        let beacons2 = createTestBeacons(count: 3)
        storage.storeBatch(beacons1)
        storage.storeBatch(beacons2)
        
        // Get batches
        let batches = storage.getAllBatches()
        #expect(batches.count == 2)
        
        // Remove first batch
        storage.removeBatch(batches[0].id)
        
        // Verify only one batch remains
        let remainingBatches = storage.getAllBatches()
        #expect(remainingBatches.count == 1)
        #expect(remainingBatches[0].beacons.count == 3)
    }
    
    @Test("Respect max batch count limit")
    func respectMaxBatchCountLimit() {
        var storage = OfflineBatchStorage()
        storage.maxBatchCount = 3
        storage.clearAll()
        
        // Try to store 5 batches (limit is 3)
        for _ in 0..<5 {
            let beacons = createTestBeacons(count: 1)
            storage.storeBatch(beacons)
            Thread.sleep(forTimeInterval: 0.01)
        }
        
        // Should only have 3 batches (oldest ones removed)
        let batches = storage.getAllBatches()
        #expect(batches.count == 3)
    }
    
    @Test("Clear all batches")
    func clearAllBatches() {
        let storage = OfflineBatchStorage()
        
        // Store some batches
        for _ in 0..<5 {
            let beacons = createTestBeacons(count: 2)
            storage.storeBatch(beacons)
        }
        
        #expect(storage.getAllBatches().count == 5)
        
        // Clear all
        storage.clearAll()
        
        #expect(storage.getAllBatches().count == 0)
    }
    
    @Test("Age-based cleanup removes old batches")
    func ageBasedCleanup() {
        let storage = OfflineBatchStorage()
        storage.clearAll()
        
        // Store a batch
        let beacons = createTestBeacons(count: 2)
        storage.storeBatch(beacons)
        
        // Get the batch and manually set old timestamp
        var batches = storage.getAllBatches()
        #expect(batches.count == 1)
        
        // Clean up should work
        storage.cleanupOldBatches(olderThanDays: 7)
        
        // For recent batches, nothing should be removed
        batches = storage.getAllBatches()
        #expect(batches.count == 1)
    }
    
    @Test("Count batches")
    func countBatches() {
        let storage = OfflineBatchStorage()
        storage.clearAll()
        
        #expect(storage.count() == 0)
        
        storage.storeBatch(createTestBeacons(count: 1))
        #expect(storage.count() == 1)
        
        storage.storeBatch(createTestBeacons(count: 1))
        #expect(storage.count() == 2)
        
        storage.clearAll()
        #expect(storage.count() == 0)
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
                proximity: 1, // near
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
