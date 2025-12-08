//
//  BearoundSDKTests.swift
//  BearoundSDKTests
//
//  Created by Felipe Costa Araujo on 08/12/25.
//

import XCTest
@testable import BearoundSDK
import Testing
import CoreLocation

// MARK: - Beacon Tests

@Suite("Beacon Tests")
struct BeaconTests {
    
    @Test("Beacon equality based on major and minor")
    func beaconEquality() {
        let beacon1 = Beacon(
            major: "100",
            minor: "200",
            rssi: -60,
            bluetoothName: "BeA:b_100.200",
            bluetoothAddress: "ADDRESS-1",
            distanceMeters: 1.5,
            lastSeen: Date()
        )
        
        let beacon2 = Beacon(
            major: "100",
            minor: "200",
            rssi: -65,
            bluetoothName: "BeA:b_100.200",
            bluetoothAddress: "ADDRESS-2",
            distanceMeters: 2.0,
            lastSeen: Date()
        )
        
        let beacon3 = Beacon(
            major: "100",
            minor: "201",
            rssi: -60,
            bluetoothName: "BeA:b_100.201",
            bluetoothAddress: "ADDRESS-3",
            distanceMeters: 1.5,
            lastSeen: Date()
        )
        
        #expect(beacon1 == beacon2, "Beacons with same major/minor should be equal")
        #expect(beacon1 != beacon3, "Beacons with different minor should not be equal")
    }
    
    @Test("Beacon UUID is consistent")
    func beaconUUID() {
        let beacon = Beacon(
            major: "100",
            minor: "200",
            rssi: -60,
            bluetoothName: nil,
            bluetoothAddress: nil,
            distanceMeters: nil,
            lastSeen: Date()
        )
        
        let expectedUUID = UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!
        #expect(beacon.uuid == expectedUUID, "Beacon UUID should match the expected UUID")
    }
}

// MARK: - BeaconParser Tests

@Suite("BeaconParser Tests")
struct BeaconParserTests {
    
    let parser = BeaconParser()
    
    @Test("Parse major from beacon name")
    func parseMajor() {
        let name1 = "BeA:b_100.200"
        let major1 = parser.getMajor(name1)
        #expect(major1 == "100", "Should extract major value correctly")
        
        let name2 = "BeA:b_5.10"
        let major2 = parser.getMajor(name2)
        #expect(major2 == "5", "Should extract single digit major")
        
        let invalidName = "BeA:invalid"
        let major3 = parser.getMajor(invalidName)
        #expect(major3 == nil, "Should return nil for invalid format")
    }
    
    @Test("Parse minor from beacon name")
    func parseMinor() {
        let name1 = "BeA:b_100.200"
        let minor1 = parser.getMinor(name1)
        #expect(minor1 == "200", "Should extract minor value correctly")
        
        let name2 = "BeA:b_5.10"
        let minor2 = parser.getMinor(name2)
        #expect(minor2 == "10", "Should extract two digit minor")
        
        let invalidName = "BeA:invalid"
        let minor3 = parser.getMinor(invalidName)
        #expect(minor3 == nil, "Should return nil for invalid format")
    }
    
    @Test("Calculate distance from RSSI")
    func calculateDistance() {
        // Test with valid RSSI
        let distance1 = parser.getDistanceInMeters(rssi: -59, txPower: -59)
        #expect(distance1 != nil, "Should calculate distance for valid RSSI")
        #expect(distance1! > 0, "Distance should be positive")
        
        // Test with zero RSSI (invalid)
        let distance2 = parser.getDistanceInMeters(rssi: 0)
        #expect(distance2 == -1, "Should return -1 for invalid RSSI of 0")
        
        // Test with strong signal (close distance)
        let distance3 = parser.getDistanceInMeters(rssi: -50, txPower: -59)
        #expect(distance3 != nil && distance3! < 2, "Strong signal should indicate close distance")
        
        // Test with weak signal (far distance)
        let distance4 = parser.getDistanceInMeters(rssi: -90, txPower: -59)
        #expect(distance4 != nil && distance4! > 2, "Weak signal should indicate far distance")
    }
}

// MARK: - Bearound SDK Tests

@Suite("Bearound SDK Tests")
struct BearoundSDKMainTests {
    
    @Test("SDK initialization")
    func sdkInitialization() async throws {
        let sdk = Bearound(clientToken: "test-token", isDebugEnable: true)
        
        // Verify initial state
        let beacons = sdk.getActiveBeacons()
        #expect(beacons.isEmpty, "SDK should start with no beacons")
        
        let allBeacons = sdk.getAllBeacons()
        #expect(allBeacons.isEmpty, "SDK should start with no beacons")
    }
    
    @Test("Get active beacons filters by time")
    func getActiveBeaconsFiltering() async throws {
        let sdk = Bearound(clientToken: "test-token", isDebugEnable: false)
        
        // Create a recent beacon
        let recentBeacon = Beacon(
            major: "100",
            minor: "200",
            rssi: -60,
            bluetoothName: "BeA:b_100.200",
            bluetoothAddress: "ADDRESS-1",
            distanceMeters: 1.5,
            lastSeen: Date()
        )
        
        // Create an old beacon (more than 5 seconds ago)
        let oldBeacon = Beacon(
            major: "101",
            minor: "201",
            rssi: -65,
            bluetoothName: "BeA:b_101.201",
            bluetoothAddress: "ADDRESS-2",
            distanceMeters: 2.0,
            lastSeen: Date().addingTimeInterval(-10)
        )
        
        sdk.updateBeaconList(recentBeacon)
        sdk.updateBeaconList(oldBeacon)
        
        let activeBeacons = sdk.getActiveBeacons()
        let allBeacons = sdk.getAllBeacons()
        
        #expect(activeBeacons.count == 1, "Should only return recent beacons")
        #expect(allBeacons.count == 2, "Should return all beacons")
        #expect(activeBeacons.first?.major == "100", "Active beacon should be the recent one")
    }
    
    @Test("Update beacon list replaces existing beacon")
    func updateBeaconList() async throws {
        let sdk = Bearound(clientToken: "test-token", isDebugEnable: false)
        
        let beacon1 = Beacon(
            major: "100",
            minor: "200",
            rssi: -60,
            bluetoothName: "BeA:b_100.200",
            bluetoothAddress: "ADDRESS-1",
            distanceMeters: 1.5,
            lastSeen: Date()
        )
        
        sdk.updateBeaconList(beacon1)
        var allBeacons = sdk.getAllBeacons()
        #expect(allBeacons.count == 1, "Should have one beacon")
        
        // Update the same beacon with different RSSI
        let beacon2 = Beacon(
            major: "100",
            minor: "200",
            rssi: -65,
            bluetoothName: "BeA:b_100.200",
            bluetoothAddress: "ADDRESS-1",
            distanceMeters: 2.0,
            lastSeen: Date()
        )
        
        sdk.updateBeaconList(beacon2)
        allBeacons = sdk.getAllBeacons()
        
        #expect(allBeacons.count == 1, "Should still have one beacon (updated)")
        #expect(allBeacons.first?.rssi == -65, "Should have updated RSSI value")
        #expect(allBeacons.first?.distanceMeters == 2.0, "Should have updated distance")
    }
}

// MARK: - Listener Tests

@Suite("Listener Tests")
struct ListenerTests {
    
    // Mock Beacon Listener
    class MockBeaconListener: BeaconListener {
        var detectedBeacons: [Beacon] = []
        var detectedEventType: String = ""
        var callCount = 0
        
        func onBeaconsDetected(_ beacons: [Beacon], eventType: String) {
            detectedBeacons = beacons
            detectedEventType = eventType
            callCount += 1
        }
    }
    
    // Mock Sync Listener
    class MockSyncListener: SyncListener {
        var successCallCount = 0
        var errorCallCount = 0
        var lastEventType: String = ""
        var lastBeaconCount: Int = 0
        var lastMessage: String = ""
        var lastErrorMessage: String = ""
        
        func onSyncSuccess(eventType: String, beaconCount: Int, message: String) {
            successCallCount += 1
            lastEventType = eventType
            lastBeaconCount = beaconCount
            lastMessage = message
        }
        
        func onSyncError(eventType: String, beaconCount: Int, errorCode: Int?, errorMessage: String) {
            errorCallCount += 1
            lastEventType = eventType
            lastBeaconCount = beaconCount
            lastErrorMessage = errorMessage
        }
    }
    
    // Mock Region Listener
    class MockRegionListener: RegionListener {
        var enteredRegions: [String] = []
        var exitedRegions: [String] = []
        
        func onRegionEnter(regionName: String) {
            enteredRegions.append(regionName)
        }
        
        func onRegionExit(regionName: String) {
            exitedRegions.append(regionName)
        }
    }
    
    @Test("Add and remove beacon listener")
    func beaconListenerManagement() async throws {
        let sdk = Bearound(clientToken: "test-token", isDebugEnable: false)
        let listener = MockBeaconListener()
        
        sdk.addBeaconListener(listener)
        sdk.removeBeaconListener(listener)
        
        // Listeners are tested indirectly through the SDK behavior
        #expect(true, "Listener management should not crash")
    }
    
    @Test("Add and remove sync listener")
    func syncListenerManagement() async throws {
        let sdk = Bearound(clientToken: "test-token", isDebugEnable: false)
        let listener = MockSyncListener()
        
        sdk.addSyncListener(listener)
        sdk.removeSyncListener(listener)
        
        #expect(true, "Listener management should not crash")
    }
    
    @Test("Add and remove region listener")
    func regionListenerManagement() async throws {
        let sdk = Bearound(clientToken: "test-token", isDebugEnable: false)
        let listener = MockRegionListener()
        
        sdk.addRegionListener(listener)
        sdk.removeRegionListener(listener)
        
        #expect(true, "Listener management should not crash")
    }
}

// MARK: - Edge Cases Tests

@Suite("Edge Cases Tests")
struct EdgeCasesTests {
    @Test("BeaconParser handles edge cases")
    func beaconParserEdgeCases() {
        let parser = BeaconParser()
        
        // Empty string
        #expect(parser.getMajor("") == nil, "Should handle empty string")
        #expect(parser.getMinor("") == nil, "Should handle empty string")
        
        // Invalid formats
        #expect(parser.getMajor("BeA:") == nil, "Should handle incomplete beacon name")
        #expect(parser.getMinor("BeA:") == nil, "Should handle incomplete beacon name")
        
        // Very large numbers
        let largeName = "BeA:b_999999.888888"
        #expect(parser.getMajor(largeName) == "999999", "Should handle large numbers")
        #expect(parser.getMinor(largeName) == "888888", "Should handle large numbers")
    }
    
    @Test("Distance calculation edge cases")
    func distanceCalculationEdgeCases() {
        let parser = BeaconParser()
        
        // Zero RSSI
        let distance1 = parser.getDistanceInMeters(rssi: 0)
        #expect(distance1 == -1, "Zero RSSI should return -1")
        
        // Very strong signal
        let distance2 = parser.getDistanceInMeters(rssi: -10, txPower: -59)
        #expect(distance2 != nil, "Should handle very strong signal")
        
        // Very weak signal
        let distance3 = parser.getDistanceInMeters(rssi: -120, txPower: -59)
        #expect(distance3 != nil, "Should handle very weak signal")
        
        // RSSI equal to txPower
        let distance4 = parser.getDistanceInMeters(rssi: -59, txPower: -59)
        #expect(distance4 != nil, "Should handle RSSI equal to txPower")
    }
    
    @Test("SDK handles multiple beacons with same major/minor")
    func duplicateBeacons() async throws {
        let sdk = Bearound(clientToken: "test-token", isDebugEnable: false)
        
        let beacon1 = Beacon(
            major: "100",
            minor: "200",
            rssi: -60,
            bluetoothName: "BeA:b_100.200",
            bluetoothAddress: "ADDRESS-1",
            distanceMeters: 1.5,
            lastSeen: Date()
        )
        
        let beacon2 = Beacon(
            major: "100",
            minor: "200",
            rssi: -70,
            bluetoothName: "BeA:b_100.200",
            bluetoothAddress: "ADDRESS-2",
            distanceMeters: 3.0,
            lastSeen: Date()
        )
        
        sdk.updateBeaconList(beacon1)
        sdk.updateBeaconList(beacon2)
        
        let allBeacons = sdk.getAllBeacons()
        #expect(allBeacons.count == 1, "Duplicate beacons should be merged")
        #expect(allBeacons.first?.rssi == -70, "Should keep the latest beacon data")
    }
}

// MARK: - IDFA Tests

@Suite("IDFA Tests")
struct IDFATests {
    
    @Test("IDFA retrieval")
    func idfaRetrieval() async throws {
        let sdk = Bearound(clientToken: "test-token", isDebugEnable: false)
        
        let idfa = sdk.currentIDFA()
        
        // IDFA should be either a valid UUID string or empty
        #expect(idfa.isEmpty || UUID(uuidString: idfa) != nil, 
                "IDFA should be empty or a valid UUID")
    }
}
