//
//  SDKInfo.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import Foundation

struct SDKInfo {
    let version: String
    let platform: String
    let appId: String
    let build: Int
    let technology: String

    init(version: String = BeAroundSDK.version, appId: String, build: Int, technology: String = "ios-native") {
        self.version = version
        platform = "ios"
        self.appId = appId
        self.build = build
        self.technology = technology
    }
}

