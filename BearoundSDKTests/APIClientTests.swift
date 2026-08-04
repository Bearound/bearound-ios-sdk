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
        // version now tracks the real SDK version (no stale "2.2.1" default on the wire)
        #expect(sdkInfo.version == BeAroundSDK.version)
        #expect(sdkInfo.platform == "ios")
        #expect(sdkInfo.technology == "ios-native")
    }

    @Test("BeAroundSDK.version reads from the framework bundle, not a Swift literal")
    func versionFromBundle() {
        let bundleVersion = Bundle(for: BeAroundSDK.self).infoDictionary?["CFBundleShortVersionString"] as? String
        #expect(BeAroundSDK.version == bundleVersion)
        #expect(BeAroundSDK.version != "2.2.1") // the old stale-default bug must never come back
        #expect(!BeAroundSDK.version.isEmpty)
    }

    @Test("sdk wire payload carries the real version + ios-native technology")
    func sdkWirePayload() throws {
        let sdkInfo = SDKInfo(appId: "com.test.app", build: 210)
        let dict = APIClient.makeSdkPayload(sdkInfo)
        let data = try JSONSerialization.data(withJSONObject: dict)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["version"] as? String == BeAroundSDK.version) // wire == bundle version
        #expect(json["version"] as? String != "2.2.1")
        #expect(json["technology"] as? String == "ios-native")
        #expect(json["platform"] as? String == "ios")
        #expect(json["build"] as? Int == 210)
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
    
    // `collectDeviceInfo` reads notification/app state (UNUserNotificationCenter /
    // UIApplication), which throws `bundleProxyForCurrentProcess is nil` in a
    // host-less unit-test bundle (as in CI). Run it only where there's an app host.
    @Test("UserDevice model is collected", .enabled(if: Bundle.main.bundlePath.hasSuffix(".app")))
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
        // Battery is a fraction in [0, 1], or the -1 sentinel when it can't be read
        // (battery monitoring off / the Simulator, which reports -1).
        #expect(device.batteryLevel == -1 || (device.batteryLevel >= 0 && device.batteryLevel <= 1))
        #expect(device.locationPermission == "authorized_always")
        #expect(device.appInForeground == true)
    }
    
    @Test("Lista de beacons vazia só sobe quando há o que arquivar")
    func emptyBeaconsRule() {
        // register: registra o aparelho antes de ele ter visto qualquer beacon.
        #expect(APIClient.acceptsEmptyBeacons(syncTrigger: "register", hasEncounters: false))

        // Encontros: viu outros aparelhos, nenhum beacon no alcance. Há o que arquivar.
        #expect(APIClient.acceptsEmptyBeacons(syncTrigger: "encounter_mesh", hasEncounters: true))
        #expect(APIClient.acceptsEmptyBeacons(syncTrigger: "ble_detection", hasEncounters: true))

        // Scan que não achou nada: onde o aparelho estava, e o Wi-Fi ao redor, É o dado.
        #expect(
            APIClient.acceptsEmptyBeacons(
                syncTrigger: "presence_heartbeat", hasEncounters: false, hasLocation: true
            )
        )
        #expect(
            APIClient.acceptsEmptyBeacons(
                syncTrigger: "presence_heartbeat", hasEncounters: false, hasWifis: true
            )
        )

        // Sem beacon, sem encontro, sem localização e sem Wi-Fi não há nada a registrar — o
        // ingest responde 400 "Missing beacons in payload", então isso não pode virar requisição.
        for trigger in [
            "encounter_mesh", "ble_detection", "precision_high_timer", "presence_heartbeat",
            "bluetooth_zone_enter", "background_fetch", "unknown", "", "Register", "register ",
        ] {
            #expect(
                !APIClient.acceptsEmptyBeacons(syncTrigger: trigger, hasEncounters: false),
                "aceitou \(trigger) sem nada para enviar"
            )
        }
    }

    @Test("o motivo do envio sobrevive ao motivo que agendou o sync")
    func composedSyncTrigger() {
        // A regressão que isto tranca: o carimbo só acontecia enquanto o trigger ainda era
        // "unknown", mas o coordenador SEMPRE escreve o motivo do agendamento antes. Resultado:
        // nem encounter_mesh nem presence_heartbeat chegavam ao payload — todo reporte de scan
        // vazio subia como "precision_high_timer", indistinguível de um sync comum.
        #expect(
            BeAroundSDK.composedTrigger(current: "precision_high_timer", adding: "presence_heartbeat")
                == "precision_high_timer+presence_heartbeat"
        )
        #expect(
            BeAroundSDK.composedTrigger(current: "ble_detection+precision_high_timer", adding: "encounter_mesh")
                == "ble_detection+encounter_mesh+precision_high_timer"
        )

        // Sem motivo prévio, o motivo do envio é o trigger inteiro.
        #expect(BeAroundSDK.composedTrigger(current: "unknown", adding: "presence_heartbeat") == "presence_heartbeat")
        #expect(BeAroundSDK.composedTrigger(current: "", adding: "encounter_mesh") == "encounter_mesh")

        // Idempotente: reentrar no mesmo caminho não duplica a razão.
        #expect(
            BeAroundSDK.composedTrigger(current: "presence_heartbeat", adding: "presence_heartbeat")
                == "presence_heartbeat"
        )
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

    @Test("merging keeps existing internalId when the update omits it")
    func mergingPreservesInternalId() {
        let base = UserProperties(internalId: "user-123")
        let update = UserProperties(email: "user@example.com")

        let merged = base.merging(update)

        #expect(merged.internalId == "user-123")
        #expect(merged.email == "user@example.com")
    }

    @Test("merging overrides provided fields and merges custom keys")
    func mergingOverridesAndMergesCustom() {
        let base = UserProperties(internalId: "old", name: "Old", customProperties: ["a": "1", "b": "2"])
        let update = UserProperties(internalId: "new", customProperties: ["b": "9", "c": "3"])

        let merged = base.merging(update)

        #expect(merged.internalId == "new")
        #expect(merged.name == "Old")
        #expect(merged.customProperties["a"] == "1")
        #expect(merged.customProperties["b"] == "9")
        #expect(merged.customProperties["c"] == "3")
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
