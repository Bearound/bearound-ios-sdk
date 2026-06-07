//
//  APNSEnvironment.swift
//  BearoundSDK
//
//  Created by Bearound on 04/06/26.
//

import Foundation

/// APNs environment (`sandbox`/`production`), read from the `aps-environment` entitlement.
enum APNSEnvironment {
    static func current() -> String {
        #if DEBUG
        return "sandbox"
        #else
        // App Store builds strip the embedded profile → production.
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .isoLatin1),
              let keyRange = raw.range(of: "aps-environment") else {
            return "production"
        }
        let tail = raw[keyRange.upperBound...]
        let dev = tail.range(of: "development")?.lowerBound
        let prod = tail.range(of: "production")?.lowerBound
        switch (dev, prod) {
        case let (dev?, prod?): return dev < prod ? "sandbox" : "production"
        case (.some, .none): return "sandbox"
        default: return "production"
        }
        #endif
    }
}
