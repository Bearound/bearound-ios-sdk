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

@MainActor
public class Bearound: BeaconActionsDelegate {
    
    // MARK: - Singleton
    private static var _shared: Bearound?
    private static let lock = NSLock()
    
    /// Shared instance of the SDK. Must be configured before use.
    public static var shared: Bearound {
        get {
            lock.lock()
            defer { lock.unlock() }
            
            guard let instance = _shared else {
                fatalError("Bearound SDK must be configured before use. Call Bearound.configure(clientToken:isDebugEnable:) first.")
            }
            return instance
        }
    }
    
    // MARK: - Properties
    private var timer: Timer?
    private var clientToken: String
    private var beacons: Array<Beacon>
    private var lostBeacons: Array<Beacon>
    private var debugger: DebuggerHelper
    private var currentRegionState: String?
    private var isScanning: Bool = false
    
    private var syncInterval: SyncInterval = .time20
    private var backupSize: BackupSize = .size40
    
    // MARK: - Listener Collections
    private var beaconListeners: [BeaconListener] = []
    private var syncListeners: [SyncListener] = []
    private var regionListeners: [RegionListener] = []
    
    private lazy var scanner: BeaconScanner = {
        return BeaconScanner(delegate: self, debugger: self.debugger)
    }()
    
    private lazy var tracker: BeaconTracker = {
        return BeaconTracker(delegate: self, debugger: self.debugger)
    }()
    
    // MARK: - Configuration
    
    /// Configures the SDK with the required client token. Must be called before using the SDK.
    /// - Parameters:
    ///   - clientToken: Your API client token
    ///   - isDebugEnable: Enable debug logging
    /// - Returns: The configured SDK instance
    /// - Note: This method can only be called once. Subsequent calls will return the existing instance.
    @discardableResult
    public static func configure(clientToken: String, isDebugEnable: Bool) -> Bearound {
        lock.lock()
        defer { lock.unlock() }
        
        if let existing = _shared {
            // Use Swift.print for warning since debugger not available yet
            Swift.print("[BeAroundSDK] Warning: SDK already configured. Returning existing instance.")
            return existing
        }
        
        let instance = Bearound(clientToken: clientToken, isDebugEnable: isDebugEnable)
        _shared = instance
        return instance
    }
    
    /// Resets the SDK instance. Use with caution - typically only needed for testing.
    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        _shared?.stopServices()
        _shared = nil
    }
    
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
                completion?()
            }
        } else {
            completion?()
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
    
    // MARK: - SDK Configuration Methods
    
    /// Configura o intervalo de sincronização com a API
    /// - Parameter interval: Intervalo predefinido (5-60 segundos)
    public func setSyncInterval(_ interval: SyncInterval) {
        guard interval != syncInterval else {
            debugger.defaultPrint("Sync interval already set to \(interval.description)")
            return
        }
        
        syncInterval = interval
        debugger.defaultPrint("Sync interval changed to \(interval.description)")
        
        if isScanning {
            recreateTimer()
        }
    }
    
    /// Obtém o intervalo atual de sincronização
    /// - Returns: Intervalo de sincronização configurado
    public func getSyncInterval() -> SyncInterval {
        return syncInterval
    }
    
    /// Configura o tamanho máximo do backup de beacons perdidos
    /// - Parameter size: Tamanho predefinido (5-50 beacons)
    public func setBackupSize(_ size: BackupSize) {
        backupSize = size
        debugger.defaultPrint("Backup size set to \(size.description)")
        
        if lostBeacons.count > size.count {
            let overflow = lostBeacons.count - size.count
            lostBeacons.removeFirst(overflow)
            debugger.defaultPrint("Trimmed \(overflow) beacons from backup to fit new size")
        }
    }
    
    /// Obtém o tamanho configurado do backup
    /// - Returns: Tamanho máximo do backup
    public func getBackupSize() -> BackupSize {
        return backupSize
    }
    
    /// Obtém o número atual de beacons no backup
    /// - Returns: Quantidade de beacons aguardando reenvio
    public func getLostBeaconsCount() -> Int {
        return lostBeacons.count
    }
    
    private func recreateTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            timeInterval: syncInterval.seconds,
            target: self,
            selector: #selector(syncWithAPI),
            userInfo: nil,
            repeats: true
        )
        debugger.defaultPrint("Timer recreated with interval: \(syncInterval.seconds)s")
    }
    
    // MARK: - Initialization
    
    internal init(clientToken: String, isDebugEnable: Bool) {
        self.beacons = []
        self.lostBeacons = []
        self.clientToken = clientToken
        self.debugger = DebuggerHelper(isDebugEnable)
        self.currentRegionState = nil
        
        self.timer = Timer.scheduledTimer(
            timeInterval: syncInterval.seconds,
            target: self,
            selector: #selector(syncWithAPI),
            userInfo: nil,
            repeats: true
        )
        
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
        
        // Convert beacons to beacon payloads (filter out invalid beacons)
        let beaconPayloads = beacons.compactMap { beacon in
            beacon.toBeaconPayload()
        }
        
        // Create scan context
        let scanContext = DeviceInfoService.shared.createScanContext()
        
        return IngestPayload(
            clientToken: self.clientToken,
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
        
        let service = APIService(debugger: self.debugger)
        service.sendIngestPayload(payload) { result in
            completion(result)
        }
    }
    
    /// Call `requestPermissions()` before starting services to ensure proper authorization.
    public func startServices() {
        guard !isScanning else {
            debugger.defaultPrint("Warning: Services already running. Ignoring startServices() call.")
            return
        }
        
        isScanning = true
        
        if timer == nil {
            timer = Timer.scheduledTimer(
                timeInterval: syncInterval.seconds,
                target: self,
                selector: #selector(syncWithAPI),
                userInfo: nil,
                repeats: true
            )
            debugger.defaultPrint("Timer created with interval: \(syncInterval.seconds)s")
        }
        
        self.scanner.startScanning()
        
        debugger.defaultPrint("⚠️ BeaconTracker DISABLED (temporary test)")
        
        DeviceInfoService.shared.setBluetoothStateProvider { [weak self] in
            return self?.scanner.getCBManagerState() ?? .unknown
        }
        
        self.debugger.defaultPrint("SDK services started on version: \(BeAroundSDKConfig.version)")
    }
    
    public func stopServices() {
        guard isScanning else {
            debugger.defaultPrint("Warning: Services not running. Ignoring stopServices() call.")
            return
        }
        
        isScanning = false
        self.scanner.stopScanning()
        
        debugger.defaultPrint("⚠️ BeaconTracker DISABLED (temporary test)")
        
        timer?.invalidate()
        timer = nil
        
        debugger.defaultPrint("SDK services stopped")
    }
    
    /// Check if scanning is currently active
    public func isCurrentlyScanning() -> Bool {
        return isScanning
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
                debugger.defaultPrint("Beacons found: \(activeBeacons)")
                notifyBeaconListeners(activeBeacons, eventType: "enter")
                await sendBeacons(type: .enter, activeBeacons)
            }
            
            if !exitBeacons.isEmpty {
                debugger.defaultPrint("Beacons exit: \(exitBeacons)")
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
        let validBeacons = filterValidBeacons(beacons)
        
        guard !validBeacons.isEmpty else {
            debugger.defaultPrint("No valid beacons to send for \(type.rawValue)")
            return
        }
        
        let payload = await createIngestPayload(for: validBeacons)
        
        let service = APIService(debugger: self.debugger)
        service.sendIngestPayload(payload) { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(_):
                self.debugger.printStatments(type: type)
                
                self.notifySyncListeners(
                    success: true,
                    eventType: type.rawValue,
                    beaconCount: validBeacons.count,
                    message: "Successfully synced \(validBeacons.count) beacons",
                    errorCode: nil,
                    errorMessage: nil
                )
                
                if type == .lost && !self.lostBeacons.isEmpty {
                    let clearedCount = self.lostBeacons.count
                    self.lostBeacons.removeAll()
                    self.debugger.defaultPrint("✅ Cleared \(clearedCount) lost beacons after successful retry")
                }
                
                if type == .exit {
                    self.removeBeacons(validBeacons)
                }
                
            case .failure(let error):
                self.notifySyncListeners(
                    success: false,
                    eventType: type.rawValue,
                    beaconCount: validBeacons.count,
                    message: nil,
                    errorCode: (error as NSError?)?.code,
                    errorMessage: error.localizedDescription
                )
                
                let availableSpace = self.backupSize.count - self.lostBeacons.count
                
                if availableSpace > 0 {
                    let beaconsToAdd = validBeacons.filter { !self.lostBeacons.contains($0) }
                    let addCount = min(beaconsToAdd.count, availableSpace)
                    
                    self.lostBeacons.append(contentsOf: beaconsToAdd.prefix(addCount))
                    
                    self.debugger.defaultPrint("📦 Backup: \(self.lostBeacons.count)/\(self.backupSize.count) beacons")
                } else {
                    self.debugger.defaultPrint("⚠️ Backup full! Discarding \(validBeacons.count) beacons")
                }
            }
        }
    }
    
    func updateBeaconList(_ beacon: Beacon) {
        if let existingIndex = findBeaconIndex(for: beacon) {
            mergeBeaconData(at: existingIndex, with: beacon)
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
    
    private func filterValidBeacons(_ beacons: [Beacon]) -> [Beacon] {
        return beacons.filter { beacon in
            beacon.rssi != 0 && 
            beacon.rssi >= -120 && 
            beacon.rssi <= -1
        }
    }
    
    private func findBeaconIndex(for beacon: Beacon) -> Int? {
        return beacons.firstIndex(where: { $0.bluetoothName == beacon.bluetoothName })
    }
    
    private func mergeBeaconData(at index: Int, with newBeacon: Beacon) {
        var existing = beacons[index]
        
        existing.rssi = newBeacon.rssi
        existing.lastSeen = newBeacon.lastSeen
        
        if let newDistance = newBeacon.distanceMeters {
            existing.distanceMeters = newDistance
        }
        
        if let newAddress = newBeacon.bluetoothAddress, !newAddress.isEmpty {
            existing.bluetoothAddress = newAddress
        }
        
        beacons[index] = existing
    }
    
    private func notifyBeaconListeners(_ beacons: [Beacon], eventType: String) {
        for listener in self.beaconListeners {
            listener.onBeaconsDetected(beacons, eventType: eventType)
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
        for listener in self.regionListeners {
            if entered {
                listener.onRegionEnter(regionName: regionName)
            } else {
                listener.onRegionExit(regionName: regionName)
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

