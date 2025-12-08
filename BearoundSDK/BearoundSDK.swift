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
import AppTrackingTransparency

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
    
    // MARK: - Permissions
    /// Requests all necessary permissions used by the SDK (App Tracking Transparency for IDFA and Location permissions for beacon scanning).
    /// - Parameters:
    ///   - completion: Called on the main queue with the resulting statuses when using the completion-based API.
    /// - Note: On iOS 14.5+, ATT authorization is requested; on earlier systems, it is skipped. Location permission is delegated to the internal scanner if needed.
    @available(iOS 13.0, *)
    public func requestPermissions() async {
        await requestAppTrackingTransparencyIfNeeded()
        // If your scanner needs to request location permissions explicitly, expose and call it here.
        // For now, we assume `BeaconScanner` handles location authorization on start.
    }

    /// Completion-based variant for codebases not using async/await.
    public func requestPermissions(completion: (() -> Void)? = nil) {
        if #available(iOS 14.5, *) {
            ATTrackingManager.requestTrackingAuthorization { _ in
                DispatchQueue.main.async {
                    completion?()
                }
            }
        } else {
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    @available(iOS 13.0, *)
    private func requestAppTrackingTransparencyIfNeeded() async {
        if #available(iOS 14.5, *) {
            let status = ATTrackingManager.trackingAuthorizationStatus
            if status == .notDetermined {
                _ = await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    ATTrackingManager.requestTrackingAuthorization { _ in
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Safe accessor for IDFA string. Returns empty string if not authorized or unavailable.
    public func currentIDFA() -> String {
        // On iOS 14+, only return IDFA if tracking is authorized
        if #available(iOS 14, *) {
            guard ATTrackingManager.trackingAuthorizationStatus == .authorized else {
                return ""
            }
            // Even when authorized, ASIdentifierManager still provides the IDFA value
            return ASIdentifierManager.shared().advertisingIdentifier.uuidString
        } else {
            // On iOS versions prior to 14, return the IDFA directly
            return ASIdentifierManager.shared().advertisingIdentifier.uuidString
        }
    }
    
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
        
        // Mark warm start after the first initialization
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            DeviceInfoService.shared.markWarmStart()
        }
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
    
    /// Creates a complete ingest payload with device info and scan context
    /// - Parameters:
    ///   - beacons: Array of beacons to include in the payload
    ///   - sdkVersion: SDK version (defaults to current version)
    /// - Returns: IngestPayload ready to be sent to the API
    public func createIngestPayload(
        for beacons: [Beacon],
        sdkVersion: String = BeAroundSDKConfig.version
    ) async -> IngestPayload {
        // Get SDK info
        let sdkInfo = DeviceInfoService.shared.getSDKInfo(version: sdkVersion)
        
        // Get device info
        let deviceInfo = await DeviceInfoService.shared.getUserDeviceInfo()
        
        // Convert beacons to beacon payloads
        let beaconPayloads = beacons.map { beacon in
            beacon.toBeaconPayload()
        }
        
        // Create scan context from the first beacon (or use default values)
        let scanContext: ScanContext
        if let firstBeacon = beacons.first {
            scanContext = DeviceInfoService.shared.createScanContext(
                rssi: firstBeacon.rssi,
                txPower: -59, // Default txPower, pode ser customizado
                approxDistanceMeters: firstBeacon.distanceMeters
            )
        } else {
            // Default scan context if no beacons
            scanContext = DeviceInfoService.shared.createScanContext(
                rssi: 0,
                txPower: nil,
                approxDistanceMeters: nil
            )
        }
        
        return IngestPayload(
            beacons: beaconPayloads,
            sdk: sdkInfo,
            userDevice: deviceInfo,
            scanContext: scanContext
        )
    }
    
    /// Sends beacons using the new ingest payload format
    public func sendBeaconsWithFullInfo(
        _ beacons: [Beacon],
        completion: @escaping (Result<Data, Error>) -> Void
    ) async {
        let payload = await createIngestPayload(for: beacons)
        
        let service = APIService()
        service.sendIngestPayload(payload) { result in
            completion(result)
        }
    }
    
    /// Call `requestPermissions()` before starting services to ensure proper authorization.
    public func startServices() {
        self.scanner.startScanning()
        self.tracker.startTracking()
        
        // Configure Bluetooth state provider
        DeviceInfoService.shared.setBluetoothStateProvider { [weak self] in
            return self?.scanner.getCBManagerState() ?? .unknown
        }
        
        self.debugger.defaultPrint("SDK initialization successful on version: \(BeAroundSDKConfig.version)")
    }
    
    public func stopServices() {
        self.scanner.stopScanning()
        self.tracker.stopTracking()
        timer?.invalidate()
        timer = nil
    }
    
    @objc private func syncWithAPI() {
        Task { @MainActor in
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
                await sendBeacons(type: .enter, activeBeacons)
            }
            
            if !exitBeacons.isEmpty {
                print("[BeAroundSDK]: Beacons exit: \(exitBeacons)")
                notifyBeaconListeners(exitBeacons, eventType: "exit")
                await sendBeacons(type: .exit, exitBeacons)
            }
            
            if !lostBeacons.isEmpty {
                notifyBeaconListeners(lostBeacons, eventType: "failed")
                await sendBeacons(type: .lost, lostBeacons)
            }
            
            // Handle region state changes
            handleRegionStateChanges(activeBeacons: activeBeacons)
        }
    }
    
    private func sendBeacons(type: RequestType, _ beacons: Array<Beacon>) async {
        // Create the ingest payload with full device info
        let payload = await createIngestPayload(for: beacons)
        
        let service = APIService()
        service.sendIngestPayload(payload) { [weak self] result in
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

