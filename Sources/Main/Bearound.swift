//
//  Bearound.swift
//  beaconDetector
//
//  Created by Arthur Sousa on 19/06/25.
//

#if canImport(UIKit)
import UIKit
#endif

protocol BeaconActionsDelegate {
    func updateBeaconList(_ beacon: Beacon)
}

public class Bearound: BeaconActionsDelegate {
    //MARK: - Local variables
    internal var timer: Timer?
    internal var clientToken: String
    internal var beacons: Array<Beacon>
    internal var lostBeacons: Array<Beacon>
    internal var debugger: DebuggerHelper
    internal var maximumLostBeaconsStorage: Int
    internal var requestsMade: Array<RequestModel>
    
    internal lazy var scanner: BeaconScanner = {
        return BeaconScanner(delegate: self)
    }()
    
    internal lazy var tracker: BeaconTracker = {
        return BeaconTracker(delegate: self)
    }()
    
    //MARK: - Initialization
    public init(clientToken: String) {
        self.beacons = []
        self.lostBeacons = []
        self.clientToken = clientToken
        self.debugger = DebuggerHelper(true)
        self.maximumLostBeaconsStorage = 10
        self.requestsMade = []
        
        self.timer = Timer.scheduledTimer(
            timeInterval: 5.0,
            target: self,
            selector: #selector(syncWithAPI),
            userInfo: nil,
            repeats: true
        )
    }
    
    deinit {
        timer?.invalidate()
        timer = nil
    }
    
    //MARK: Scanner/Tracker Delegate
    internal func getLastRequests() -> Array<RequestModel> {
        return self.requestsMade
    }
    
    internal func updateBeaconList(_ beacon: Beacon) {
        self.parseFoundBeacon(beacon)
    }
}
