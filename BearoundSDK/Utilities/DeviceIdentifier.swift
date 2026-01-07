//
//  DeviceIdentifier.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import AdSupport
import AppTrackingTransparency
import Foundation
import UIKit

class DeviceIdentifier {
    private static let keychainKey = "io.bearound.sdk.deviceId"

    static func getDeviceId() -> String {
        if let idfa = getIDFA() {
            print("[BeAroundSDK] Using IDFA as device ID")
            return idfa
        }

        if let keychainId = getKeychainUUID() {
            print("[BeAroundSDK] Using Keychain UUID as device ID")
            return keychainId
        }

        let idfv = getIDFV()
        print("[BeAroundSDK] Using IDFV as device ID")

        KeychainHelper.save(idfv, forKey: keychainKey)

        return idfv
    }

    static func getDeviceIdType() -> String {
        if getIDFA() != nil {
            "idfa"
        } else if getKeychainUUID() != nil {
            "keychain_uuid"
        } else {
            "idfv"
        }
    }

    private static func getIDFA() -> String? {
        if #available(iOS 14, *) {
            guard ATTrackingManager.trackingAuthorizationStatus == .authorized else {
                return nil
            }
        } else {
            guard ASIdentifierManager.shared().isAdvertisingTrackingEnabled else {
                return nil
            }
        }

        let idfa = ASIdentifierManager.shared().advertisingIdentifier
        let idfaString = idfa.uuidString

        guard idfaString != "00000000-0000-0000-0000-000000000000" else {
            return nil
        }

        return idfaString
    }

    private static func getKeychainUUID() -> String? {
        if let existingId = KeychainHelper.retrieve(forKey: keychainKey) {
            return existingId
        }

        let newId = UUID().uuidString
        if KeychainHelper.save(newId, forKey: keychainKey) {
            return newId
        }

        return nil
    }

    private static func getIDFV() -> String {
        UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    }
}

