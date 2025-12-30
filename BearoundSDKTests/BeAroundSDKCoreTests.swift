////
////  BeAroundSDKCoreTests.swift
////  BearoundSDKTests
////
////  Core functionality tests for BeAroundSDK
////
//
//import Testing
//import Foundation
//internal import CoreLocation
//@testable import BearoundSDK
//
//@Suite("BeAroundSDK Core Functionality")
//struct BeAroundSDKCoreTests {
//    
//    @Test("SDK singleton instance")
//    func sdkSingletonInstance() {
//        let instance1 = BeAroundSDK.shared
//        let instance2 = BeAroundSDK.shared
//        
//        #expect(instance1 === instance2) // Same instance
//    }
//    
//    @Test("SDK initial state before configuration")
//    func initialState() {
//        let sdk = BeAroundSDK.shared
//        
//        #expect(sdk.isScanning == false)
//        #expect(sdk.currentSyncInterval == nil)
//        #expect(sdk.currentScanDuration == nil)
//        #expect(sdk.isPeriodicScanningEnabled == false)
//        #expect(sdk.isBluetoothScanningEnabled == false)
//    }
//    
//    @Test("SDK configuration updates state")
//    func configurationUpdatesState() {
//        let sdk = BeAroundSDK.shared
//        
//        sdk.configure(
//            appId: "test-app",
//            syncInterval: 25,
//            enableBluetoothScanning: true,
//            enablePeriodicScanning: false
//        )
//        
//        #expect(sdk.currentSyncInterval == 25)
//        #expect(sdk.currentScanDuration != nil)
//        #expect(sdk.isPeriodicScanningEnabled == false)
//        #expect(sdk.isBluetoothScanningEnabled == true)
//    }
//    
//    @Test("SDK bluetooth scanning toggle")
//    func bluetoothScanningToggle() {
//        let sdk = BeAroundSDK.shared
//        
//        sdk.configure(
//            appId: "test-app",
//            syncInterval: 20,
//            enableBluetoothScanning: false
//        )
//        
//        #expect(sdk.isBluetoothScanningEnabled == false)
//        
//        sdk.setBluetoothScanning(enabled: true)
//        #expect(sdk.isBluetoothScanningEnabled == true)
//        
//        sdk.setBluetoothScanning(enabled: false)
//        #expect(sdk.isBluetoothScanningEnabled == false)
//    }
//    
//    @Test("SDK user properties management")
//    func userPropertiesManagement() {
//        let sdk = BeAroundSDK.shared
//        
//        let properties = UserProperties(
//            internalId: "user789",
//            email: "user@test.com",
//            name: "Test User"
//        )
//        
//        // Setting properties should not throw
//        sdk.setUserProperties(properties)
//        
//        // Clearing properties should not throw
//        sdk.clearUserProperties()
//    }
//    
//    @Test("SDK location availability check")
//    func locationAvailabilityCheck() {
//        let isAvailable = BeAroundSDK.isLocationAvailable()
//        
//        // Just verify it returns a boolean
//        #expect(isAvailable == true || isAvailable == false)
//    }
//    
//    @Test("SDK authorization status check")
//    func authorizationStatusCheck() {
//        let status = BeAroundSDK.authorizationStatus()
//        
//        // Verify it returns a valid CLAuthorizationStatus
//        let validStatuses: [CLAuthorizationStatus] = [
//            .notDetermined,
//            .restricted,
//            .denied,
//            .authorizedAlways,
//            .authorizedWhenInUse
//        ]
//        
//        #expect(validStatuses.contains(status))
//    }
//    
//    @Test("Complete SDK setup workflow")
//    func completeSetupWorkflow() {
//        let sdk = BeAroundSDK.shared
//        
//        // 1. Configure SDK
//        sdk.configure(
//            appId: "production-app-id",
//            syncInterval: 30,
//            enableBluetoothScanning: true,
//            enablePeriodicScanning: true
//        )
//        
//        // 2. Set user properties
//        let userProps = UserProperties(
//            internalId: "user123",
//            email: "user@company.com",
//            name: "John Doe",
//            customProperties: ["tier": "premium"]
//        )
//        sdk.setUserProperties(userProps)
//        
//        // 3. Verify configuration
//        #expect(sdk.currentSyncInterval == 30)
//        #expect(sdk.isBluetoothScanningEnabled == true)
//        #expect(sdk.isPeriodicScanningEnabled == true)
//    }
//    
//    @Test("Dynamic configuration changes")
//    func dynamicConfigurationChanges() {
//        let sdk = BeAroundSDK.shared
//        
//        // Initial configuration
//        sdk.configure(
//            appId: "app-v1",
//            syncInterval: 20,
//            enableBluetoothScanning: false
//        )
//        
//        #expect(sdk.isBluetoothScanningEnabled == false)
//        
//        // Update bluetooth scanning
//        sdk.setBluetoothScanning(enabled: true)
//        #expect(sdk.isBluetoothScanningEnabled == true)
//        
//        // Reconfigure with new settings
//        sdk.configure(
//            appId: "app-v2",
//            syncInterval: 45,
//            enableBluetoothScanning: false
//        )
//        
//        #expect(sdk.currentSyncInterval == 45)
//        #expect(sdk.isBluetoothScanningEnabled == false)
//    }
//}
//
