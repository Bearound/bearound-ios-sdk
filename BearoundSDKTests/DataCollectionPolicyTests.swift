//
//  DataCollectionPolicyTests.swift
//  BearoundSDKTests
//
//  The host's collect-or-not switches: defaults and the config → policy mapping the
//  collectors read. The persistence round-trip lives in SDKConfigStorageTests.
//

import CoreLocation
import Foundation
import Testing

@testable import BearoundSDK

// .serialized: these mutate the process-wide policy store, so a parallel test would read
// another test's policy. The persistence round-trip lives in SDKConfigStorageTests instead —
// everything touching that UserDefaults suite has to run inside ONE serialized suite.
@Suite("DataCollectionPolicy Tests", .serialized)
struct DataCollectionPolicyTests {

    @Test("Everything is collected unless the host says otherwise")
    func defaultsAreAllEnabled() {
        let config = SDKConfiguration(businessToken: "t")

        #expect(config.collectAdvertisingId)
        #expect(config.collectLocation)
        #expect(config.collectWifi)
        #expect(config.dataCollectionPolicy == .allEnabled)
    }

    @Test("Each switch maps to the policy the collectors read")
    func configurationMapsToPolicy() {
        let noIdfa = SDKConfiguration(businessToken: "t", collectAdvertisingId: false)
        #expect(noIdfa.dataCollectionPolicy == DataCollectionPolicy(advertisingId: false))

        let noLocation = SDKConfiguration(businessToken: "t", collectLocation: false)
        #expect(noLocation.dataCollectionPolicy == DataCollectionPolicy(location: false))

        let noWifi = SDKConfiguration(businessToken: "t", collectWifi: false)
        #expect(noWifi.dataCollectionPolicy == DataCollectionPolicy(wifi: false))
    }

    @Test("One switch off never turns another off")
    func switchesAreIndependent() {
        let config = SDKConfiguration(
            businessToken: "t",
            collectAdvertisingId: false,
            collectLocation: true,
            collectWifi: false
        )

        #expect(!config.dataCollectionPolicy.advertisingId)
        #expect(config.dataCollectionPolicy.location)
        #expect(!config.dataCollectionPolicy.wifi)
    }

    // The switch is only worth anything if the COLLECTOR honours it — the config mapping
    // above would pass just as happily with the collector ignoring the policy entirely.
    // Same host-app guard as APIClientTests: collectDeviceInfo reads UIApplication /
    // UNUserNotificationCenter, which throw in a host-less test bundle.
    @Test(
        "A disabled signal never reaches the payload",
        .enabled(if: Bundle.main.bundlePath.hasSuffix(".app"))
    )
    func collectorHonoursThePolicy() {
        defer { DataCollectionPolicyStore.reset() }

        DataCollectionPolicyStore.apply(
            DataCollectionPolicy(advertisingId: false, location: false, wifi: false)
        )

        let device = DeviceInfoCollector().collectDeviceInfo(
            locationPermission: .authorizedAlways,
            bluetoothState: "powered_on",
            appInForeground: true
        )

        #expect(device.advertisingId == nil)
        #expect(device.trackingAuthorization == nil)
        #expect(device.location == nil)
        #expect(device.wifis.isEmpty)
        #expect(device.apId == nil)
        #expect(device.wifiSSID == nil)
        // The authorisation status is NOT the position — it stays, so the backend can still
        // explain why data is missing.
        #expect(device.locationPermission == "authorized_always")
    }

    @Test("The store hands the collectors what was applied")
    func storeAppliesPolicy() {
        defer { DataCollectionPolicyStore.reset() }

        DataCollectionPolicyStore.apply(
            SDKConfiguration(businessToken: "t", collectLocation: false).dataCollectionPolicy
        )

        #expect(!DataCollectionPolicyStore.current.location)
        #expect(DataCollectionPolicyStore.current.advertisingId)
        #expect(DataCollectionPolicyStore.current.wifi)
    }
}
