//
//  RequestModel.swift
//  BeAround
//
//  Created by Arthur Sousa on 20/08/25.
//

import Foundation

internal struct RequestModel: Error {
    var error: Error?
    
    //Request
    var httpMethod: String?
    var endpoint: String?
    var requestHeaders: [String: String]?
    var requestBody: PostData
    var statusCode: Int?
}

struct PostData: Codable {
    let deviceType: String
    let clientToken: String
    let sdkVersion: String
    let idfa: String?
    let eventType: String
    let appState: String
    let beacons: Array<Beacon>
    
    func toString() -> String? {
        do {
            let jsonData = try JSONEncoder().encode(self)
            return String(data: jsonData, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
