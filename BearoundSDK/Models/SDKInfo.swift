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

    init(version: String = "2.2.0", appId: String, build: Int) {
        self.version = version
        platform = "ios"
        self.appId = appId
        self.build = build
    }
}

