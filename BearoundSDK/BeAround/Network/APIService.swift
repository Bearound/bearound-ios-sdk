//
//  APIService.swift
//  beaconDetector
//
//  Created by Arthur Sousa on 19/06/25.
//

import Foundation

// MARK: - API Service

class APIService {
    
    /// Envia beacons usando o formato de IngestPayload
    func sendIngestPayload(_ payload: IngestPayload, completion: @escaping (Result<Data, Error>) -> Void) {
        
        guard let url = URL(string: "https://ingest.bearound.io/ingest") else {
            completion(.failure(NSError(domain: "InvalidURL", code: 0, userInfo: nil)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .useDefaultKeys
            let jsonData = try encoder.encode(payload)
            request.httpBody = jsonData
            
            // Para debug, imprimir o JSON
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                print("[BeAroundSDK]: Sending ingest payload: \(jsonString)")
            }
        } catch {
            completion(.failure(error))
            return
        }
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let data = data else {
                completion(.failure(NSError(domain: "NoData", code: 0, userInfo: nil)))
                return
            }
            
            completion(.success(data))
        }
        
        task.resume()
    }
}
