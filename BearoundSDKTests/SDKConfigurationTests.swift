////
////  SDKConfigurationTests.swift
////  BearoundSDKTests
////
////  Tests for SDKConfiguration model
////
//
//import Testing
//import Foundation
//@testable import BearoundSDK
//
//@Suite("SDKConfiguration Tests")
//struct SDKConfigurationTests {
//
//    @Test("SDKConfiguration basic initialization")
//    func configurationInitialization() {
//        let config = SDKConfiguration(
//            businessToken: "test-business-token-abc123",
//            syncInterval: 30,
//            enableBluetoothScanning: true,
//            enablePeriodicScanning: false
//        )
//
//        #expect(config.businessToken == "test-business-token-abc123")
//        #expect(config.syncInterval == 30)
//        #expect(config.enableBluetoothScanning == true)
//        #expect(config.enablePeriodicScanning == false)
//        #expect(config.apiBaseURL == "https://ingest.bearound.io")
//        // appId agora é obtido dinamicamente do Bundle.main.bundleIdentifier
//        #expect(config.appId != "")
//    }
//
//    @Test("SDKConfiguration default values")
//    func configurationDefaults() {
//        let config = SDKConfiguration(
//            businessToken: "business-token-123",
//            syncInterval: 15
//        )
//
//        #expect(config.enableBluetoothScanning == false)
//        #expect(config.enablePeriodicScanning == true)
//    }
//
//    @Test("SDKConfiguration sync interval clamping - minimum")
//    func syncIntervalMinimumClamping() {
//        let config = SDKConfiguration(
//            businessToken: "business-token-123",
//            syncInterval: 2 // Below minimum
//        )
//
//        #expect(config.syncInterval == 5) // Should be clamped to 5
//    }
//
//    @Test("SDKConfiguration sync interval clamping - maximum")
//    func syncIntervalMaximumClamping() {
//        let config = SDKConfiguration(
//            businessToken: "business-token-123",
//            syncInterval: 100 // Above maximum
//        )
//
//        #expect(config.syncInterval == 60) // Should be clamped to 60
//    }
//
//    @Test("SDKConfiguration sync interval valid range")
//    func syncIntervalValidRange() {
//        let validIntervals: [TimeInterval] = [5, 10, 20, 30, 45, 60]
//
//        for interval in validIntervals {
//            let config = SDKConfiguration(
//                businessToken: "business-token-123",
//                syncInterval: interval
//            )
//            #expect(config.syncInterval == interval)
//        }
//    }
//
//    @Test("SDKConfiguration scan duration calculation")
//    func scanDurationCalculation() {
//        // Scan duration should be syncInterval / 3, clamped between 5-10 seconds
//
//        let config15 = SDKConfiguration(businessToken: "biz-token", syncInterval: 15)
//        #expect(config15.scanDuration == 5) // 15/3 = 5
//
//        let config30 = SDKConfiguration(businessToken: "biz-token", syncInterval: 30)
//        #expect(config30.scanDuration == 10) // 30/3 = 10
//
//        let config60 = SDKConfiguration(businessToken: "biz-token", syncInterval: 60)
//        #expect(config60.scanDuration == 10) // 60/3 = 20, but clamped to 10
//
//        let config5 = SDKConfiguration(businessToken: "biz-token", syncInterval: 5)
//        #expect(config5.scanDuration == 5) // 5/3 = 1.67, but clamped to 5
//    }
//
//    @Test("SDKConfiguration mutability of scanning flags")
//    func configurationMutability() {
//        var config = SDKConfiguration(
//            businessToken: "business-token-123",
//            syncInterval: 20,
//            enableBluetoothScanning: false,
//            enablePeriodicScanning: true
//        )
//
//        #expect(config.enableBluetoothScanning == false)
//        #expect(config.enablePeriodicScanning == true)
//
//        config.enableBluetoothScanning = true
//        config.enablePeriodicScanning = false
//
//        #expect(config.enableBluetoothScanning == true)
//        #expect(config.enablePeriodicScanning == false)
//    }
//
//    @Test("SDKConfiguration extracts Bundle ID automatically")
//    func configurationBundleId() {
//        let config = SDKConfiguration(
//            businessToken: "business-token-123",
//            syncInterval: 15
//        )
//
//        // Bundle ID should be extracted from Bundle.main.bundleIdentifier
//        // In tests, this might be "unknown" or the test bundle ID
//        #expect(config.appId.isEmpty == false)
//    }
//}
//
