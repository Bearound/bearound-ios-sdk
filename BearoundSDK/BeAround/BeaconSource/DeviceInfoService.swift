//
//  DeviceInfoService.swift
//  beaconDetector
//
//  Created by Felipe Costa Araujo on 08/12/25.
//

#if canImport(UIKit)
import UIKit
#endif
import Foundation
import CoreLocation
import CoreBluetooth
import AdSupport
import AppTrackingTransparency
import Network
import CoreTelephony

// MARK: - Data Models

/// Representa as informações do SDK
public struct SDKInfo: Codable {
    let version: String
    let platform: String
    let appId: String?
    let build: Int?
    
    enum CodingKeys: String, CodingKey {
        case version
        case platform
        case appId
        case build
    }
}

/// Representa as informações do dispositivo do usuário
public struct UserDeviceInfo: Codable {
    let manufacturer: String
    let model: String
    let os: String
    let osVersion: String
    let sdkInt: Int?
    let timestamp: Int64
    let timezone: String
    let batteryLevel: Float
    let isCharging: Bool
    let powerSaveMode: Bool?
    let lowPowerMode: Bool?
    let bluetoothState: String
    let locationPermission: String
    let locationAccuracy: String?
    let notificationsPermission: String
    let networkType: String
    let wifiSSID: String?
    let wifiBSSID: String?
    let cellularGeneration: String?
    let isRoaming: Bool?
    let connectionMetered: Bool?
    let connectionExpensive: Bool?
    let ramTotalMb: Int64
    let ramAvailableMb: Int64
    let screenWidth: Int
    let screenHeight: Int
    let advertisingId: String?
    let adTrackingEnabled: Bool
    let appInForeground: Bool
    let appUptimeMs: Int64
    let coldStart: Bool
    
    enum CodingKeys: String, CodingKey {
        case manufacturer
        case model
        case os
        case osVersion
        case sdkInt
        case timestamp
        case timezone
        case batteryLevel
        case isCharging
        case powerSaveMode
        case lowPowerMode
        case bluetoothState
        case locationPermission
        case locationAccuracy
        case notificationsPermission
        case networkType
        case wifiSSID
        case wifiBSSID
        case cellularGeneration
        case isRoaming
        case connectionMetered
        case connectionExpensive
        case ramTotalMb
        case ramAvailableMb
        case screenWidth
        case screenHeight
        case advertisingId
        case adTrackingEnabled
        case appInForeground
        case appUptimeMs
        case coldStart
    }
}

/// Representa o contexto do scan de beacon
public struct ScanContext: Codable {
    let rssi: Int
    let txPower: Int?
    let approxDistanceMeters: Float?
    let scanSessionId: String
    let detectedAt: Int64
    
    enum CodingKeys: String, CodingKey {
        case rssi
        case txPower
        case approxDistanceMeters
        case scanSessionId
        case detectedAt
    }
}

// MARK: - Device Info Service

public class DeviceInfoService {
    
    // MARK: - Singleton
    public static let shared = DeviceInfoService()
    
    // MARK: - Private Properties
    private var appStartTime: Date
    private var isColdStart: Bool
    private var scanSessionId: String
    private var pathMonitor: NWPathMonitor?
    private var currentNetworkType: String = "none"
    private var currentConnectionExpensive: Bool = false
    private var bluetoothStateProvider: (() -> CBManagerState)?
    
    private init() {
        self.appStartTime = Date()
        self.isColdStart = true
        self.scanSessionId = UUID().uuidString
        self.setupNetworkMonitoring()
    }
    
    // MARK: - Public Methods
    
    /// Gera um novo ID de sessão de scan
    public func generateNewScanSession() {
        self.scanSessionId = UUID().uuidString
    }
    
    /// Marca que o cold start já passou
    public func markWarmStart() {
        self.isColdStart = false
    }
    
    /// Define o provider para obter o estado do Bluetooth
    public func setBluetoothStateProvider(_ provider: @escaping () -> CBManagerState) {
        self.bluetoothStateProvider = provider
    }
    
    /// Coleta todas as informações do SDK
    public func getSDKInfo(version: String = BeAroundSDKConfig.version) -> SDKInfo {
        return SDKInfo(
            version: version,
            platform: "ios",
            appId: Bundle.main.bundleIdentifier,
            build: getBuildNumber()
        )
    }
    
    /// Coleta todas as informações do dispositivo do usuário
    @MainActor
    public func getUserDeviceInfo() async -> UserDeviceInfo {
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        
        let notificationStatus = await getNotificationPermissionStatus()
        
        return UserDeviceInfo(
            manufacturer: getManufacturer(),
            model: getDeviceModel(),
            os: "ios",
            osVersion: getOSVersion(),
            sdkInt: nil, // iOS não usa sdkInt (apenas Android)
            timestamp: getCurrentTimestamp(),
            timezone: getTimezone(),
            batteryLevel: getBatteryLevel(),
            isCharging: isDeviceCharging(),
            powerSaveMode: nil, // iOS não tem power save mode (usa lowPowerMode)
            lowPowerMode: isLowPowerModeEnabled(),
            bluetoothState: getBluetoothState(),
            locationPermission: getLocationPermission(),
            locationAccuracy: getLocationAccuracy(),
            notificationsPermission: notificationStatus,
            networkType: currentNetworkType,
            wifiSSID: nil, // Requer entitlement especial, retorna nil por padrão
            wifiBSSID: nil, // Requer entitlement especial, retorna nil por padrão
            cellularGeneration: getCellularGeneration(),
            isRoaming: isRoaming(),
            connectionMetered: nil, // iOS não expõe essa informação diretamente
            connectionExpensive: currentConnectionExpensive,
            ramTotalMb: getTotalRAM(),
            ramAvailableMb: getAvailableRAM(),
            screenWidth: getScreenWidth(),
            screenHeight: getScreenHeight(),
            advertisingId: getAdvertisingId(),
            adTrackingEnabled: isAdTrackingEnabled(),
            appInForeground: isAppInForeground(),
            appUptimeMs: getAppUptimeMs(),
            coldStart: isColdStart
        )
    }
    
    /// Cria um contexto de scan para um beacon específico
    public func createScanContext(rssi: Int, txPower: Int?, approxDistanceMeters: Float?) -> ScanContext {
        return ScanContext(
            rssi: rssi,
            txPower: txPower,
            approxDistanceMeters: approxDistanceMeters,
            scanSessionId: scanSessionId,
            detectedAt: getCurrentTimestamp()
        )
    }
    
    // MARK: - Private Helper Methods
    
    // SDK Info Methods
    
    private func getBuildNumber() -> Int? {
        guard let buildString = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
              let buildNumber = Int(buildString) else {
            return nil
        }
        return buildNumber
    }
    
    // Device Info Methods
    
    private func getManufacturer() -> String {
        return "Apple"
    }
    
    private func getDeviceModel() -> String {
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        return "Unknown"
        #endif
    }
    
    private func getOSVersion() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }
    
    private func getCurrentTimestamp() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000)
    }
    
    private func getTimezone() -> String {
        return TimeZone.current.identifier
    }
    
    private func getBatteryLevel() -> Float {
        #if canImport(UIKit)
        let level = UIDevice.current.batteryLevel
        return level < 0 ? -1.0 : level
        #else
        return -1.0
        #endif
    }
    
    private func isDeviceCharging() -> Bool {
        #if canImport(UIKit)
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
        #else
        return false
        #endif
    }
    
    private func isLowPowerModeEnabled() -> Bool {
        return ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    
    private func getBluetoothState() -> String {
        guard let provider = bluetoothStateProvider else {
            return "unknown"
        }
        
        let state = provider()
        
        switch state {
        case .poweredOn:
            return "on"
        case .poweredOff:
            return "off"
        case .unauthorized:
            return "unauthorized"
        case .unsupported, .resetting, .unknown:
            return "unknown"
        @unknown default:
            return "unknown"
        }
    }
    
    private func getLocationPermission() -> String {
        let status: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            status = CLLocationManager().authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }
        
        switch status {
        case .notDetermined:
            return "not_determined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorizedAlways:
            return "authorized_always"
        case .authorizedWhenInUse:
            return "authorized_when_in_use"
        @unknown default:
            return "not_determined"
        }
    }
    
    private func getLocationAccuracy() -> String? {
        if #available(iOS 14.0, *) {
            let manager = CLLocationManager()
            switch manager.accuracyAuthorization {
            case .fullAccuracy:
                return "full"
            case .reducedAccuracy:
                return "reduced"
            @unknown default:
                return nil
            }
        }
        return "full" // Em versões anteriores ao iOS 14, sempre é full
    }
    
    private func getNotificationPermissionStatus() async -> String {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        
        switch settings.authorizationStatus {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .notDetermined:
            return "not_determined"
        case .provisional:
            return "provisional"
        case .ephemeral:
            return "ephemeral"
        @unknown default:
            return "not_determined"
        }
    }
    
    // Network Methods
    
    private func setupNetworkMonitoring() {
        pathMonitor = NWPathMonitor()
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            self?.updateNetworkInfo(path: path)
        }
        let queue = DispatchQueue(label: "NetworkMonitor")
        pathMonitor?.start(queue: queue)
    }
    
    private func updateNetworkInfo(path: NWPath) {
        if path.status == .satisfied {
            if path.usesInterfaceType(.wifi) {
                currentNetworkType = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                currentNetworkType = "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                currentNetworkType = "ethernet"
            } else {
                currentNetworkType = "none"
            }
            currentConnectionExpensive = path.isExpensive
        } else {
            currentNetworkType = "none"
            currentConnectionExpensive = false
        }
    }
    
    private func getCellularGeneration() -> String? {
        guard currentNetworkType == "cellular" else { return nil }
        
        let networkInfo = CTTelephonyNetworkInfo()
        
        // iOS 13+ usa serviceCurrentRadioAccessTechnology
        if #available(iOS 13.0, *) {
            guard let radioTech = networkInfo.serviceCurrentRadioAccessTechnology?.values.first else {
                return "unknown"
            }
            return mapRadioTechnologyToGeneration(radioTech)
        } else {
            // iOS 12 e anteriores
            if let radioTech = networkInfo.currentRadioAccessTechnology {
                return mapRadioTechnologyToGeneration(radioTech)
            }
        }
        
        return "unknown"
    }
    
    private func mapRadioTechnologyToGeneration(_ radioTech: String) -> String {
        switch radioTech {
        case CTRadioAccessTechnologyGPRS,
             CTRadioAccessTechnologyEdge,
             CTRadioAccessTechnologyCDMA1x:
            return "2g"
            
        case CTRadioAccessTechnologyWCDMA,
             CTRadioAccessTechnologyHSDPA,
             CTRadioAccessTechnologyHSUPA,
             CTRadioAccessTechnologyCDMAEVDORev0,
             CTRadioAccessTechnologyCDMAEVDORevA,
             CTRadioAccessTechnologyCDMAEVDORevB,
             CTRadioAccessTechnologyeHRPD:
            return "3g"
            
        case CTRadioAccessTechnologyLTE:
            return "4g"
            
        default:
            // iOS 14+ suporta 5G
            if #available(iOS 14.1, *) {
                if radioTech == CTRadioAccessTechnologyNRNSA || radioTech == CTRadioAccessTechnologyNR {
                    return "5g"
                }
            }
            return "unknown"
        }
    }
    
    private func isRoaming() -> Bool? {
        let networkInfo = CTTelephonyNetworkInfo()
        
        if #available(iOS 13.0, *) {
            // Para iOS 13+, verifica o primeiro carrier disponível
            guard let carrier = networkInfo.serviceSubscriberCellularProviders?.values.first else {
                return nil
            }
            // Note: A propriedade para verificar roaming não está diretamente disponível
            // Esta é uma limitação do iOS
            return nil
        } else {
            // Para iOS 12 e anteriores
            return nil
        }
    }
    
    // Memory Methods
    
    private func getTotalRAM() -> Int64 {
        return Int64(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
    }
    
    private func getAvailableRAM() -> Int64 {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            let freeMemory = Int64(vmStats.free_count) * Int64(vm_kernel_page_size) / (1024 * 1024)
            return freeMemory
        }
        
        return 0
    }
    
    // Screen Methods
    
    private func getScreenWidth() -> Int {
        #if canImport(UIKit)
        return Int(UIScreen.main.bounds.width * UIScreen.main.scale)
        #else
        return 0
        #endif
    }
    
    private func getScreenHeight() -> Int {
        #if canImport(UIKit)
        return Int(UIScreen.main.bounds.height * UIScreen.main.scale)
        #else
        return 0
        #endif
    }
    
    // Advertising Methods
    
    private func getAdvertisingId() -> String? {
        if #available(iOS 14, *) {
            guard ATTrackingManager.trackingAuthorizationStatus == .authorized else {
                return nil
            }
        }
        
        let idfa = ASIdentifierManager.shared().advertisingIdentifier
        
        // Retorna nil se for o UUID zero (IDFA não disponível)
        if idfa.uuidString == "00000000-0000-0000-0000-000000000000" {
            return nil
        }
        
        return idfa.uuidString
    }
    
    private func isAdTrackingEnabled() -> Bool {
        if #available(iOS 14, *) {
            return ATTrackingManager.trackingAuthorizationStatus == .authorized
        } else {
            return ASIdentifierManager.shared().isAdvertisingTrackingEnabled
        }
    }
    
    // App State Methods
    
    private func isAppInForeground() -> Bool {
        #if canImport(UIKit)
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }
    
    private func getAppUptimeMs() -> Int64 {
        return Int64(Date().timeIntervalSince(appStartTime) * 1000)
    }
}

// MARK: - Extensions

import UserNotifications

extension UNUserNotificationCenter {
    func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }
}
