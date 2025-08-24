//
//  ViewController+TableView.swift
//  BeAround
//
//  Created by Arthur Sousa on 20/08/25.
//

import UIKit

extension ViewController: UITableViewDelegate, UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.requests.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "tableViewCell", for: indexPath) as! TableViewCell
        
        guard let endpointLabel =  self.requests[indexPath.row].endpoint else { return cell }
        guard let statusCodeLabel = self.requests[indexPath.row].statusCode else { return cell }
        cell.endpointLabel?.text = "Endpoint: " + endpointLabel
        cell.statusCodeLabel?.text = "Status Code: " + String(statusCodeLabel)
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        if let detalheVC = storyboard.instantiateViewController(withIdentifier: "detailViewController") as? DetailViewController {
            detalheVC.detailItem = self.requests[indexPath.row]
            navigationController?.pushViewController(detalheVC, animated: true)
        }
    }
}
