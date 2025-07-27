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
    
    func sendBeacons(_ postData: PostData, completion: @escaping (Result<Data, Error>) -> Void) {
        
        guard let url = URL(string: "https://api.bearound.io/ingest") else {
            completion(.failure(NSError(domain: "InvalidURL", code: 0, userInfo: nil)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            let jsonData = try JSONEncoder().encode(postData)
            request.httpBody = jsonData
        } catch {
            completion(.failure(error))
            return
        }
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            
            guard let data = data else {
                completion(.failure(NSError(domain: "NoData", code: 0, userInfo: nil)))
                return
            }
            
            completion(.success(data))
        }
        
        task.resume()
    }
}
