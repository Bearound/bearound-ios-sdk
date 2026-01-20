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
    
    @Test("Get or create device ID")
    func getOrCreateDeviceID() {
        // Clear existing ID first
        DeviceIdentifier.clearDeviceId()
        
        // Get device ID (should create new one)
        let deviceId1 = DeviceIdentifier.getDeviceId()
        
        #expect(!deviceId1.isEmpty)
        #expect(deviceId1.count > 0)
        
        // Get device ID again (should return same one)
        let deviceId2 = DeviceIdentifier.getDeviceId()
        
        #expect(deviceId1 == deviceId2)
    }
    
    @Test("Device ID persists across calls")
    func deviceIDPersists() {
        // Clear and create new ID
        DeviceIdentifier.clearDeviceId()
        let initialId = DeviceIdentifier.getDeviceId()
        
        // Call multiple times
        for _ in 0..<10 {
            let currentId = DeviceIdentifier.getDeviceId()
            #expect(currentId == initialId)
        }
    }
    
    @Test("Clear device ID")
    func clearDeviceID() {
        // Create device ID
        let deviceId1 = DeviceIdentifier.getDeviceId()
        #expect(!deviceId1.isEmpty)
        
        // Clear device ID
        DeviceIdentifier.clearDeviceId()
        
        // Get device ID again (should be different)
        let deviceId2 = DeviceIdentifier.getDeviceId()
        #expect(!deviceId2.isEmpty)
        #expect(deviceId1 != deviceId2)
    }
    
    @Test("Device ID format is UUID")
    func deviceIDFormatIsUUID() {
        DeviceIdentifier.clearDeviceId()
        let deviceId = DeviceIdentifier.getDeviceId()
        
        // Try to create UUID from string
        let uuid = UUID(uuidString: deviceId)
        
        #expect(uuid != nil)
    }
    
    @Test("Multiple instances share same device ID")
    func multipleInstancesShareSameID() {
        // Clear and get ID
        DeviceIdentifier.clearDeviceId()
        let id1 = DeviceIdentifier.getDeviceId()
        
        // In a static/singleton pattern, both calls should return same ID
        let id2 = DeviceIdentifier.getDeviceId()
        
        #expect(id1 == id2)
    }
}
