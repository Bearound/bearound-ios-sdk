//
//  Bearound.swift
//  beaconDetector
//
//  Created by Arthur Sousa on 19/06/25.
//

import UIKit
import AdSupport
import CoreLocation

protocol BeaconActionsDelegate {
    func updateBeaconList(_ beacon: Beacon)
}

public class Bearound: BeaconActionsDelegate {
    private var timer: Timer?
    private var clientToken: String
    private var beacons: Array<Beacon>
    
    public init(clientToken: String) {
        self.beacons = []
        self.clientToken = clientToken
        BeaconScanner.shared.delegate = self
        BeaconTracker.shared.delegate = self
        
        self.timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            self.syncWithAPI()
        }
    }
    
    deinit {
        timer?.invalidate()
        timer = nil
    }
    
    private func syncWithAPI() {
        let activeBeacons = beacons.filter { beacon in
            Date().timeIntervalSince(beacon.lastSeen) <= 5
        }
        
        let exitBeacons = beacons.filter { beacon in
            Date().timeIntervalSince(beacon.lastSeen) >= 5
        }
        
        if !activeBeacons.isEmpty {
            sendBeacons(isRemoving: false, activeBeacons)
        }
        
        if !exitBeacons.isEmpty {
            sendBeacons(isRemoving: true, exitBeacons)
        }
    }
    
    private func sendBeacons(isRemoving: Bool, _ beacons: Array<Beacon>) {
        let deviceType = "iOS"
        let idfa = ASIdentifierManager.shared().advertisingIdentifier
        let appState = {
            switch UIApplication.shared.applicationState {
            case .active: return "foreground"
            case .background: return "background"
            case .inactive: return "inactive"
            @unknown default: return "unknown"
            }
        }()
        
        Task {
            try await APIService().sendBeacons(
                PostData(
                    deviceType: deviceType,
                    idfa: idfa.uuidString,
                    eventType: isRemoving ? "exit" : "enter",
                    appState: appState,
                    beacons: beacons
                )
            )
            
            if isRemoving {
                removeBeacons(beacons)
            }
        }
    }
    
    func updateBeaconList(_ beacon: Beacon) {
        if let index = beacons.firstIndex(of: beacon) {
            beacons[index] = beacon
        } else {
            beacons.append(beacon)
        }
    }
    
    func removeBeacons(_ beacons: Array<Beacon>) {
        for beacon in beacons {
            self.beacons.removeAll { $0 == beacon }
        }
    }
}
