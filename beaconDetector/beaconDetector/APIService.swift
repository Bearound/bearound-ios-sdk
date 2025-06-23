//
//  APIService.swift
//  beaconDetector
//
//  Created by Arthur Sousa on 19/06/25.
//

import Foundation

struct PostData: Codable {
       let deviceType: String
       let idfa: String?
       let eventType: String
       let appState: String
       let beacons: Array<Beacon>
}

class APIService {
    
    func sendBeacons(_ data: PostData) async throws {
        guard let url = URL(string: "https://api.bearound.io/ingest") else {
            throw URLError(.badURL)
        }
        
        do {
            let jsonData = try JSONEncoder().encode(data)
            let (data, response) = try await Session.shared.data(with: url, and: jsonData)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }
            
            print("Beacon registrado na API")
            
        } catch {
            throw URLError(.unknown)
        }
    }
}
