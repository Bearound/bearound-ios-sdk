//
//  SDKConfigStorageTests.swift
//  BearoundSDKTests
//
//  Tests for SDK configuration persistence
//

import Foundation
import Testing

@testable import BearoundSDK

// .serialized: every test here reads/writes the SAME UserDefaults suite
// ("com.bearound.sdk.config") — parallel execution makes them clobber each other.
@Suite("SDKConfigStorage Tests", .serialized)
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

    @Test("Persist and restore technology")
    func persistTechnology() {
        let config = SDKConfiguration(
            businessToken: "test-token-tech",
            technology: "react-native"
        )
        SDKConfigStorage.save(config)

        // Survives relaunch (restore path used by background auto-configure)
        #expect(SDKConfigStorage.load()?.technology == "react-native")
    }

    @Test("Technology defaults to ios-native")
    func technologyDefault() {
        let config = SDKConfiguration(businessToken: "test-token-default")
        #expect(config.technology == "ios-native")
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

    @Test("Persist and restore periodic reconciliation fields")
    func persistPeriodicReconciliation() {
        let config = SDKConfiguration(
            businessToken: "test-periodic",
            periodicReconciliationEnabled: false,
            periodicReconciliationInterval: 10 * 60,
            periodicScanDuration: 8
        )
        SDKConfigStorage.save(config)

        let loaded = SDKConfigStorage.load()
        #expect(loaded?.periodicReconciliationEnabled == false)
        #expect(loaded?.periodicReconciliationInterval == 600.0)
        #expect(loaded?.periodicScanDuration == 8.0)
    }

    @Test("Legacy stored config without periodic fields restores the defaults")
    func legacyConfigRestoresPeriodicDefaults() {
        // Persist a current config, then strip the new keys to simulate a config
        // written by an SDK version that predates the feature.
        SDKConfigStorage.save(SDKConfiguration(businessToken: "legacy-token"))
        let defaults = UserDefaults(suiteName: "com.bearound.sdk.config")
        defaults?.removeObject(forKey: "periodic_reconciliation_enabled")
        defaults?.removeObject(forKey: "periodic_reconciliation_interval")
        defaults?.removeObject(forKey: "periodic_scan_duration")

        let loaded = SDKConfigStorage.load()
        #expect(loaded?.periodicReconciliationEnabled == true)
        #expect(loaded?.periodicReconciliationInterval == PeriodicReconciliationDefaults.interval)
        #expect(loaded?.periodicScanDuration == PeriodicReconciliationDefaults.scanDuration)
    }
}
