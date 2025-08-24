//
//  DetailViewController.swift
//  BeAround
//
//  Created by Arthur Sousa on 20/08/25.
//

import UIKit
import Foundation

class DetailViewController: UIViewController {
    
    var detailItem: RequestModel!
    
    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet weak var methodLabel: UILabel!
    @IBOutlet weak var endpointLabel: UILabel!
    @IBOutlet weak var requestHeaderLabel: UITextView!
    @IBOutlet weak var requestBodyLabel: UITextView!
    
    override func viewDidLoad() {
        guard let statusCode = detailItem.statusCode else { return }
        self.statusLabel.text = "Status code: " + String(statusCode)
        
        guard let httpMethod = detailItem.httpMethod else { return }
        self.methodLabel.text = "Method: " + httpMethod
        
        guard let endpoint = detailItem.endpoint else { return }
        self.endpointLabel.text = "Endpoint: " + endpoint
        
        guard let requestBody = detailItem.requestBody.toString() else { return }
        self.requestBodyLabel.text = "Body: " + requestBody
        
        guard let requestHeaders = detailItem.requestHeaders else { return }
        if let data = try? JSONSerialization.data(withJSONObject: requestHeaders, options: .prettyPrinted),
           let jsonString = String(data: data, encoding: .utf8) {
            self.requestHeaderLabel.text = "Headers: " + jsonString
        }
    }
}
