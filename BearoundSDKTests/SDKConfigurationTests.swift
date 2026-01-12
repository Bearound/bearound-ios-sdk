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
            foregroundScanInterval: .seconds30,
            backgroundScanInterval: .seconds60,
            maxQueuedPayloads: .medium,
            enableBluetoothScanning: true,
            enablePeriodicScanning: false
        )

        #expect(config.businessToken == "test-business-token-abc123")
        #expect(config.foregroundScanInterval.timeInterval == 30)
        #expect(config.backgroundScanInterval.timeInterval == 60)
        #expect(config.maxQueuedPayloads.value == 100)
        #expect(config.enableBluetoothScanning == true)
        #expect(config.enablePeriodicScanning == false)
        #expect(config.apiBaseURL == "https://ingest.bearound.io")
        // appId is now obtained dynamically from Bundle.main.bundleIdentifier
        #expect(config.appId != "")
    }

    @Test("SDKConfiguration default values")
    func configurationDefaults() {
        let config = SDKConfiguration(
            businessToken: "business-token-123"
        )

        #expect(config.foregroundScanInterval.timeInterval == 15)
        #expect(config.backgroundScanInterval.timeInterval == 60)
        #expect(config.maxQueuedPayloads.value == 100)
        #expect(config.enableBluetoothScanning == false)
        #expect(config.enablePeriodicScanning == true)
    }

    @Test("SDKConfiguration foreground scan intervals")
    func foregroundScanIntervals() {
        let intervals: [(ForegroundScanInterval, TimeInterval)] = [
            (.seconds5, 5),
            (.seconds10, 10),
            (.seconds15, 15),
            (.seconds20, 20),
            (.seconds25, 25),
            (.seconds30, 30),
            (.seconds35, 35),
            (.seconds40, 40),
            (.seconds45, 45),
            (.seconds50, 50),
            (.seconds55, 55),
            (.seconds60, 60)
        ]

        for (interval, expected) in intervals {
            let config = SDKConfiguration(
                businessToken: "business-token-123",
                foregroundScanInterval: interval
            )
            #expect(config.foregroundScanInterval.timeInterval == expected)
        }
    }

    @Test("SDKConfiguration background scan intervals")
    func backgroundScanIntervals() {
        let intervals: [(BackgroundScanInterval, TimeInterval)] = [
            (.seconds60, 60),
            (.seconds90, 90),
            (.seconds120, 120)
        ]

        for (interval, expected) in intervals {
            let config = SDKConfiguration(
                businessToken: "business-token-123",
                backgroundScanInterval: interval
            )
            #expect(config.backgroundScanInterval.timeInterval == expected)
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

    @Test("SDKConfiguration scan duration calculation")
    func scanDurationCalculation() {
        // Scan duration should be syncInterval / 3, clamped between 5-10 seconds

        let config15 = SDKConfiguration(
            businessToken: "biz-token",
            foregroundScanInterval: .seconds15
        )
        #expect(config15.scanDuration(for: 15) == 5) // 15/3 = 5

        let config30 = SDKConfiguration(
            businessToken: "biz-token",
            foregroundScanInterval: .seconds30
        )
        #expect(config30.scanDuration(for: 30) == 10) // 30/3 = 10

        let config60 = SDKConfiguration(
            businessToken: "biz-token",
            foregroundScanInterval: .seconds60
        )
        #expect(config60.scanDuration(for: 60) == 10) // 60/3 = 20, but clamped to 10

        let config5 = SDKConfiguration(
            businessToken: "biz-token",
            foregroundScanInterval: .seconds5
        )
        #expect(config5.scanDuration(for: 5) == 5) // 5/3 = 1.67, but clamped to 5
    }

    @Test("SDKConfiguration sync interval based on background state")
    func syncIntervalByBackgroundState() {
        let config = SDKConfiguration(
            businessToken: "business-token-123",
            foregroundScanInterval: .seconds15,
            backgroundScanInterval: .seconds90
        )

        #expect(config.syncInterval(isInBackground: false) == 15)
        #expect(config.syncInterval(isInBackground: true) == 90)
    }

    @Test("SDKConfiguration mutability of scanning flags")
    func configurationMutability() {
        var config = SDKConfiguration(
            businessToken: "business-token-123",
            foregroundScanInterval: .seconds20,
            backgroundScanInterval: .seconds60,
            enableBluetoothScanning: false,
            enablePeriodicScanning: true
        )

        #expect(config.enableBluetoothScanning == false)
        #expect(config.enablePeriodicScanning == true)

        config.enableBluetoothScanning = true
        config.enablePeriodicScanning = false

        #expect(config.enableBluetoothScanning == true)
        #expect(config.enablePeriodicScanning == false)
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


