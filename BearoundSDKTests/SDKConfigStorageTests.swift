//
//  SDKConfigStorageTests.swift
//  BearoundSDKTests
//
//  Tests for SDK configuration persistence
//

import Foundation
import Testing

@testable import BearoundSDK

@Suite("SDKConfigStorage Tests")
struct SDKConfigStorageTests {
    
    @Test("Save and load configuration")
    func saveAndLoadConfiguration() {
        // Create test configuration
        let config = SDKConfiguration(
            businessToken: "test-token-123",
            foregroundScanInterval: .seconds30,
            backgroundScanInterval: .seconds90,
            maxQueuedPayloads: .large
        )
        
        // Save configuration
        SDKConfigStorage.save(config)
        
        // Load configuration
        let loadedConfig = SDKConfigStorage.load()
        
        #expect(loadedConfig != nil)
        #expect(loadedConfig?.businessToken == "test-token-123")
        #expect(loadedConfig?.foregroundScanInterval.timeInterval == 30)
        #expect(loadedConfig?.backgroundScanInterval.timeInterval == 90)
        #expect(loadedConfig?.maxQueuedPayloads.value == 200)
    }
    
    @Test("Load returns nil when no config saved")
    func loadWithoutSaving() {
        // Clear any existing config
        SDKConfigStorage.clear()
        
        // Try to load
        let config = SDKConfigStorage.load()
        
        #expect(config == nil)
    }
    
    @Test("Clear configuration")
    func clearConfiguration() {
        // Save a config
        let config = SDKConfiguration(
            businessToken: "test-token",
            foregroundScanInterval: .seconds15,
            backgroundScanInterval: .seconds60
        )
        SDKConfigStorage.save(config)
        
        // Verify it was saved
        #expect(SDKConfigStorage.load() != nil)
        
        // Clear it
        SDKConfigStorage.clear()
        
        // Verify it was cleared
        #expect(SDKConfigStorage.load() == nil)
    }
    
    @Test("Save and load scanning state")
    func saveAndLoadScanningState() {
        // Save scanning state as true
        SDKConfigStorage.saveScanningState(true)
        #expect(SDKConfigStorage.loadScanningState() == true)
        
        // Save scanning state as false
        SDKConfigStorage.saveScanningState(false)
        #expect(SDKConfigStorage.loadScanningState() == false)
    }
    
    @Test("Default scanning state is false")
    func defaultScanningState() {
        // Clear any existing state
        SDKConfigStorage.clearScanningState()
        
        // Load should return false by default
        #expect(SDKConfigStorage.loadScanningState() == false)
    }
    
    @Test("Persist all enum values")
    func persistAllEnumValues() {
        // Test all foreground interval values
        let foregroundIntervals: [ForegroundScanInterval] = [
            .seconds5, .seconds10, .seconds15, .seconds20,
            .seconds25, .seconds30, .seconds35, .seconds40,
            .seconds45, .seconds50, .seconds55, .seconds60
        ]
        
        for interval in foregroundIntervals {
            let config = SDKConfiguration(
                businessToken: "test",
                foregroundScanInterval: interval,
                backgroundScanInterval: .seconds60
            )
            SDKConfigStorage.save(config)
            let loaded = SDKConfigStorage.load()
            #expect(loaded?.foregroundScanInterval == interval)
        }
        
        // Test all background interval values
        let backgroundIntervals: [BackgroundScanInterval] = [
            .seconds15, .seconds30, .seconds45,
            .seconds60, .seconds90, .seconds120
        ]
        
        for interval in backgroundIntervals {
            let config = SDKConfiguration(
                businessToken: "test",
                foregroundScanInterval: .seconds15,
                backgroundScanInterval: interval
            )
            SDKConfigStorage.save(config)
            let loaded = SDKConfigStorage.load()
            #expect(loaded?.backgroundScanInterval == interval)
        }
        
        // Test all queue size values
        let queueSizes: [MaxQueuedPayloads] = [
            .small, .medium, .large, .xlarge
        ]
        
        for queueSize in queueSizes {
            let config = SDKConfiguration(
                businessToken: "test",
                foregroundScanInterval: .seconds15,
                backgroundScanInterval: .seconds60,
                maxQueuedPayloads: queueSize
            )
            SDKConfigStorage.save(config)
            let loaded = SDKConfigStorage.load()
            #expect(loaded?.maxQueuedPayloads == queueSize)
        }
    }
}
