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
        #expect(high.precisionPauseDuration == 0)
        #expect(high.precisionCycleCount == 0)
        #expect(high.precisionLocationAccuracy == 10)
        #expect(high.syncInterval == 15)

        let medium = SDKConfiguration(businessToken: "t", scanPrecision: .medium)
        #expect(medium.precisionPauseDuration == 10)
        #expect(medium.precisionCycleCount == 3)
        #expect(medium.precisionLocationAccuracy == 10)
        #expect(medium.syncInterval == 60)

        let low = SDKConfiguration(businessToken: "t", scanPrecision: .low)
        #expect(low.precisionPauseDuration == 50)
        #expect(low.precisionCycleCount == 1)
        #expect(low.precisionLocationAccuracy == 100)
        #expect(low.syncInterval == 60)
    }

    @Test("SDKConfiguration scan duration is always 10s")
    func scanDurationConstant() {
        for precision in ScanPrecision.allCases {
            let config = SDKConfiguration(businessToken: "t", scanPrecision: precision)
            #expect(config.precisionScanDuration == 10)
        }
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
