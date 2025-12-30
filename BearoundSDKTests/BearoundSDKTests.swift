//
//  BearoundSDKTests.swift
//  BearoundSDKTests
//
//  Created by Felipe Costa Araujo on 30/12/25.
//

import Testing
import Foundation
import CoreLocation
@testable import BearoundSDK

// MARK: - Beacon Tests

@Suite("Beacon Model Tests")
struct BeaconTests {
    
    @Test("Beacon initialization with all properties")
    func beaconInitialization() {
        let uuid = UUID()
        let metadata = BeaconMetadata(
            firmwareVersion: "1.0.0",
            batteryLevel: 85,
            movements: 10,
            temperature: 25,
            txPower: -59,
            rssiFromBLE: -65,
            isConnectable: true
        )
        
        let beacon = Beacon(
            uuid: uuid,
            major: 100,
            minor: 200,
            rssi: -70,
            proximity: .near,
            accuracy: 2.5,
            timestamp: Date(),
            metadata: metadata,
            txPower: -59
        )
        
        #expect(beacon.uuid == uuid)
        #expect(beacon.major == 100)
        #expect(beacon.minor == 200)
        #expect(beacon.rssi == -70)
        #expect(beacon.proximity == .near)
        #expect(beacon.accuracy == 2.5)
        #expect(beacon.metadata != nil)
        #expect(beacon.txPower == -59)
    }
    
    @Test("Beacon without metadata")
    func beaconWithoutMetadata() {
        let beacon = Beacon(
            uuid: UUID(),
            major: 1,
            minor: 1,
            rssi: -50,
            proximity: .immediate,
            accuracy: 0.5,
            timestamp: Date()
        )
        
        #expect(beacon.metadata == nil)
        #expect(beacon.txPower == nil)
    }
    
    @Test("Beacon proximity values")
    func beaconProximityValues() {
        let proximities: [CLProximity] = [.unknown, .immediate, .near, .far]
        
        for proximity in proximities {
            let beacon = Beacon(
                uuid: UUID(),
                major: 1,
                minor: 1,
                rssi: -50,
                proximity: proximity,
                accuracy: 1.0,
                timestamp: Date()
            )
            
            #expect(beacon.proximity == proximity)
        }
    }
}

// MARK: - BeaconMetadata Tests

@Suite("BeaconMetadata Tests")
struct BeaconMetadataTests {
    
    @Test("BeaconMetadata initialization with required fields")
    func metadataInitialization() {
        let metadata = BeaconMetadata(
            firmwareVersion: "2.1.0",
            batteryLevel: 90,
            movements: 5,
            temperature: 22
        )
        
        #expect(metadata.firmwareVersion == "2.1.0")
        #expect(metadata.batteryLevel == 90)
        #expect(metadata.movements == 5)
        #expect(metadata.temperature == 22)
        #expect(metadata.txPower == nil)
        #expect(metadata.rssiFromBLE == nil)
        #expect(metadata.isConnectable == nil)
    }
    
    @Test("BeaconMetadata with all optional fields")
    func metadataWithOptionalFields() {
        let metadata = BeaconMetadata(
            firmwareVersion: "3.0.0",
            batteryLevel: 75,
            movements: 100,
            temperature: 30,
            txPower: -60,
            rssiFromBLE: -70,
            isConnectable: false
        )
        
        #expect(metadata.txPower == -60)
        #expect(metadata.rssiFromBLE == -70)
        #expect(metadata.isConnectable == false)
    }
    
    @Test("BeaconMetadata equality")
    func metadataEquality() {
        let metadata1 = BeaconMetadata(
            firmwareVersion: "1.0.0",
            batteryLevel: 80,
            movements: 10,
            temperature: 25,
            txPower: -59
        )
        
        let metadata2 = BeaconMetadata(
            firmwareVersion: "1.0.0",
            batteryLevel: 80,
            movements: 10,
            temperature: 25,
            txPower: -59
        )
        
        let metadata3 = BeaconMetadata(
            firmwareVersion: "1.0.0",
            batteryLevel: 85, // Different
            movements: 10,
            temperature: 25,
            txPower: -59
        )
        
        #expect(metadata1 == metadata2)
        #expect(metadata1 != metadata3)
    }
}

// MARK: - UserProperties Tests

@Suite("UserProperties Tests")
struct UserPropertiesTests {
    
    @Test("UserProperties initialization with all fields")
    func userPropertiesInitialization() {
        let properties = UserProperties(
            internalId: "user123",
            email: "user@example.com",
            name: "Test User",
            customProperties: ["role": "admin", "tier": "premium"]
        )
        
        #expect(properties.internalId == "user123")
        #expect(properties.email == "user@example.com")
        #expect(properties.name == "Test User")
        #expect(properties.customProperties.count == 2)
        #expect(properties.customProperties["role"] == "admin")
    }
    
    @Test("UserProperties initialization with empty values")
    func emptyUserProperties() {
        let properties = UserProperties()
        
        #expect(properties.internalId == nil)
        #expect(properties.email == nil)
        #expect(properties.name == nil)
        #expect(properties.customProperties.isEmpty)
        #expect(!properties.hasProperties)
    }
    
    @Test("UserProperties hasProperties detection")
    func hasPropertiesDetection() {
        let emptyProps = UserProperties()
        #expect(!emptyProps.hasProperties)
        
        let propsWithId = UserProperties(internalId: "123")
        #expect(propsWithId.hasProperties)
        
        let propsWithEmail = UserProperties(email: "test@test.com")
        #expect(propsWithEmail.hasProperties)
        
        let propsWithName = UserProperties(name: "John")
        #expect(propsWithName.hasProperties)
        
        let propsWithCustom = UserProperties(customProperties: ["key": "value"])
        #expect(propsWithCustom.hasProperties)
    }
    
    @Test("UserProperties toDictionary conversion")
    func userPropertiesToDictionary() {
        let properties = UserProperties(
            internalId: "user456",
            email: "test@example.com",
            name: "Jane Doe",
            customProperties: ["subscription": "premium", "region": "US"]
        )
        
        let dict = properties.toDictionary()
        
        #expect(dict["internalId"] as? String == "user456")
        #expect(dict["email"] as? String == "test@example.com")
        #expect(dict["name"] as? String == "Jane Doe")
        #expect(dict["subscription"] as? String == "premium")
        #expect(dict["region"] as? String == "US")
        #expect(dict.count == 5)
    }
    
    @Test("UserProperties toDictionary with only custom properties")
    func userPropertiesToDictionaryCustomOnly() {
        let properties = UserProperties(
            customProperties: ["key1": "value1", "key2": "value2"]
        )
        
        let dict = properties.toDictionary()
        
        #expect(dict.count == 2)
        #expect(dict["key1"] as? String == "value1")
        #expect(dict["key2"] as? String == "value2")
    }
}

// MARK: - SDKConfiguration Tests

@Suite("SDKConfiguration Tests")
struct SDKConfigurationTests {
    
    @Test("SDKConfiguration basic initialization")
    func configurationInitialization() {
        let config = SDKConfiguration(
            appId: "test-app-123",
            syncInterval: 30,
            enableBluetoothScanning: true,
            enablePeriodicScanning: false
        )
        
        #expect(config.appId == "test-app-123")
        #expect(config.syncInterval == 30)
        #expect(config.enableBluetoothScanning == true)
        #expect(config.enablePeriodicScanning == false)
        #expect(config.apiBaseURL == "https://ingest.bearound.io")
    }
    
    @Test("SDKConfiguration default values")
    func configurationDefaults() {
        let config = SDKConfiguration(
            appId: "app123",
            syncInterval: 15
        )
        
        #expect(config.enableBluetoothScanning == false)
        #expect(config.enablePeriodicScanning == true)
    }
    
    @Test("SDKConfiguration sync interval clamping - minimum")
    func syncIntervalMinimumClamping() {
        let config = SDKConfiguration(
            appId: "app123",
            syncInterval: 2 // Below minimum
        )
        
        #expect(config.syncInterval == 5) // Should be clamped to 5
    }
    
    @Test("SDKConfiguration sync interval clamping - maximum")
    func syncIntervalMaximumClamping() {
        let config = SDKConfiguration(
            appId: "app123",
            syncInterval: 100 // Above maximum
        )
        
        #expect(config.syncInterval == 60) // Should be clamped to 60
    }
    
    @Test("SDKConfiguration sync interval clamping - valid range")
    func syncIntervalValidRange() {
        let validIntervals: [TimeInterval] = [5, 10, 20, 30, 45, 60]
        
        for interval in validIntervals {
            let config = SDKConfiguration(
                appId: "app123",
                syncInterval: interval
            )
            #expect(config.syncInterval == interval)
        }
    }
    
    @Test("SDKConfiguration scan duration calculation")
    func scanDurationCalculation() {
        // Scan duration should be syncInterval / 3, clamped between 5-10 seconds
        
        let config15 = SDKConfiguration(appId: "app", syncInterval: 15)
        #expect(config15.scanDuration == 5) // 15/3 = 5
        
        let config30 = SDKConfiguration(appId: "app", syncInterval: 30)
        #expect(config30.scanDuration == 10) // 30/3 = 10
        
        let config60 = SDKConfiguration(appId: "app", syncInterval: 60)
        #expect(config60.scanDuration == 10) // 60/3 = 20, but clamped to 10
        
        let config5 = SDKConfiguration(appId: "app", syncInterval: 5)
        #expect(config5.scanDuration == 5) // 5/3 = 1.67, but clamped to 5
    }
    
    @Test("SDKConfiguration mutability of scanning flags")
    func configurationMutability() {
        var config = SDKConfiguration(
            appId: "app123",
            syncInterval: 20,
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
}

// MARK: - BeAroundSDK Integration Tests

@Suite("BeAroundSDK Core Functionality")
struct BeAroundSDKTests {
    
    @Test("SDK singleton instance")
    func sdkSingletonInstance() {
        let instance1 = BeAroundSDK.shared
        let instance2 = BeAroundSDK.shared
        
        #expect(instance1 === instance2) // Same instance
    }
    
    @Test("SDK initial state before configuration")
    func initialState() {
        let sdk = BeAroundSDK.shared
        
        #expect(sdk.isScanning == false)
        #expect(sdk.currentSyncInterval == nil)
        #expect(sdk.currentScanDuration == nil)
        #expect(sdk.isPeriodicScanningEnabled == false)
        #expect(sdk.isBluetoothScanningEnabled == false)
    }
    
    @Test("SDK configuration updates state")
    func configurationUpdatesState() {
        let sdk = BeAroundSDK.shared
        
        sdk.configure(
            appId: "test-app",
            syncInterval: 25,
            enableBluetoothScanning: true,
            enablePeriodicScanning: false
        )
        
        #expect(sdk.currentSyncInterval == 25)
        #expect(sdk.currentScanDuration != nil)
        #expect(sdk.isPeriodicScanningEnabled == false)
        #expect(sdk.isBluetoothScanningEnabled == true)
    }
    
    @Test("SDK bluetooth scanning toggle")
    func bluetoothScanningToggle() {
        let sdk = BeAroundSDK.shared
        
        sdk.configure(
            appId: "test-app",
            syncInterval: 20,
            enableBluetoothScanning: false
        )
        
        #expect(sdk.isBluetoothScanningEnabled == false)
        
        sdk.setBluetoothScanning(enabled: true)
        #expect(sdk.isBluetoothScanningEnabled == true)
        
        sdk.setBluetoothScanning(enabled: false)
        #expect(sdk.isBluetoothScanningEnabled == false)
    }
    
    @Test("SDK user properties management")
    func userPropertiesManagement() {
        let sdk = BeAroundSDK.shared
        
        let properties = UserProperties(
            internalId: "user789",
            email: "user@test.com",
            name: "Test User"
        )
        
        // Setting properties should not throw
        sdk.setUserProperties(properties)
        
        // Clearing properties should not throw
        sdk.clearUserProperties()
    }
    
    @Test("SDK location availability check")
    func locationAvailabilityCheck() {
        let isAvailable = BeAroundSDK.isLocationAvailable()
        
        // Just verify it returns a boolean (actual value depends on device/simulator)
        #expect(isAvailable == true || isAvailable == false)
    }
    
    @Test("SDK authorization status check")
    func authorizationStatusCheck() {
        let status = BeAroundSDK.authorizationStatus()
        
        // Verify it returns a valid CLAuthorizationStatus
        let validStatuses: [CLAuthorizationStatus] = [
            .notDetermined,
            .restricted,
            .denied,
            .authorizedAlways,
            .authorizedWhenInUse
        ]
        
        #expect(validStatuses.contains(status))
    }
}

// MARK: - APIClient Tests (Mock)

@Suite("APIClient Error Handling")
struct APIClientTests {
    
    @Test("APIError descriptions")
    func apiErrorDescriptions() {
        let invalidURLError = APIError.invalidURL
        #expect(invalidURLError.errorDescription == "Invalid API URL")
        
        let invalidResponseError = APIError.invalidResponse
        #expect(invalidResponseError.errorDescription == "Invalid server response")
        
        let httpError = APIError.httpError(statusCode: 404)
        #expect(httpError.errorDescription == "HTTP error: 404")
    }
    
    @Test("APIError different status codes")
    func apiErrorStatusCodes() {
        let error400 = APIError.httpError(statusCode: 400)
        let error401 = APIError.httpError(statusCode: 401)
        let error500 = APIError.httpError(statusCode: 500)
        
        #expect(error400.errorDescription?.contains("400") == true)
        #expect(error401.errorDescription?.contains("401") == true)
        #expect(error500.errorDescription?.contains("500") == true)
    }
}

// MARK: - Integration Scenarios

@Suite("Real-world Usage Scenarios")
struct UsageScenarioTests {
    
    @Test("Complete SDK setup workflow")
    func completeSetupWorkflow() {
        let sdk = BeAroundSDK.shared
        
        // 1. Configure SDK
        sdk.configure(
            appId: "production-app-id",
            syncInterval: 30,
            enableBluetoothScanning: true,
            enablePeriodicScanning: true
        )
        
        // 2. Set user properties
        let userProps = UserProperties(
            internalId: "user123",
            email: "user@company.com",
            name: "John Doe",
            customProperties: ["tier": "premium"]
        )
        sdk.setUserProperties(userProps)
        
        // 3. Verify configuration
        #expect(sdk.currentSyncInterval == 30)
        #expect(sdk.isBluetoothScanningEnabled == true)
        #expect(sdk.isPeriodicScanningEnabled == true)
    }
    
    @Test("User session lifecycle")
    func userSessionLifecycle() {
        let sdk = BeAroundSDK.shared
        
        // User logs in
        let loginProps = UserProperties(
            internalId: "user456",
            email: "newuser@example.com",
            name: "Jane Smith"
        )
        sdk.setUserProperties(loginProps)
        
        // User logs out
        sdk.clearUserProperties()
        
        // No errors should occur
    }
    
    @Test("Dynamic configuration changes")
    func dynamicConfigurationChanges() {
        let sdk = BeAroundSDK.shared
        
        // Initial configuration
        sdk.configure(
            appId: "app-v1",
            syncInterval: 20,
            enableBluetoothScanning: false
        )
        
        #expect(sdk.isBluetoothScanningEnabled == false)
        
        // Update bluetooth scanning
        sdk.setBluetoothScanning(enabled: true)
        #expect(sdk.isBluetoothScanningEnabled == true)
        
        // Reconfigure with new settings
        sdk.configure(
            appId: "app-v2",
            syncInterval: 45,
            enableBluetoothScanning: false
        )
        
        #expect(sdk.currentSyncInterval == 45)
        #expect(sdk.isBluetoothScanningEnabled == false)
    }
    
    @Test("Multiple beacon creation")
    func multipleBeaconCreation() {
        var beacons: [Beacon] = []
        
        // Simulate discovering multiple beacons
        for i in 1...5 {
            let beacon = Beacon(
                uuid: UUID(),
                major: 100,
                minor: i,
                rssi: -60 - i,
                proximity: .near,
                accuracy: Double(i),
                timestamp: Date()
            )
            beacons.append(beacon)
        }
        
        #expect(beacons.count == 5)
        
        // Verify each beacon has unique minor
        let minors = beacons.map { $0.minor }
        let uniqueMinors = Set(minors)
        #expect(uniqueMinors.count == 5)
    }
}

// MARK: - Edge Cases and Validation

@Suite("Edge Cases and Data Validation")
struct EdgeCaseTests {
    
    @Test("Beacon with extreme RSSI values")
    func extremeRSSIValues() {
        let weakBeacon = Beacon(
            uuid: UUID(),
            major: 1,
            minor: 1,
            rssi: -100,
            proximity: .far,
            accuracy: 10.0,
            timestamp: Date()
        )
        
        let strongBeacon = Beacon(
            uuid: UUID(),
            major: 1,
            minor: 2,
            rssi: -30,
            proximity: .immediate,
            accuracy: 0.1,
            timestamp: Date()
        )
        
        #expect(weakBeacon.rssi == -100)
        #expect(strongBeacon.rssi == -30)
    }
    
    @Test("BeaconMetadata with extreme values")
    func extremeMetadataValues() {
        let lowBattery = BeaconMetadata(
            firmwareVersion: "1.0.0",
            batteryLevel: 0,
            movements: 0,
            temperature: -10
        )
        
        let highValues = BeaconMetadata(
            firmwareVersion: "99.99.99",
            batteryLevel: 100,
            movements: 999999,
            temperature: 100
        )
        
        #expect(lowBattery.batteryLevel == 0)
        #expect(highValues.batteryLevel == 100)
        #expect(highValues.movements == 999999)
    }
    
    @Test("UserProperties with special characters")
    func specialCharactersInUserProperties() {
        let properties = UserProperties(
            internalId: "user@#$%^&*()",
            email: "test+special@domain.co.uk",
            name: "José María Ñoño",
            customProperties: [
                "key-with-dashes": "value",
                "key_with_underscores": "value",
                "key.with.dots": "value"
            ]
        )
        
        #expect(properties.internalId == "user@#$%^&*()")
        #expect(properties.email == "test+special@domain.co.uk")
        #expect(properties.name == "José María Ñoño")
        #expect(properties.customProperties.count == 3)
    }
    
    @Test("Empty string values in UserProperties")
    func emptyStringValues() {
        let properties = UserProperties(
            internalId: "",
            email: "",
            name: "",
            customProperties: ["": ""]
        )
        
        // Empty strings should still count as having properties
        #expect(properties.hasProperties)
        #expect(properties.internalId == "")
        #expect(properties.email == "")
        #expect(properties.name == "")
    }
    
    @Test("Very long custom property values")
    func longCustomPropertyValues() {
        let longValue = String(repeating: "a", count: 1000)
        let properties = UserProperties(
            customProperties: ["longKey": longValue]
        )
        
        #expect(properties.customProperties["longKey"]?.count == 1000)
    }
    
    @Test("Multiple rapid configuration changes")
    func rapidConfigurationChanges() {
        let sdk = BeAroundSDK.shared
        
        // Rapidly change configuration multiple times
        for i in 1...10 {
            sdk.configure(
                appId: "app-\(i)",
                syncInterval: TimeInterval(5 + i),
                enableBluetoothScanning: i % 2 == 0,
                enablePeriodicScanning: i % 3 == 0
            )
        }
        
        // SDK should still be in valid state
        #expect(sdk.currentSyncInterval != nil)
    }
}

// MARK: - Thread Safety Tests

@Suite("Concurrency and Thread Safety")
struct ConcurrencyTests {
    
    @Test("Concurrent beacon creation")
    func concurrentBeaconCreation() async {
        await withTaskGroup(of: Beacon.self) { group in
            for i in 1...100 {
                group.addTask {
                    return Beacon(
                        uuid: UUID(),
                        major: i,
                        minor: i,
                        rssi: -60,
                        proximity: .near,
                        accuracy: 1.0,
                        timestamp: Date()
                    )
                }
            }
            
            var beacons: [Beacon] = []
            for await beacon in group {
                beacons.append(beacon)
            }
            
            #expect(beacons.count == 100)
        }
    }
    
    @Test("Concurrent user properties updates")
    func concurrentUserPropertiesUpdates() async {
        let sdk = BeAroundSDK.shared
        
        await withTaskGroup(of: Void.self) { group in
            for i in 1...50 {
                group.addTask {
                    let props = UserProperties(
                        internalId: "user-\(i)",
                        email: "user\(i)@test.com"
                    )
                    sdk.setUserProperties(props)
                }
            }
        }
        
        // Should complete without crashes
    }
    
    @Test("Concurrent configuration changes")
    func concurrentConfigurationChanges() async {
        let sdk = BeAroundSDK.shared
        
        await withTaskGroup(of: Void.self) { group in
            for i in 1...20 {
                group.addTask {
                    sdk.configure(
                        appId: "concurrent-app-\(i)",
                        syncInterval: 10 + TimeInterval(i),
                        enableBluetoothScanning: i % 2 == 0
                    )
                }
            }
        }
        
        // Should complete without crashes
        #expect(sdk.currentSyncInterval != nil)
    }
}
