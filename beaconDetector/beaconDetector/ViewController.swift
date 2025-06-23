//
//  ViewController.swift
//  beaconDetector
//
//  Created by Arthur Sousa on 15/06/25.
//

import UIKit
import AdSupport
import AppTrackingTransparency

class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        let bearound = Bearound(clientToken: "")
        bearound.initServices()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }

}

