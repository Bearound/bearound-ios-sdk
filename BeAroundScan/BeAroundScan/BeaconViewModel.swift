import AdSupport
import AppTrackingTransparency
import BearoundSDK
import Combine
import CoreBluetooth
import CoreLocation
import SwiftUI
import UserNotifications

private enum UserDefaultsKeys {
    static let foregroundInterval = "foregroundInterval"
    static let backgroundInterval = "backgroundInterval"
    static let queueSize = "queueSize"
    static let userPropertyInternalId = "userPropertyInternalId"
    static let userPropertyEmail = "userPropertyEmail"
    static let userPropertyName = "userPropertyName"
    static let userPropertyCustom = "userPropertyCustom"
}

enum BeaconSortOption: String, CaseIterable {
    case proximity = "Proximidade"
    case name = "ID"
}

class BeaconViewModel: NSObject, ObservableObject, BeAroundSDKDelegate {
    @Published var isScanning = false
    @Published var beacons: [Beacon] = []
    @Published var statusMessage = "Pronto"
    @Published var permissionStatus = "Verificando..."
    @Published var lastScanTime: Date?
    @Published var sortOption: BeaconSortOption = .proximity
    @Published var bluetoothStatus: String = "Verificando..."
    @Published var notificationStatus: String = "Verificando..."
    @Published var trackingStatus: String = "Verificando..."
    @Published var idfaValue: String = "—"

    // SDK Configuration Settings
    @Published var foregroundInterval: ForegroundScanInterval = .seconds15
    @Published var backgroundInterval: BackgroundScanInterval = .seconds60
    @Published var queueSize: MaxQueuedPayloads = .medium

    // Sync Info
    @Published var lastSyncTime: Date?
    @Published var lastSyncBeaconCount: Int = 0
    @Published var lastSyncResult: String = "Aguardando..."
    @Published var retryBatchCount: Int = 0

    // Pinned Beacons
    @Published var pinnedBeaconKeys: Set<String> = []

    // User Properties
    @Published var userPropertyInternalId: String = ""
    @Published var userPropertyEmail: String = ""
    @Published var userPropertyName: String = ""
    @Published var userPropertyCustom: String = ""

    private let locationManager = CLLocationManager()
    private var wasInBeaconRegion = false
    private var scanStartTime: Date?
    private let notificationManager = NotificationManager.shared
    private var bluetoothManager: CBCentralManager?

    override init() {
        super.init()
        locationManager.delegate = self

        loadSavedSettings()

        locationManager.requestAlwaysAuthorization()
        notificationManager.requestAuthorization()
        updatePermissionStatus()
        checkBluetoothStatus()
        checkNotificationStatus()
        requestTrackingPermission()
        initializeSDK()
    }

    private func checkBluetoothStatus() {
        bluetoothManager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    private func checkNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    self.notificationStatus = "Autorizada"
                case .denied:
                    self.notificationStatus = "Negada"
                case .notDetermined:
                    self.notificationStatus = "Não solicitada"
                @unknown default:
                    self.notificationStatus = "Desconhecida"
                }
            }
        }
    }

    private func requestTrackingPermission() {
        if #available(iOS 14, *) {
            let currentStatus = ATTrackingManager.trackingAuthorizationStatus
            if currentStatus == .notDetermined {
                // Delay to avoid conflict with other permission dialogs
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    ATTrackingManager.requestTrackingAuthorization { [weak self] status in
                        DispatchQueue.main.async {
                            self?.updateTrackingStatus()
                        }
                    }
                }
            } else {
                updateTrackingStatus()
            }
        } else {
            // iOS < 14: no ATT framework
            let enabled = ASIdentifierManager.shared().isAdvertisingTrackingEnabled
            trackingStatus = enabled ? "Permitido" : "Negado"
            updateIDFAValue()
        }
    }

    private func updateTrackingStatus() {
        if #available(iOS 14, *) {
            switch ATTrackingManager.trackingAuthorizationStatus {
            case .authorized:
                trackingStatus = "Permitido"
            case .denied:
                trackingStatus = "Negado"
            case .restricted:
                trackingStatus = "Restrito"
            case .notDetermined:
                trackingStatus = "Não solicitado"
            @unknown default:
                trackingStatus = "Desconhecido"
            }
        }
        updateIDFAValue()
    }

    private func updateIDFAValue() {
        let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        if idfa == "00000000-0000-0000-0000-000000000000" {
            idfaValue = "Indisponível"
        } else {
            idfaValue = idfa
        }
    }

    private func loadSavedSettings() {
        let defaults = UserDefaults.standard

        if let foregroundRaw = defaults.object(forKey: UserDefaultsKeys.foregroundInterval) as? Int,
           let interval = ForegroundScanInterval(rawValue: foregroundRaw) {
            self.foregroundInterval = interval
        }

        if let backgroundRaw = defaults.object(forKey: UserDefaultsKeys.backgroundInterval) as? Int,
           let interval = BackgroundScanInterval(rawValue: backgroundRaw) {
            self.backgroundInterval = interval
        }

        if let queueRaw = defaults.object(forKey: UserDefaultsKeys.queueSize) as? Int,
           let queue = MaxQueuedPayloads(rawValue: queueRaw) {
            self.queueSize = queue
        }

        self.userPropertyInternalId = defaults.string(forKey: UserDefaultsKeys.userPropertyInternalId) ?? ""
        self.userPropertyEmail = defaults.string(forKey: UserDefaultsKeys.userPropertyEmail) ?? ""
        self.userPropertyName = defaults.string(forKey: UserDefaultsKeys.userPropertyName) ?? ""
        self.userPropertyCustom = defaults.string(forKey: UserDefaultsKeys.userPropertyCustom) ?? ""
    }

    private func saveCurrentSettings() {
        let defaults = UserDefaults.standard

        defaults.set(foregroundInterval.rawValue, forKey: UserDefaultsKeys.foregroundInterval)
        defaults.set(backgroundInterval.rawValue, forKey: UserDefaultsKeys.backgroundInterval)
        defaults.set(queueSize.rawValue, forKey: UserDefaultsKeys.queueSize)

        defaults.set(userPropertyInternalId, forKey: UserDefaultsKeys.userPropertyInternalId)
        defaults.set(userPropertyEmail, forKey: UserDefaultsKeys.userPropertyEmail)
        defaults.set(userPropertyName, forKey: UserDefaultsKeys.userPropertyName)
        defaults.set(userPropertyCustom, forKey: UserDefaultsKeys.userPropertyCustom)
    }

    private func updatePermissionStatus() {
        let locationAuth = locationManager.authorizationStatus

        permissionStatus = switch locationAuth {
        case .authorizedAlways: "Sempre (Background habilitado)"
        case .authorizedWhenInUse: "Quando em uso (Background não funciona)"
        case .denied, .restricted: "Negada"
        case .notDetermined: "Aguardando resposta..."
        @unknown default: "Status desconhecido"
        }
    }

    @MainActor
    private func initializeSDK() {
        BeAroundSDK.shared.configure(
            businessToken: "BUSINESS_TOKEN",
            foregroundScanInterval: foregroundInterval,
            backgroundScanInterval: backgroundInterval,
            maxQueuedPayloads: queueSize
        )

        BeAroundSDK.shared.delegate = self

        if !userPropertyInternalId.isEmpty || !userPropertyEmail.isEmpty ||
           !userPropertyName.isEmpty || !userPropertyCustom.isEmpty {
            let properties = UserProperties(
                internalId: userPropertyInternalId,
                email: userPropertyEmail,
                name: userPropertyName,
                customProperties: [
                    "custom": userPropertyCustom,
                ]
            )
            BeAroundSDK.shared.setUserProperties(properties)
        }

        statusMessage = "Configurado"

        startScanning()
    }
    
    @MainActor
    func applySettings() {
        let wasScanning = isScanning

        if wasScanning {
            stopScanning()
        }

        BeAroundSDK.shared.configure(
            businessToken: "BUSINESS_TOKEN",
            foregroundScanInterval: foregroundInterval,
            backgroundScanInterval: backgroundInterval,
            maxQueuedPayloads: queueSize
        )
        
        let properties = UserProperties(
            internalId: userPropertyInternalId,
            email: userPropertyEmail,
            name: userPropertyName,
            customProperties: [
                "custom": userPropertyCustom,
            ]
        )

        BeAroundSDK.shared.setUserProperties(properties)

        // Save settings to UserDefaults
        saveCurrentSettings()

        statusMessage = "Configurações aplicadas"

        if wasScanning {
            startScanning()
        }
    }

    @MainActor
    func startScanning() {
        BeAroundSDK.shared.startScanning()
        isScanning = true
        statusMessage = "Scaneando..."
        lastScanTime = Date()
        scanStartTime = Date() // Marca início do scan para evitar notificações imediatas
        wasInBeaconRegion = false // Reseta estado para detectar nova entrada
    }

    @MainActor
    func stopScanning() {
        BeAroundSDK.shared.stopScanning()
        isScanning = false
        statusMessage = "Parado"
        wasInBeaconRegion = false // Reseta para permitir nova detecção quando iniciar novamente
        scanStartTime = nil
    }

    func togglePin(for beacon: Beacon) {
        let key = "\(beacon.major).\(beacon.minor)"
        if pinnedBeaconKeys.contains(key) {
            pinnedBeaconKeys.remove(key)
        } else {
            pinnedBeaconKeys.insert(key)
        }
        beacons = sortBeacons(beacons, by: sortOption)
    }

    func isPinned(_ beacon: Beacon) -> Bool {
        pinnedBeaconKeys.contains("\(beacon.major).\(beacon.minor)")
    }

    var currentDisplayInterval: Int {
        Int(BeAroundSDK.shared.currentSyncInterval ?? 0)
    }
    
    var scanDuration: Int {
        Int(BeAroundSDK.shared.currentScanDuration ?? 0)
    }

    var pauseDuration: Int {
        let interval = Int(BeAroundSDK.shared.currentSyncInterval ?? 0)
        let scan = scanDuration
        return max(0, interval - scan)
    }

    var scanMode: String {
        return "Periódico (economiza bateria)"
    }

    var sdkVersion: String {
        return BeAroundSDK.version
    }

    deinit {}
}

extension BeaconViewModel: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_: CLLocationManager) {
        DispatchQueue.main.async {
            self.updatePermissionStatus()
            self.initializeSDK()
        }
    }
}

extension BeaconViewModel: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async {
            switch central.state {
            case .poweredOn:
                self.bluetoothStatus = "Ligado"
            case .poweredOff:
                self.bluetoothStatus = "Desligado"
            case .unsupported:
                self.bluetoothStatus = "Não suportado"
            case .unauthorized:
                self.bluetoothStatus = "Não autorizado"
            case .resetting:
                self.bluetoothStatus = "Reiniciando"
            case .unknown:
                self.bluetoothStatus = "Desconhecido"
            @unknown default:
                self.bluetoothStatus = "Desconhecido"
            }
        }
    }
}

extension BeaconViewModel {
    func didUpdateBeacons(_ beacons: [Beacon]) {
        DispatchQueue.main.async {
            let sortedBeacons = self.sortBeacons(beacons, by: self.sortOption)
            
            let isNowInBeaconRegion = !sortedBeacons.isEmpty
            
            // Detecta entrada na região (mudou de vazio para não-vazio)
            // Só notifica se realmente entrou na região (estava fora e agora está dentro)
            let shouldNotify = isNowInBeaconRegion && !self.wasInBeaconRegion
            if shouldNotify {
                // Só notifica se passou tempo suficiente desde o início do scan
                // Isso evita notificações quando o app inicia já dentro da zona
                if let startTime = self.scanStartTime {
                    let timeSinceStart = Date().timeIntervalSince(startTime)
                    // Aguarda 2 segundos para evitar notificações imediatas ao iniciar já na zona
                    if timeSinceStart >= 2.0 {
                        self.notificationManager.notifyBeaconDetectedWithDetails(beacons: sortedBeacons)
                    }
                }
                // Se scanStartTime é nil, significa que o scan já estava ativo antes,
                // então não notificamos para evitar notificações indevidas
            }
            
            self.wasInBeaconRegion = isNowInBeaconRegion
            self.beacons = sortedBeacons
            self.lastScanTime = Date()

            if sortedBeacons.isEmpty {
                self.statusMessage = "Scaneando..."
            } else {
                self.statusMessage = "\(sortedBeacons.count) beacon\(sortedBeacons.count == 1 ? "" : "s")"
            }
        }
    }

    private func sortBeacons(_ beacons: [Beacon], by option: BeaconSortOption) -> [Beacon] {
        beacons.sorted { beacon1, beacon2 in
            let key1 = "\(beacon1.major).\(beacon1.minor)"
            let key2 = "\(beacon2.major).\(beacon2.minor)"
            let pinned1 = pinnedBeaconKeys.contains(key1)
            let pinned2 = pinnedBeaconKeys.contains(key2)

            if pinned1 != pinned2 {
                return pinned1
            }

            switch option {
            case .proximity:
                let proximityOrder: [BeaconProximity] = [.immediate, .near, .far, .bt, .unknown]
                if let index1 = proximityOrder.firstIndex(of: beacon1.proximity),
                   let index2 = proximityOrder.firstIndex(of: beacon2.proximity),
                   index1 != index2 {
                    return index1 < index2
                }

                if beacon1.rssi != beacon2.rssi {
                    return beacon1.rssi > beacon2.rssi
                }

                if beacon1.accuracy > 0 && beacon2.accuracy > 0 {
                    return beacon1.accuracy < beacon2.accuracy
                }
                if beacon1.accuracy > 0 { return true }
                if beacon2.accuracy > 0 { return false }

                return false

            case .name:
                return "\(beacon1.major).\(beacon1.minor)" < "\(beacon2.major).\(beacon2.minor)"
            }
        }
    }

    func didFailWithError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            print("Erro: \(error.localizedDescription)")
            self?.statusMessage = "Erro: \(error.localizedDescription)"
        }
    }

    func didChangeScanning(isScanning: Bool) {
        DispatchQueue.main.async {
            self.isScanning = isScanning
            if isScanning {
                self.statusMessage = "Scaneando..."
                self.notificationManager.notifyScanningStarted()
            } else {
                self.statusMessage = "Parado"
                self.notificationManager.notifyScanningStopped()
            }
        }
    }

    // MARK: - Sync Lifecycle Delegate Methods

    func willStartSync(beaconCount: Int) {
        DispatchQueue.main.async {
            NSLog("[BeaconViewModel] Sync starting with %d beacons", beaconCount)
            self.lastSyncBeaconCount = beaconCount
            self.lastSyncResult = "Enviando..."
            self.notificationManager.notifyAPISyncStarted(beaconCount: beaconCount)
        }
    }

    func didCompleteSync(beaconCount: Int, success: Bool, error: Error?) {
        DispatchQueue.main.async {
            self.lastSyncTime = Date()
            self.lastSyncBeaconCount = beaconCount
            self.retryBatchCount = BeAroundSDK.shared.pendingBatchCount
            if success {
                NSLog("[BeaconViewModel] Sync completed successfully: %d beacons", beaconCount)
                self.lastSyncResult = "Sucesso"
            } else {
                let errorMsg = error?.localizedDescription ?? "Erro desconhecido"
                NSLog("[BeaconViewModel] Sync failed: %@", errorMsg)
                self.lastSyncResult = "Falha: \(errorMsg)"
            }
            self.notificationManager.notifyAPISyncCompleted(beaconCount: beaconCount, success: success)
        }
    }

    // MARK: - Background Events Delegate Methods

    func didDetectBeaconInBackground(beacons: [Beacon]) {
        DispatchQueue.main.async {
            NSLog("[BeaconViewModel] Beacon detected in background: %d beacons", beacons.count)
            self.notificationManager.notifyBeaconDetectedWithDetails(beacons: beacons, isBackground: true)
        }
    }
}
