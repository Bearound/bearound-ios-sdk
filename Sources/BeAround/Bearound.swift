//
//  Bearound.swift
//  beaconDetector
//
//  Created by Arthur Sousa on 19/06/25.
//

import UIKit
import AdSupport
import CoreLocation

enum RequestType: String {
    case enter = "enter"
    case exit = "exit"
    case lost = "lost"
}

protocol BeaconActionsDelegate {
    func updateBeaconList(_ beacon: Beacon)
}

public class Bearound: BeaconActionsDelegate {
    private var timer: Timer?
    private var clientToken: String
    private var beacons: Array<Beacon>
    private var lostBeacons: Array<Beacon>
    private var debugger: DebuggerHelper
    
    public init(clientToken: String, isDebugEnable: Bool) {
        self.beacons = []
        self.lostBeacons = []
        self.clientToken = clientToken
        self.debugger = DebuggerHelper(isDebugEnable)
        BeaconScanner.shared.delegate = self
        BeaconTracker.shared.delegate = self
        
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
    
    @objc private func syncWithAPI() {
        let activeBeacons = beacons.filter { beacon in
            Date().timeIntervalSince(beacon.lastSeen) <= 5
        }
        
        let exitBeacons = beacons.filter { beacon in
            Date().timeIntervalSince(beacon.lastSeen) >= 5
        }
        
        if !activeBeacons.isEmpty {
            sendBeacons(type: .enter, activeBeacons)
        }
        
        if !exitBeacons.isEmpty {
            sendBeacons(type: .exit, exitBeacons)
        }
        
        if !lostBeacons.isEmpty {
            sendBeacons(type: .lost, lostBeacons)
        }
    }
    
    private func sendBeacons(type: RequestType, _ beacons: Array<Beacon>) {
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
            do {
                try await APIService().sendBeacons(
                    PostData(
                        deviceType: deviceType,
                        idfa: idfa.uuidString,
                        eventType: type.rawValue,
                        appState: appState,
                        beacons: beacons
                    )
                )
                
                debugger.printStatments(type: type)
                
                if type == .exit {
                    removeBeacons(beacons)
                }
            } catch {
                if lostBeacons.count < 10 {
                    for beacon in beacons {
                        if !lostBeacons.contains(beacon) {
                            lostBeacons.append(beacon)
                        }
                    }
                }
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
