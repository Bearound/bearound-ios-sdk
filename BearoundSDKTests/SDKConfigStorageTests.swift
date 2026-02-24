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
            scanPrecision: .medium,
            maxQueuedPayloads: .large
        )

        // Save configuration
        SDKConfigStorage.save(config)

        // Load configuration
        let loadedConfig = SDKConfigStorage.load()

        #expect(loadedConfig != nil)
        #expect(loadedConfig?.businessToken == "test-token-123")
        #expect(loadedConfig?.scanPrecision == .medium)
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
            scanPrecision: .high
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
        SDKConfigStorage.saveIsScanning(true)
        #expect(SDKConfigStorage.loadIsScanning() == true)

        // Save scanning state as false
        SDKConfigStorage.saveIsScanning(false)
        #expect(SDKConfigStorage.loadIsScanning() == false)
    }

    @Test("Default scanning state is false")
    func defaultScanningState() {
        // Clear config (which clears scanning state too)
        SDKConfigStorage.clear()

        // Load should return false by default
        #expect(SDKConfigStorage.loadIsScanning() == false)
    }

    @Test("Persist all precision values")
    func persistAllPrecisionValues() {
        // Test all scan precision values
        for precision in ScanPrecision.allCases {
            let config = SDKConfiguration(
                businessToken: "test",
                scanPrecision: precision
            )
            SDKConfigStorage.save(config)
            let loaded = SDKConfigStorage.load()
            #expect(loaded?.scanPrecision == precision)
        }

        // Test all queue size values
        let queueSizes: [MaxQueuedPayloads] = [
            .small, .medium, .large, .xlarge
        ]

        for queueSize in queueSizes {
            let config = SDKConfiguration(
                businessToken: "test",
                maxQueuedPayloads: queueSize
            )
            SDKConfigStorage.save(config)
            let loaded = SDKConfigStorage.load()
            #expect(loaded?.maxQueuedPayloads == queueSize)
        }
    }
}
