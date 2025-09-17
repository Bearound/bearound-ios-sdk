//
//  APIService.swift
//  beaconDetector
//
//  Created by Arthur Sousa on 19/06/25.
//

import Foundation

class APIService {
    
    func sendBeacons(_ postData: PostData, completion: @escaping (Result<RequestModel, RequestModel>) -> Void) {
        var requestModel = RequestModel(requestBody: postData)
        
        guard let url = URL(string: "https://ingest.bearound.io/ingest") else {
            requestModel.error = NSError(domain: "InvalidURL", code: 404, userInfo: nil)
            completion(.failure(requestModel))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let jsonData = try JSONEncoder().encode(postData)
            request.httpBody = jsonData
        } catch {
            requestModel.error = error
            completion(.failure(requestModel))
            return
        }
        
        requestModel.endpoint = url.absoluteString
        requestModel.httpMethod = "POST"
        requestModel.requestHeaders = request.allHTTPHeaderFields
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let httpResponse = response as? HTTPURLResponse else {
                requestModel.error = error ?? NSError(domain: "InvalidResponse", code: 502, userInfo: nil)
                completion(.failure(requestModel))
                return
            }
            guard let _ = data else {
                requestModel.error = error ?? NSError(domain: "NoData", code: 400, userInfo: nil)
                completion(.failure(requestModel))
                return
            }
            requestModel.statusCode = httpResponse.statusCode
            completion(.success(requestModel))
        }
        
        task.resume()
    }
}
