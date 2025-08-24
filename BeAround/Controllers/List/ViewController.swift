//
//  ViewController.swift
//  BeAround
//
//  Created by Arthur Sousa on 27/07/25.
//

import UIKit
import CoreLocation
import AppTrackingTransparency

class ViewController: UIViewController, CLLocationManagerDelegate {
    
    //MARK: Outlets
    @IBOutlet weak var tableView: UITableView!
    
    //MARK: Local variables
    internal var beAroundSDK: Bearound!
    internal var requests: Array<RequestModel> = []

    //MARK: View life-cycle
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.tableView.delegate = self
        self.tableView.dataSource = self
        let timeInterval = TimeIntervals.five
        
        self.beAroundSDK = Bearound(clientToken: "")
        self.beAroundSDK.enableDebug()
        self.beAroundSDK.startServices()
        self.beAroundSDK.setUpdatingTime(timeInterval)
        self.beAroundSDK.setMaximumLostBeaconsStorage(.five)
        
        Timer.scheduledTimer(
            timeInterval: timeInterval.rawValue,
            target: self,
            selector: #selector(fetchData),
            userInfo: nil,
            repeats: true
        )
    }
    
    override func viewDidAppear(_ animated: Bool) {
        self.askForLocationPermission()
        self.askForTrackingPermission()
    }
    
    //MARK: Permissions
    private func askForLocationPermission() {
        let locationManager = CLLocationManager()
        locationManager.delegate = self
        locationManager.requestAlwaysAuthorization()
    }
    
    private func askForTrackingPermission() {
        ATTrackingManager.requestTrackingAuthorization { status in
            switch status {
            case .authorized:
                print("")
            case .denied:
                print("")
            case .notDetermined:
                print("")
            case .restricted:
                print("")
            @unknown default:
                break
            }
        }
    }
    
    // MARK: Loginc
    @objc private func fetchData() {
        if beAroundSDK.getLastRequests().count > 0 {
            self.requests = beAroundSDK.getLastRequests()
            self.tableView.reloadData()
        }
    }
}
