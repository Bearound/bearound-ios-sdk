//
//  UserPropertiesTests.swift
//  BearoundSDKTests
//
//  Tests for UserProperties model
//

import Testing
import Foundation
@testable import BearoundSDK

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
}

