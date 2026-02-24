//
//  APIClientTests.swift
//  BearoundSDKTests
//
//  Tests for API communication
//

import CoreLocation
import Foundation
import Testing

@testable import BearoundSDK

@Suite("APIClient Tests")
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

    @Test("APIClient initialization with configuration")
    func apiClientInitialization() {
        let config = SDKConfiguration(
            businessToken: "test-business-token-123",
            scanPrecision: .high
        )

        let apiClient = APIClient(configuration: config)

        // Verify client initializes without crashing
        #expect(apiClient != nil)
    }

    @Test("API payload structure validation")
    func apiPayloadStructure() {
        // Test that we can create the models needed for API payload
        let sdkInfo = SDKInfo(
            appId: "test-app",
            build: 100
        )

        #expect(sdkInfo.appId == "test-app")
        #expect(sdkInfo.build == 100)
        #expect(sdkInfo.version == "2.2.1")
        #expect(sdkInfo.platform == "ios")
    }
    
    @Test("Beacon model creation")
    func beaconModelCreation() {
        let uuid = UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!
        
        let beacon = Beacon(
            uuid: uuid,
            major: 1000,
            minor: 2000,
            rssi: -65,
            proximity: .near,
            accuracy: 2.5,
            timestamp: Date(),
            metadata: nil,
            txPower: -59
        )
        
        #expect(beacon.uuid == uuid)
        #expect(beacon.major == 1000)
        #expect(beacon.minor == 2000)
        #expect(beacon.rssi == -65)
        #expect(beacon.accuracy == 2.5)
        #expect(beacon.txPower == -59)
    }
    
    @Test("Beacon with metadata")
    func beaconWithMetadata() {
        let metadata = BeaconMetadata(
            firmwareVersion: "2.1.0",
            batteryLevel: 87,
            movements: 42,
            temperature: 24,
            txPower: -59,
            rssiFromBLE: -63,
            isConnectable: true
        )
        
        let beacon = Beacon(
            uuid: UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!,
            major: 1000,
            minor: 2000,
            rssi: -65,
            proximity: .near,
            accuracy: 2.5,
            timestamp: Date(),
            metadata: metadata,
            txPower: -59
        )
        
        #expect(beacon.metadata != nil)
        #expect(beacon.metadata?.firmwareVersion == "2.1.0")
        #expect(beacon.metadata?.batteryLevel == 87)
        #expect(beacon.metadata?.movements == 42)
        #expect(beacon.metadata?.temperature == 24)
        #expect(beacon.metadata?.isConnectable == true)
    }
    
    @Test("UserDevice model is collected")
    func userDeviceModelCollected() {
        // Test that DeviceInfoCollector can create UserDevice
        let collector = DeviceInfoCollector()
        
        let device = collector.collectDeviceInfo(
            locationPermission: .authorizedAlways,
            bluetoothState: "powered_on",
            appInForeground: true
        )
        
        // Verify basic fields are populated
        #expect(!device.manufacturer.isEmpty)
        #expect(!device.model.isEmpty)
        #expect(!device.osVersion.isEmpty)
        #expect(device.batteryLevel >= 0 && device.batteryLevel <= 1)
        #expect(device.locationPermission == "authorized_always")
        #expect(device.appInForeground == true)
    }
    
    @Test("Beacon metadata model")
    func beaconMetadataModel() {
        let metadata = BeaconMetadata(
            firmwareVersion: "v1.2.3",
            batteryLevel: 95,
            movements: 12,
            temperature: 25,
            txPower: -59,
            rssiFromBLE: -62,
            isConnectable: true
        )
        
        #expect(metadata.firmwareVersion == "v1.2.3")
        #expect(metadata.batteryLevel == 95)
        #expect(metadata.movements == 12)
        #expect(metadata.temperature == 25)
        #expect(metadata.txPower == -59)
        #expect(metadata.rssiFromBLE == -62)
        #expect(metadata.isConnectable == true)
    }
    
    @Test("UserProperties model")
    func userPropertiesModel() {
        let properties = UserProperties(
            internalId: "user-123",
            email: "user@example.com",
            name: "John Doe",
            customProperties: ["tier": "premium", "region": "US"]
        )
        
        #expect(properties.internalId == "user-123")
        #expect(properties.email == "user@example.com")
        #expect(properties.name == "John Doe")
        #expect(properties.customProperties["tier"] == "premium")
        #expect(properties.customProperties["region"] == "US")
    }
    
    @Test("APIClient base URL validation")
    func apiClientBaseURLValidation() {
        let config = SDKConfiguration(
            businessToken: "test-token",
            scanPrecision: .high
        )
        
        #expect(config.apiBaseURL == "https://ingest.bearound.io")
    }
}
