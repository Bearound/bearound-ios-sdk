//
//  KeychainHelperTests.swift
//  BearoundSDKTests
//
//  Tests for keychain storage utility
//

import Foundation
import Testing

@testable import BearoundSDK

@Suite("KeychainHelper Tests")
struct KeychainHelperTests {
    
    let testKey = "com.bearound.test.deviceid"
    
    @Test("Save and retrieve string from keychain")
    func saveAndRetrieveString() {
        let testValue = "test-device-id-123"
        
        // Save value
        let saveResult = KeychainHelper.save(key: testKey, data: testValue)
        #expect(saveResult == true)
        
        // Retrieve value
        if let retrievedValue: String = KeychainHelper.load(key: testKey) {
            #expect(retrievedValue == testValue)
        } else {
            Issue.record("Failed to retrieve value from keychain")
        }
    }
    
    @Test("Update existing keychain value")
    func updateExistingValue() {
        let initialValue = "initial-value"
        let updatedValue = "updated-value"
        
        // Save initial value
        _ = KeychainHelper.save(key: testKey, data: initialValue)
        
        // Update with new value
        let updateResult = KeychainHelper.save(key: testKey, data: updatedValue)
        #expect(updateResult == true)
        
        // Verify updated value
        if let retrievedValue: String = KeychainHelper.load(key: testKey) {
            #expect(retrievedValue == updatedValue)
        } else {
            Issue.record("Failed to retrieve updated value")
        }
    }
    
    @Test("Delete value from keychain")
    func deleteValue() {
        let testValue = "value-to-delete"
        
        // Save value
        _ = KeychainHelper.save(key: testKey, data: testValue)
        
        // Verify it exists
        let loadedValue: String? = KeychainHelper.load(key: testKey)
        #expect(loadedValue != nil)
        
        // Delete value
        let deleteResult = KeychainHelper.delete(key: testKey)
        #expect(deleteResult == true)
        
        // Verify it's gone
        let afterDelete: String? = KeychainHelper.load(key: testKey)
        #expect(afterDelete == nil)
    }
    
    @Test("Load non-existent key returns nil")
    func loadNonExistentKey() {
        let nonExistentKey = "com.bearound.test.nonexistent.key"
        
        // Delete if exists (cleanup)
        _ = KeychainHelper.delete(key: nonExistentKey)
        
        // Try to load
        let result: String? = KeychainHelper.load(key: nonExistentKey)
        
        #expect(result == nil)
    }
    
    @Test("Delete non-existent key succeeds")
    func deleteNonExistentKey() {
        let nonExistentKey = "com.bearound.test.another.nonexistent"
        
        // Delete non-existent key should succeed (no-op)
        let result = KeychainHelper.delete(key: nonExistentKey)
        
        // Should return true even if key doesn't exist
        #expect(result == true)
    }
    
    @Test("Save empty string")
    func saveEmptyString() {
        let emptyValue = ""
        
        let saveResult = KeychainHelper.save(key: testKey, data: emptyValue)
        #expect(saveResult == true)
        
        if let retrievedValue: String = KeychainHelper.load(key: testKey) {
            #expect(retrievedValue == "")
        } else {
            Issue.record("Failed to retrieve empty string")
        }
    }
    
    @Test("Save long string")
    func saveLongString() {
        // Create a long string (10KB)
        let longValue = String(repeating: "A", count: 10_000)
        
        let saveResult = KeychainHelper.save(key: testKey, data: longValue)
        #expect(saveResult == true)
        
        if let retrievedValue: String = KeychainHelper.load(key: testKey) {
            #expect(retrievedValue.count == 10_000)
            #expect(retrievedValue == longValue)
        } else {
            Issue.record("Failed to retrieve long string")
        }
    }
    
    @Test("Save special characters")
    func saveSpecialCharacters() {
        let specialValue = "Test™ 特殊 🎉 @#$%^&*()"
        
        let saveResult = KeychainHelper.save(key: testKey, data: specialValue)
        #expect(saveResult == true)
        
        if let retrievedValue: String = KeychainHelper.load(key: testKey) {
            #expect(retrievedValue == specialValue)
        } else {
            Issue.record("Failed to retrieve special characters")
        }
    }
}
