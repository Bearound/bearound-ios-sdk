//
//  ViewController.swift
//  BeAroundExample
//
//  Created by Arthur Sousa on 04/08/25.
//

import UIKit
import BeAround
import CoreLocation

class ViewController: UIViewController, CLLocationManagerDelegate {

    override func viewDidLoad() {
        super.viewDidLoad()
        
        let locationManager = CLLocationManager()
        locationManager.delegate = self
        locationManager.requestAlwaysAuthorization()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        Bearound(isDebugEnable: true).startServices()
    }


}

