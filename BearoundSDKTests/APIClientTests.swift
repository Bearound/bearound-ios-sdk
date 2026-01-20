//
//  APIClientTests.swift
//  BearoundSDKTests
//
//  Tests for API communication
//

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
            foregroundScanInterval: .seconds10,
            backgroundScanInterval: .seconds60
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
            proximity: 2, // near
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
            proximity: 2,
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
    
    @Test("UserDevice model validation")
    func userDeviceModelValidation() {
        let device = UserDevice(
            manufacturer: "Apple",
            model: "iPhone 13",
            os: "ios",
            osVersion: "17.2",
            timestamp: 1735940400000,
            timezone: "America/Sao_Paulo",
            batteryLevel: 0.78,
            isCharging: false,
            lowPowerMode: false,
            bluetoothState: "powered_on",
            locationPermission: "authorized_always",
            locationAccuracy: "full",
            notificationsPermission: "authorized",
            networkType: "wifi",
            cellularGeneration: nil,
            isRoaming: false,
            ramTotalMb: 4096,
            ramAvailableMb: 1280,
            screenWidth: 1170,
            screenHeight: 2532,
            advertisingId: "00000000-0000-0000-0000-000000000000",
            adTrackingEnabled: false,
            appInForeground: true,
            appUptimeMs: 12345,
            coldStart: false,
            location: nil
        )
        
        #expect(device.manufacturer == "Apple")
        #expect(device.model == "iPhone 13")
        #expect(device.batteryLevel == 0.78)
        #expect(device.isCharging == false)
        #expect(device.locationPermission == "authorized_always")
        #expect(device.appInForeground == true)
    }
    
    @Test("DeviceLocation model")
    func deviceLocationModel() {
        let location = DeviceLocation(
            latitude: -23.5505,
            longitude: -46.6333,
            accuracy: 10.0,
            altitude: 760.0,
            altitudeAccuracy: 5.0,
            speed: 0.0,
            speedAccuracy: nil,
            course: 0.0,
            courseAccuracy: nil,
            timestamp: 1735940400000,
            floor: nil,
            sourceInformation: nil
        )
        
        #expect(location.latitude == -23.5505)
        #expect(location.longitude == -46.6333)
        #expect(location.accuracy == 10.0)
        #expect(location.altitude == 760.0)
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
        #expect(properties.customProperties?["tier"] == "premium")
        #expect(properties.customProperties?["region"] == "US")
    }
    
    @Test("APIClient base URL validation")
    func apiClientBaseURLValidation() {
        let config = SDKConfiguration(
            businessToken: "test-token",
            foregroundScanInterval: .seconds15,
            backgroundScanInterval: .seconds60
        )
        
        #expect(config.apiBaseURL == "https://ingest.bearound.io")
    }
}
