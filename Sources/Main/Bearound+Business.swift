//
//  Bearound+Business.swift
//  BeAround
//
//  Created by Arthur Sousa on 20/08/25.
//

#if canImport(UIKit)
import UIKit
#endif
import AdSupport

extension Bearound {
    @MainActor
    @objc internal func syncWithAPI() {
        let activeBeacons = extractActiveBeacons()
        let exitBeacons = extractExitBeacons()
        
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
    
    private func extractActiveBeacons() -> Array<Beacon> {
        return beacons.filter { beacon in
            Date().timeIntervalSince(beacon.lastSeen) <= 5
        }
    }
    
    private func extractExitBeacons() -> Array<Beacon> {
        return beacons.filter { beacon in
            Date().timeIntervalSince(beacon.lastSeen) >= 5
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
            case .success(let requestData):
                self.requestsMade.insert(requestData, at: 0)
                self.debugger.printStatments(type: type)
                if type == .exit {
                    self.removeBeacons(beacons)
                }
            case .failure(let requestData):
                self.requestsMade.insert(requestData, at: 0)
                self.debugger.printStatments(type: .error)
                if self.lostBeacons.count < self.maximumLostBeaconsStorage {
                    for beacon in beacons {
                        if !self.lostBeacons.contains(beacon) {
                            self.lostBeacons.insert(beacon, at: 0)
                        }
                    }
                }
            }
        }
    }
    
    internal func parseFoundBeacon(_ beacon: Beacon) {
        if let index = beacons.firstIndex(of: beacon) {
            beacons[index].rssi = beacon.rssi
            beacons[index].lastSeen = beacon.lastSeen
            if let name = beacon.bluetoothName {
                beacons[index].bluetoothName = name
            }
            if let address = beacon.bluetoothAddress {
                beacons[index].bluetoothAddress = address
            }
        } else {
            beacons.insert(beacon, at: 0)
        }
    }
    
    internal func removeBeacons(_ beacons: Array<Beacon>) {
        for beacon in beacons {
            self.beacons.removeAll { $0 == beacon }
        }
    }
}
