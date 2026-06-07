//
//  UserProperties.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import Foundation

public struct UserProperties {
    public var internalId: String?

    public var email: String?

    public var name: String?

    public var customProperties: [String: String]

    public init(
        internalId: String? = nil,
        email: String? = nil,
        name: String? = nil,
        customProperties: [String: String] = [:]
    ) {
        self.internalId = internalId
        self.email = email
        self.name = name
        self.customProperties = customProperties
    }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = customProperties

        if let internalId {
            dict["internalId"] = internalId
        }
        if let email {
            dict["email"] = email
        }
        if let name {
            dict["name"] = name
        }

        return dict
    }

    var hasProperties: Bool {
        internalId != nil || email != nil || name != nil || !customProperties.isEmpty
    }

    /// Returns a copy with `other`'s non-nil fields overriding self; custom keys are merged.
    /// Lets identity set at `configure()` survive a later partial `setUserProperties` update.
    func merging(_ other: UserProperties) -> UserProperties {
        UserProperties(
            internalId: other.internalId ?? internalId,
            email: other.email ?? email,
            name: other.name ?? name,
            customProperties: customProperties.merging(other.customProperties) { _, new in new }
        )
    }
}

