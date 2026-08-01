//
//  SDKConfigurationTests.swift
//  BearoundSDKTests
//
//  Tests for SDKConfiguration model
//
import Testing
import Foundation
@testable import BearoundSDK

@Suite("SDKConfiguration Tests")
struct SDKConfigurationTests {

    @Test("SDKConfiguration basic initialization")
    func configurationInitialization() {
        let config = SDKConfiguration(
            businessToken: "test-business-token-abc123",
            scanPrecision: .medium,
            maxQueuedPayloads: .medium
        )

        #expect(config.businessToken == "test-business-token-abc123")
        #expect(config.scanPrecision == .medium)
        #expect(config.maxQueuedPayloads.value == 100)
        #expect(config.apiBaseURL == "https://ingest.bearound.io")
        // appId is now obtained dynamically from Bundle.main.bundleIdentifier
        #expect(config.appId != "")
    }

    @Test("SDKConfiguration default values")
    func configurationDefaults() {
        let config = SDKConfiguration(
            businessToken: "business-token-123"
        )

        #expect(config.scanPrecision == .high)
        #expect(config.maxQueuedPayloads.value == 100)
    }

    @Test("SDKConfiguration scan precision values")
    func scanPrecisionValues() {
        let high = SDKConfiguration(businessToken: "t", scanPrecision: .high)
        #expect(high.precisionLocationAccuracy == 10)
        #expect(high.syncInterval == 15)

        let medium = SDKConfiguration(businessToken: "t", scanPrecision: .medium)
        #expect(medium.precisionLocationAccuracy == 10)
        #expect(medium.syncInterval == 60)

        let low = SDKConfiguration(businessToken: "t", scanPrecision: .low)
        #expect(low.precisionLocationAccuracy == 100)
        #expect(low.syncInterval == 60)
    }

    @Test("SDKConfiguration cycle interval is always 60s")
    func cycleIntervalConstant() {
        for precision in ScanPrecision.allCases {
            let config = SDKConfiguration(businessToken: "t", scanPrecision: precision)
            #expect(config.precisionCycleInterval == 60)
        }
    }

    @Test("SDKConfiguration max queued payloads")
    func maxQueuedPayloads() {
        let sizes: [(MaxQueuedPayloads, Int)] = [
            (.small, 50),
            (.medium, 100),
            (.large, 200),
            (.xlarge, 500)
        ]

        for (size, expected) in sizes {
            let config = SDKConfiguration(
                businessToken: "business-token-123",
                maxQueuedPayloads: size
            )
            #expect(config.maxQueuedPayloads.value == expected)
        }
    }

    @Test("SDKConfiguration extracts Bundle ID automatically")
    func configurationBundleId() {
        let config = SDKConfiguration(
            businessToken: "business-token-123"
        )

        // Bundle ID should be extracted from Bundle.main.bundleIdentifier
        // In tests, this might be "unknown" or the test bundle ID
        #expect(config.appId.isEmpty == false)
    }
}

@Suite("Periodic Reconciliation Configuration")
struct PeriodicReconciliationConfigurationTests {

    @Test("Defaults: enabled, 20 minutes, 12s scan window")
    func defaults() {
        let config = SDKConfiguration(businessToken: "t")
        #expect(config.periodicReconciliationEnabled == true)
        #expect(config.periodicReconciliationInterval == 20 * 60)
        #expect(config.periodicScanDuration == 12)
    }

    @Test("Interval shorter than 20 minutes is accepted as-is")
    func shorterInterval() {
        let config = SDKConfiguration(businessToken: "t", periodicReconciliationInterval: 10 * 60)
        #expect(config.periodicReconciliationInterval == 10 * 60)
    }

    @Test("Interval longer than 20 minutes is accepted as-is")
    func longerInterval() {
        let config = SDKConfiguration(businessToken: "t", periodicReconciliationInterval: 6 * 60 * 60)
        #expect(config.periodicReconciliationInterval == 6 * 60 * 60)
    }

    @Test("Interval exactly at the 60s floor is accepted")
    func intervalAtFloor() {
        let config = SDKConfiguration(businessToken: "t", periodicReconciliationInterval: 60)
        #expect(config.periodicReconciliationInterval == 60)
    }

    @Test("Interval below the floor clamps to 60s")
    func intervalBelowFloor() {
        let config = SDKConfiguration(businessToken: "t", periodicReconciliationInterval: 5)
        #expect(config.periodicReconciliationInterval == 60)
    }

    @Test("Zero, negative, infinite and NaN intervals fall back to the default")
    func invalidIntervals() {
        for bad in [0.0, -300.0, Double.infinity, -Double.infinity, Double.nan] {
            let config = SDKConfiguration(businessToken: "t", periodicReconciliationInterval: bad)
            #expect(config.periodicReconciliationInterval == PeriodicReconciliationDefaults.interval)
        }
    }

    @Test("Scan duration below the minimum clamps to 3s")
    func scanDurationBelowMinimum() {
        let config = SDKConfiguration(businessToken: "t", periodicScanDuration: 0.5)
        #expect(config.periodicScanDuration == 3)
    }

    @Test("Scan duration above the maximum clamps to 30s")
    func scanDurationAboveMaximum() {
        let config = SDKConfiguration(businessToken: "t", periodicScanDuration: 120)
        #expect(config.periodicScanDuration == 30)
    }

    @Test("Invalid scan durations fall back to the default")
    func invalidScanDurations() {
        for bad in [0.0, -5.0, Double.infinity, Double.nan] {
            let config = SDKConfiguration(businessToken: "t", periodicScanDuration: bad)
            #expect(config.periodicScanDuration == PeriodicReconciliationDefaults.scanDuration)
        }
    }

    @Test("Feature can be disabled")
    func disabled() {
        let config = SDKConfiguration(businessToken: "t", periodicReconciliationEnabled: false)
        #expect(config.periodicReconciliationEnabled == false)
    }
}
