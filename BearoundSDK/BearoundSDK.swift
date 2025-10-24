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

// MARK: - Public Listener Protocols

/// Protocol for receiving beacon detection callbacks
public protocol BeaconListener: AnyObject {
    func onBeaconsDetected(_ beacons: [Beacon], eventType: String)
}

/// Protocol for monitoring API synchronization status
public protocol SyncListener: AnyObject {
    func onSyncSuccess(eventType: String, beaconCount: Int, message: String)
    func onSyncError(eventType: String, beaconCount: Int, errorCode: Int?, errorMessage: String)
}

/// Protocol for tracking beacon region entry/exit
public protocol RegionListener: AnyObject {
    func onRegionEnter(regionName: String)
    func onRegionExit(regionName: String)
}

// MARK: - Internal Delegate Protocol

protocol BeaconActionsDelegate {
    func updateBeaconList(_ beacon: Beacon)
}

public class Bearound: BeaconActionsDelegate {
    private var timer: Timer?
    private var clientToken: String
    private var beacons: Array<Beacon>
    private var lostBeacons: Array<Beacon>
    private var debugger: DebuggerHelper
    private var currentRegionState: String?
    
    // MARK: - Listener Collections
    private var beaconListeners: [BeaconListener] = []
    private var syncListeners: [SyncListener] = []
    private var regionListeners: [RegionListener] = []
    
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
        self.currentRegionState = nil
        
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
        beaconListeners.removeAll()
        syncListeners.removeAll()
        regionListeners.removeAll()
    }
    
    
    // MARK: - Public Listener Management Methods
    
    /// Add a beacon detection listener
    public func addBeaconListener(_ listener: BeaconListener) {
        beaconListeners.append(listener)
    }
    
    /// Remove a beacon detection listener
    public func removeBeaconListener(_ listener: BeaconListener) {
        beaconListeners.removeAll { $0 === listener }
    }
    
    /// Add a sync status listener
    public func addSyncListener(_ listener: SyncListener) {
        syncListeners.append(listener)
    }
    
    /// Remove a sync status listener
    public func removeSyncListener(_ listener: SyncListener) {
        syncListeners.removeAll { $0 === listener }
    }
    
    /// Add a region entry/exit listener
    public func addRegionListener(_ listener: RegionListener) {
        regionListeners.append(listener)
    }
    
    /// Remove a region entry/exit listener
    public func removeRegionListener(_ listener: RegionListener) {
        regionListeners.removeAll { $0 === listener }
    }
    
    /// Get currently detected beacons
    public func getActiveBeacons() -> [Beacon] {
        return beacons.filter { beacon in
            Date().timeIntervalSince(beacon.lastSeen) <= 5
        }
    }
    
    /// Get all detected beacons (including recently lost ones)
    public func getAllBeacons() -> [Beacon] {
        return beacons
    }
    
    public func startServices() {
        self.scanner.startScanning()
        self.tracker.startTracking()
        self.debugger.defaultPrint("SDK initialization successful on version: \(DesignSystemVersion.current)")
    }
    
    public func stopServices() {
        self.scanner.stopScanning()
        self.tracker.stopTracking()
        timer?.invalidate()
        timer = nil
    }
    
    @MainActor
    @objc private func syncWithAPI() {
        let activeBeacons = beacons.filter { beacon in
            Date().timeIntervalSince(beacon.lastSeen) <= 5
        }
        
        let exitBeacons = beacons.filter { beacon in
            Date().timeIntervalSince(beacon.lastSeen) >= 5
        }
        
        // Notify listeners about detected beacons
        if !activeBeacons.isEmpty {
            print("[BeAroundSDK]: Beacons found: \(activeBeacons)")
            notifyBeaconListeners(activeBeacons, eventType: "enter")
            sendBeacons(type: .enter, activeBeacons)
        }
        
        if !exitBeacons.isEmpty {
            print("[BeAroundSDK]: Beacons exit: \(exitBeacons)")
            notifyBeaconListeners(exitBeacons, eventType: "exit")
            sendBeacons(type: .exit, exitBeacons)
        }
        
        if !lostBeacons.isEmpty {
            notifyBeaconListeners(lostBeacons, eventType: "failed")
            sendBeacons(type: .lost, lostBeacons)
        }
        
        // Handle region state changes
        handleRegionStateChanges(activeBeacons: activeBeacons)
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
        ) { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(_):
                self.debugger.printStatments(type: type)
                
                // Notify sync listeners of success
                DispatchQueue.main.async {
                    self.notifySyncListeners(
                        success: true,
                        eventType: type.rawValue,
                        beaconCount: beacons.count,
                        message: "Successfully synced \(beacons.count) beacons",
                        errorCode: nil,
                        errorMessage: nil
                    )
                }
                
                if type == .exit {
                    self.removeBeacons(beacons)
                }
                
            case .failure(let error):
                // Notify sync listeners of error
                DispatchQueue.main.async {
                    self.notifySyncListeners(
                        success: false,
                        eventType: type.rawValue,
                        beaconCount: beacons.count,
                        message: nil,
                        errorCode: (error as NSError?)?.code,
                        errorMessage: error.localizedDescription
                    )
                }
                
                if self.lostBeacons.count < 10 {
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
    
    // MARK: - Private Helper Methods
    
    private func notifyBeaconListeners(_ beacons: [Beacon], eventType: String) {
        DispatchQueue.global(qos: .background).async {
            for listener in self.beaconListeners {
                listener.onBeaconsDetected(beacons, eventType: eventType)
            }
        }
    }
    
    private func notifySyncListeners(success: Bool, eventType: String, beaconCount: Int, message: String?, errorCode: Int?, errorMessage: String?) {
        for listener in syncListeners {
            if success {
                listener.onSyncSuccess(eventType: eventType, beaconCount: beaconCount, message: message ?? "")
            } else {
                listener.onSyncError(eventType: eventType, beaconCount: beaconCount, errorCode: errorCode, errorMessage: errorMessage ?? "Unknown error")
            }
        }
    }
    
    private func notifyRegionListeners(entered: Bool, regionName: String) {
        DispatchQueue.global(qos: .background).async {
            for listener in self.regionListeners {
                if entered {
                    listener.onRegionEnter(regionName: regionName)
                } else {
                    listener.onRegionExit(regionName: regionName)
                }
            }
        }
    }
    
    private func handleRegionStateChanges(activeBeacons: [Beacon]) {
        let regionName = "BeaconRegion"
        let hasActiveBeacons = !activeBeacons.isEmpty
        
        if hasActiveBeacons && currentRegionState != "entered" {
            currentRegionState = "entered"
            notifyRegionListeners(entered: true, regionName: regionName)
        } else if !hasActiveBeacons && currentRegionState == "entered" {
            currentRegionState = "exited"
            notifyRegionListeners(entered: false, regionName: regionName)
        }
    }
}
