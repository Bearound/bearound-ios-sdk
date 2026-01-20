//
//  DeviceInfoCollectorTests.swift
//  BearoundSDKTests
//
//  Tests for device information collection
//

import CoreLocation
import Foundation
import Testing
import UIKit

@testable import BearoundSDK

@Suite("DeviceInfoCollector Tests")
@MainActor
struct DeviceInfoCollectorTests {
    
    @Test("Initialize collector")
    func initializeCollector() {
        let collector = DeviceInfoCollector(isColdStart: true)
        
        // Should initialize without crashing
        #expect(collector != nil)
    }
    
    @Test("Collect basic device info")
    func collectBasicDeviceInfo() {
        let collector = DeviceInfoCollector(isColdStart: false)
        
        let deviceInfo = collector.collectDeviceInfo(
            locationPermission: .authorizedAlways,
            bluetoothState: "powered_on",
            appInForeground: true,
            location: nil
        )
        
        // Verify basic fields
        #expect(deviceInfo.manufacturer == "Apple")
        #expect(deviceInfo.os == "ios")
        #expect(!deviceInfo.model.isEmpty)
        #expect(!deviceInfo.osVersion.isEmpty)
    }
    
    @Test("Cold start detection")
    func coldStartDetection() {
        let coldStartCollector = DeviceInfoCollector(isColdStart: true)
        let coldDeviceInfo = coldStartCollector.collectDeviceInfo(
            locationPermission: .authorizedAlways,
            bluetoothState: "powered_on",
            appInForeground: true
        )
        
        #expect(coldDeviceInfo.coldStart == true)
        
        let warmStartCollector = DeviceInfoCollector(isColdStart: false)
        let warmDeviceInfo = warmStartCollector.collectDeviceInfo(
            locationPermission: .authorizedAlways,
            bluetoothState: "powered_on",
            appInForeground: true
        )
        
        #expect(warmDeviceInfo.coldStart == false)
    }
    
    @Test("Location permission mapping")
    func locationPermissionMapping() {
        let collector = DeviceInfoCollector()
        
        // Test authorizedAlways
        let alwaysInfo = collector.collectDeviceInfo(
            locationPermission: .authorizedAlways,
            bluetoothState: "powered_on",
            appInForeground: true
        )
        #expect(alwaysInfo.locationPermission == "authorized_always")
        
        // Test authorizedWhenInUse
        let whenInUseInfo = collector.collectDeviceInfo(
            locationPermission: .authorizedWhenInUse,
            bluetoothState: "powered_on",
            appInForeground: true
        )
        #expect(whenInUseInfo.locationPermission == "authorized_when_in_use")
        
        // Test denied
        let deniedInfo = collector.collectDeviceInfo(
            locationPermission: .denied,
            bluetoothState: "powered_on",
            appInForeground: true
        )
        #expect(deniedInfo.locationPermission == "denied")
        
        // Test notDetermined
        let notDeterminedInfo = collector.collectDeviceInfo(
            locationPermission: .notDetermined,
            bluetoothState: "powered_on",
            appInForeground: true
        )
        #expect(notDeterminedInfo.locationPermission == "not_determined")
    }
    
    @Test("Bluetooth state mapping")
    func bluetoothStateMapping() {
        let collector = DeviceInfoCollector()
        
        let states = [
            "powered_on",
            "powered_off",
            "unauthorized",
            "unsupported",
            "unknown"
        ]
        
        for state in states {
            let deviceInfo = collector.collectDeviceInfo(
                locationPermission: .authorizedAlways,
                bluetoothState: state,
                appInForeground: true
            )
            #expect(deviceInfo.bluetoothState == state)
        }
    }
    
    @Test("App foreground state")
    func appForegroundState() {
        let collector = DeviceInfoCollector()
        
        // Test foreground
        let foregroundInfo = collector.collectDeviceInfo(
            locationPermission: .authorizedAlways,
            bluetoothState: "powered_on",
            appInForeground: true
        )
        #expect(foregroundInfo.appInForeground == true)
        
        // Test background
        let backgroundInfo = collector.collectDeviceInfo(
            locationPermission: .authorizedAlways,
            bluetoothState: "powered_on",
            appInForeground: false
        )
        #expect(backgroundInfo.appInForeground == false)
    }
    
    @Test("Location data collection")
    func locationDataCollection() {
        let collector = DeviceInfoCollector()
        
        // Test with location
        let location = CLLocation(
            latitude: -23.5505,
            longitude: -46.6333
        )
        
        let deviceInfo = collector.collectDeviceInfo(
            locationPermission: .authorizedAlways,
            bluetoothState: "powered_on",
            appInForeground: true,
            location: location
        )
        
        #expect(deviceInfo.location != nil)
        #expect(deviceInfo.location?.latitude == -23.5505)
        #expect(deviceInfo.location?.longitude == -46.6333)
        
        // Test without location
        let noLocationInfo = collector.collectDeviceInfo(
            locationPermission: .authorizedAlways,
            bluetoothState: "powered_on",
            appInForeground: true,
            location: nil
        )
        
        #expect(noLocationInfo.location == nil)
    }
    
    @Test("Battery level in valid range")
    func batteryLevelValidRange() {
        let collector = DeviceInfoCollector()
        
        let deviceInfo = collector.collectDeviceInfo(
            locationPermission: .authorizedAlways,
            bluetoothState: "powered_on",
            appInForeground: true
        )
        
        // Battery level should be between 0 and 1
        #expect(deviceInfo.batteryLevel >= 0)
        #expect(deviceInfo.batteryLevel <= 1)
    }
    
    @Test("Screen dimensions are positive")
    func screenDimensionsPositive() {
        let collector = DeviceInfoCollector()
        
        let deviceInfo = collector.collectDeviceInfo(
            locationPermission: .authorizedAlways,
            bluetoothState: "powered_on",
            appInForeground: true
        )
        
        #expect(deviceInfo.screenWidth > 0)
        #expect(deviceInfo.screenHeight > 0)
    }
    
    @Test("Timestamp is recent")
    func timestampIsRecent() {
        let collector = DeviceInfoCollector()
        
        let beforeCollection = Date().timeIntervalSince1970 * 1000
        
        let deviceInfo = collector.collectDeviceInfo(
            locationPermission: .authorizedAlways,
            bluetoothState: "powered_on",
            appInForeground: true
        )
        
        let afterCollection = Date().timeIntervalSince1970 * 1000
        
        // Timestamp should be between before and after collection
        #expect(deviceInfo.timestamp >= Int(beforeCollection))
        #expect(deviceInfo.timestamp <= Int(afterCollection))
    }
    
    @Test("Timezone is not empty")
    func timezoneNotEmpty() {
        let collector = DeviceInfoCollector()
        
        let deviceInfo = collector.collectDeviceInfo(
            locationPermission: .authorizedAlways,
            bluetoothState: "powered_on",
            appInForeground: true
        )
        
        #expect(!deviceInfo.timezone.isEmpty)
    }
    
    @Test("RAM values are reasonable")
    func ramValuesReasonable() {
        let collector = DeviceInfoCollector()
        
        let deviceInfo = collector.collectDeviceInfo(
            locationPermission: .authorizedAlways,
            bluetoothState: "powered_on",
            appInForeground: true
        )
        
        // Total RAM should be positive and less than 1TB (1,000,000 MB)
        #expect(deviceInfo.ramTotalMb > 0)
        #expect(deviceInfo.ramTotalMb < 1_000_000)
        
        // Available RAM should be positive and <= total
        #expect(deviceInfo.ramAvailableMb > 0)
        #expect(deviceInfo.ramAvailableMb <= deviceInfo.ramTotalMb)
    }
    
    @Test("App uptime is positive")
    func appUptimePositive() {
        let collector = DeviceInfoCollector()
        
        // Wait a tiny bit to ensure uptime > 0
        Thread.sleep(forTimeInterval: 0.001)
        
        let deviceInfo = collector.collectDeviceInfo(
            locationPermission: .authorizedAlways,
            bluetoothState: "powered_on",
            appInForeground: true
        )
        
        #expect(deviceInfo.appUptimeMs > 0)
    }
}
