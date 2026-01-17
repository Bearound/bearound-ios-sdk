import BearoundSDK
import Combine
import CoreBluetooth
import CoreLocation
import SwiftUI
import UserNotifications

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
    @Published var secondsUntilNextSync: Int = 0
    @Published var isRanging: Bool = false
    @Published var bluetoothStatus: String = "Verificando..."
    @Published var notificationStatus: String = "Verificando..."
    
    // SDK Configuration Settings
    @Published var foregroundInterval: ForegroundIntervalOption = .seconds15
    @Published var backgroundInterval: BackgroundIntervalOption = .seconds30
    @Published var queueSize: QueueSizeOption = .medium
    @Published var enableBluetoothScanning: Bool = false
    @Published var enablePeriodicScanning: Bool = true
    
    private let locationManager = CLLocationManager()
    private var wasInBeaconRegion = false
    private var scanStartTime: Date?
    private let notificationManager = NotificationManager.shared
    private var bluetoothManager: CBCentralManager?

    override init() {
        super.init()
        locationManager.delegate = self

        locationManager.requestAlwaysAuthorization()
        notificationManager.requestAuthorization()
        updatePermissionStatus()
        checkBluetoothStatus()
        checkNotificationStatus()
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

    private func updatePermissionStatus() {
        let locationAuth = locationManager.authorizationStatus

        permissionStatus = switch locationAuth {
        case .authorizedAlways: "Sempre (Background habilitado)"
        case .authorizedWhenInUse: "Quando em uso (Background não funciona)"
        case .denied, .restricted: "Negada (SDK não funcionará)"
        case .notDetermined: "Aguardando resposta..."
        @unknown default: "Status desconhecido"
        }
    }

    @MainActor
    private func initializeSDK() {
        BeAroundSDK.shared.configure(
            businessToken: "CLIENT_TOKEN",
            foregroundScanInterval: foregroundInterval.sdkValue,
            backgroundScanInterval: backgroundInterval.sdkValue,
            maxQueuedPayloads: queueSize.sdkValue,
            enableBluetoothScanning: enableBluetoothScanning,
            enablePeriodicScanning: enablePeriodicScanning
        )

        BeAroundSDK.shared.delegate = self

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
            businessToken: "CLIENT_TOKEN",
            foregroundScanInterval: foregroundInterval.sdkValue,
            backgroundScanInterval: backgroundInterval.sdkValue,
            maxQueuedPayloads: queueSize.sdkValue,
            enableBluetoothScanning: enableBluetoothScanning,
            enablePeriodicScanning: enablePeriodicScanning
        )
        
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
        if enablePeriodicScanning {
            return "Periódico (economiza bateria)"
        }
        return "Contínuo (sempre ativo)"
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
                        self.notificationManager.notifyBeaconRegionEntered(beaconCount: sortedBeacons.count)
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
        switch option {
        case .proximity:
            return beacons.sorted { beacon1, beacon2 in
                let proximityOrder: [CLProximity] = [.immediate, .near, .far, .unknown]
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
            }

        case .name:
            return beacons.sorted { beacon1, beacon2 in
                let name1 = "\(beacon1.major).\(beacon1.minor)"
                let name2 = "\(beacon2.major).\(beacon2.minor)"
                return name1 < name2
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
            } else {
                self.statusMessage = "Parado"
            }
        }
    }

    func didUpdateSyncStatus(secondsUntilNextSync: Int, isRanging: Bool) {
        DispatchQueue.main.async {
            self.secondsUntilNextSync = secondsUntilNextSync
            self.isRanging = isRanging
        }
    }
}
