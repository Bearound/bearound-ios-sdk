//
//  ViewController.swift
//  BeAround
//
//  Created by Arthur Sousa on 27/07/25.
//

import UIKit
import CoreLocation

class ViewController: UIViewController, CLLocationManagerDelegate {

    override func viewDidLoad() {
        super.viewDidLoad()
        Bearound(isDebugEnable: true).startServices()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        let locationManager = CLLocationManager()
        locationManager.delegate = self
        locationManager.requestAlwaysAuthorization()
    }


}

