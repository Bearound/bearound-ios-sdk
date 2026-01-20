//
//  DeviceIdentifierTests.swift
//  BearoundSDKTests
//
//  Tests for device identifier generation and persistence
//

import Foundation
import Testing

@testable import BearoundSDK

@Suite("DeviceIdentifier Tests")
struct DeviceIdentifierTests {
    
    @Test("Get device ID returns non-empty string")
    func getDeviceIDReturnsNonEmpty() {
        // Get device ID
        let deviceId = DeviceIdentifier.getDeviceId()
        
        #expect(!deviceId.isEmpty)
        #expect(deviceId.count > 0)
    }
    
    @Test("Device ID persists across calls")
    func deviceIDPersists() {
        // Get initial ID
        let initialId = DeviceIdentifier.getDeviceId()
        
        // Call multiple times - should always return same ID
        for _ in 0..<10 {
            let currentId = DeviceIdentifier.getDeviceId()
            #expect(currentId == initialId)
        }
    }
    
    @Test("Device ID format is UUID")
    func deviceIDFormatIsUUID() {
        let deviceId = DeviceIdentifier.getDeviceId()
        
        // Try to create UUID from string
        let uuid = UUID(uuidString: deviceId)
        
        #expect(uuid != nil)
    }
    
    @Test("Get device ID type")
    func getDeviceIDType() {
        let idType = DeviceIdentifier.getDeviceIdType()
        
        // Should be one of the valid types
        let validTypes = ["idfa", "keychain_uuid", "idfv"]
        #expect(validTypes.contains(idType))
    }
    
    @Test("Device ID type consistency")
    func deviceIDTypeConsistency() {
        // Get type multiple times
        let type1 = DeviceIdentifier.getDeviceIdType()
        let type2 = DeviceIdentifier.getDeviceIdType()
        
        // Should always return same type
        #expect(type1 == type2)
    }
}
