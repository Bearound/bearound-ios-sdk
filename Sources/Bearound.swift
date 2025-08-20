//
//  Bearound.swift
//  beaconDetector
//
//  Created by Arthur Sousa on 19/06/25.
//

#if canImport(UIKit)
import UIKit
#endif
import AdSupport
import CoreLocation

enum RequestType: String {
    case enter = "enter"
    case exit = "exit"
    case lost = "lost"
}

public enum TimeIntervals: Double {
    case five = 5.0
    case ten = 10.0
    case fifthteen = 15.0
    case twenty = 20.0
    case twentyFive = 25.0
}

public enum LostBeaconsStorage: Int {
    case five = 5
    case ten = 10
    case fifthteen = 15
    case twenty = 20
    case twentyFive = 25
    case thirty = 30
    case thirtyFive = 35
    case forty = 40
    case fortyFive = 45
    case fifty = 50
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
    private var maximumLostBeaconsStorage: Int
    
    private lazy var scanner: BeaconScanner = {
        return BeaconScanner(delegate: self)
    }()
    
    private lazy var tracker: BeaconTracker = {
        return BeaconTracker(delegate: self)
    }()
    
    public init(clientToken: String = "", isDebugEnable: Bool) {
        self.beacons = []
        self.lostBeacons = []
        self.clientToken = clientToken
        self.debugger = DebuggerHelper(isDebugEnable)
        self.maximumLostBeaconsStorage = 10
        
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
    
    public func startServices() {
        self.scanner.startScanning()
        self.tracker.startTracking()
        self.debugger.defaultPrint("SDK initialization successful on version: \(DesignSystemVersion.current)")
    }
    
    public func stopServices() {
        self.scanner.stopScanning()
        self.tracker.stopTracking()
        self.stopTimer()
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    public func setUpdatingTime(_ seconds: TimeIntervals) {
        self.stopTimer()
        self.timer = Timer.scheduledTimer(
            timeInterval: seconds.rawValue,
            target: self,
            selector: #selector(syncWithAPI),
            userInfo: nil,
            repeats: true
        )
    }
    
    public func setMaximumLostBeaconsStorage(_ count: LostBeaconsStorage) {
        self.maximumLostBeaconsStorage = count.rawValue
    }
    
    @MainActor
    @objc private func syncWithAPI() {
        let activeBeacons = beacons.filter { beacon in
            Date().timeIntervalSince(beacon.lastSeen) <= 5
        }
        
        let exitBeacons = beacons.filter { beacon in
            Date().timeIntervalSince(beacon.lastSeen) >= 5
        }
        
        if !activeBeacons.isEmpty {
            print("[BeAroundSDK]: Beacons found: \(activeBeacons)")
            sendBeacons(type: .enter, activeBeacons)
        }
        
        if !exitBeacons.isEmpty {
            print("[BeAroundSDK]: Beacons exit: \(exitBeacons)")
            sendBeacons(type: .exit, exitBeacons)
        }
        
        if !lostBeacons.isEmpty {
            sendBeacons(type: .lost, lostBeacons)
        }
    }
    
    @MainActor
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
        
        let service = APIService()
        service.sendBeacons(
            PostData(
                deviceType: deviceType,
                clientToken: self.clientToken,
                sdkVersion: DesignSystemVersion.current,
                idfa: idfa.uuidString,
                eventType: type.rawValue,
                appState: appState,
                beacons: beacons
            )
        ) { result in
            switch result {
            case .success(_):
                self.debugger.printStatments(type: type)
                if type == .exit {
                    self.removeBeacons(beacons)
                }
            case .failure(_):
                if self.lostBeacons.count < self.maximumLostBeaconsStorage {
                    for beacon in beacons {
                        if !self.lostBeacons.contains(beacon) {
                            self.lostBeacons.append(beacon)
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
