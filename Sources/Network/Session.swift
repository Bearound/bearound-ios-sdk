//
//  Session.swift
//  beaconDetector
//
//  Created by Arthur Sousa on 22/06/25.
//

import Foundation

class Session {
    
    internal init() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 60 * 60
    }
    
    func data(with url: URL, and data: Data?) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpBody = data
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response)
    }
}
