import AdSupport
import AppTrackingTransparency
import BearoundSDK
import Combine
import CoreBluetooth
import CoreLocation
import SwiftUI
import UserNotifications

private enum UserDefaultsKeys {
    static let scanPrecision = "scanPrecision"
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

/// A single entry in the geofence/capture debug log.
struct GeofenceEvent: Identifiable {
    enum Kind {
        case regionEnter
        case regionExit
        case scanResumed
        case scanPaused
        // v2.5 — Two Eyes
        case bluetoothZoneEnter
        case bluetoothZoneExit
    }

    let id = UUID()
    let kind: Kind
    let timestamp: Date
    /// Free-form detail line (reason / outcome / coordinates).
    let detail: String
}

/// Which "eye" is being mirrored by a Debug Geofence card.
/// LEFT  = Location (CoreLocation region monitoring)
/// RIGHT = Bluetooth (CBCentralManager scan, BLE-only zone detector)
enum GeofenceEye {
    case location
    case bluetooth
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
    @Published var scanPrecision: ScanPrecision = .high
    @Published var queueSize: MaxQueuedPayloads = .medium

    // Sync Info
    @Published var lastSyncTime: Date?
    @Published var lastSyncBeaconCount: Int = 0
    @Published var lastSyncResult: String = "Aguardando..."
    @Published var retryBatchCount: Int = 0

    // BLE Diagnostic
    @Published var bleDiagnostic: String = "..."

    // MARK: - Geofence Debug — Two Eyes (v2.5)
    //
    // Two independent presence signals, each rendered in its own card:
    //   👁 LEFT  — Location:  isInBeaconRegion + lastLocationEnter/Exit + locationRegionEnterCount
    //   👁 RIGHT — Bluetooth: isInBluetoothZone + lastBluetoothEnter/Exit + bluetoothZoneEnterCount

    /// LEFT EYE (Location) — True while CoreLocation reports the device is inside the iBeacon region.
    /// Works even if the user has BT permission off (iOS manages BLE at the system level).
    @Published var isInBeaconRegion: Bool = false
    /// LEFT EYE — When the Location eye most recently saw a region ENTER. Resets per session.
    @Published var lastLocationEnter: Date?
    /// LEFT EYE — When the Location eye most recently saw a region EXIT. Resets per session.
    @Published var lastLocationExit: Date?
    /// LEFT EYE — Number of region enters observed in this session.
    @Published var locationRegionEnterCount: Int = 0

    /// RIGHT EYE (Bluetooth) — True while the BLE-only zone detector sees at least one beacon
    /// in its rolling window. Works even if the user has Location off (region monitoring inactive).
    @Published var isInBluetoothZone: Bool = false
    /// RIGHT EYE — When the Bluetooth eye most recently entered the zone. Resets per session.
    @Published var lastBluetoothEnter: Date?
    /// RIGHT EYE — When the Bluetooth eye most recently exited the zone. Resets per session.
    @Published var lastBluetoothExit: Date?
    /// RIGHT EYE — Number of Bluetooth zone enters observed in this session.
    @Published var bluetoothZoneEnterCount: Int = 0

    /// LEFT EYE — Unique beacon keys (`major.minor`) ever seen by the Location eye in this session.
    /// Used to compute the "Total detectados" pill on the card. Survives beacons going out of range.
    @Published var locationBeaconKeysSeen: Set<String> = []

    /// RIGHT EYE — Unique beacon keys ever seen by the Bluetooth eye in this session.
    @Published var bluetoothBeaconKeysSeen: Set<String> = []

    /// First-detection timestamp per beacon per eye. Used by the comparative analysis block
    /// to measure latency — for any beacon both eyes saw, we know which eye fired first and
    /// by how much. Populated lazily in didUpdateBeacons (first sighting only — no overwrites).
    @Published var firstSeenByLocation: [String: Date] = [:]
    @Published var firstSeenByBluetooth: [String: Date] = [:]

    /// LEFT EYE — Beacons currently visible to the Location eye (have `.coreLocation` in sources).
    /// Live-derived from `beacons` so it tracks comings and goings without extra state.
    var locationBeaconsNow: Int {
        beacons.filter { $0.discoverySources.contains(.coreLocation) }.count
    }

    /// RIGHT EYE — Beacons currently visible to the Bluetooth eye (have `.serviceUUID` or `.name` in sources).
    var bluetoothBeaconsNow: Int {
        beacons.filter {
            $0.discoverySources.contains(.serviceUUID) || $0.discoverySources.contains(.name)
        }.count
    }

    // MARK: - Comparative Analysis (v2.5)
    //
    // These derived values power the "Análise comparativa" block on the dedicated screen.
    // They answer: which eye is more useful in YOUR environment right now?

    /// Beacon keys this session was seen ONLY by the Location eye (never by BT).
    /// Indicates beacons that BT can't reach — could be permission off, BT-disabled beacons,
    /// or out of BLE scan range while still in iBeacon region range.
    var locationOnlyKeys: Set<String> {
        locationBeaconKeysSeen.subtracting(bluetoothBeaconKeysSeen)
    }

    /// Beacon keys ONLY seen by the Bluetooth eye (never by Location).
    /// Indicates beacons that CL doesn't pick up — Precise Location off, distance > region trigger,
    /// or beacon advertises the BEAD service but isn't a CLBeaconRegion target.
    var bluetoothOnlyKeys: Set<String> {
        bluetoothBeaconKeysSeen.subtracting(locationBeaconKeysSeen)
    }

    /// Beacon keys seen by BOTH eyes — the overlap. Only these have meaningful latency data.
    var bothEyesKeys: Set<String> {
        locationBeaconKeysSeen.intersection(bluetoothBeaconKeysSeen)
    }

    /// Per-beacon winner: which eye fired first for each beacon in the overlap.
    /// Returns (locationWins, bluetoothWins, averageLeadSeconds). Lead is positive when the
    /// winning eye saw it earlier — averaged across all beacons.
    /// (locationWins, bluetoothWins) won't always sum to bothEyesKeys.count because ties exist.
    var detectionRace: (locationWins: Int, bluetoothWins: Int, ties: Int, avgLeadSeconds: Double) {
        var locWins = 0
        var btWins = 0
        var ties = 0
        var leadsSeconds: [Double] = []

        for key in bothEyesKeys {
            guard let locFirst = firstSeenByLocation[key],
                  let btFirst = firstSeenByBluetooth[key] else { continue }
            let delta = btFirst.timeIntervalSince(locFirst)  // positive = location was earlier
            // Treat anything within 100ms as a tie — beneath the resolution of our event loop.
            if abs(delta) < 0.1 {
                ties += 1
            } else if delta > 0 {
                locWins += 1
                leadsSeconds.append(delta)
            } else {
                btWins += 1
                leadsSeconds.append(-delta)
            }
        }

        let avg = leadsSeconds.isEmpty ? 0.0 : leadsSeconds.reduce(0, +) / Double(leadsSeconds.count)
        return (locWins, btWins, ties, avg)
    }

    /// RSSI statistics from the BT eye for beacons currently in range.
    /// Returns (avg, min, max). Defaults to (0,0,0) when no beacons are visible.
    /// CoreLocation does NOT give us raw RSSI (only CLProximity buckets), which is one
    /// concrete reason to keep the Bluetooth eye even when Location is working — it's the
    /// only source of fine-grained signal strength.
    var bluetoothRSSIStats: (avg: Int, min: Int, max: Int) {
        let rssiValues = beacons.compactMap { beacon -> Int? in
            let hasBLE = beacon.discoverySources.contains(.serviceUUID) || beacon.discoverySources.contains(.name)
            return hasBLE ? beacon.rssi : nil
        }
        guard !rssiValues.isEmpty else { return (0, 0, 0) }
        let avg = rssiValues.reduce(0, +) / rssiValues.count
        return (avg, rssiValues.min() ?? 0, rssiValues.max() ?? 0)
    }

    // MARK: - Duty Cycle (v2.5)

    /// RIGHT EYE — Current scan mode of the Bluetooth eye. Drives the "Modo" pill on the card.
    /// Defaults to `.idle` so the UI renders correctly even before the SDK fires its first event.
    @Published var bluetoothScanMode: BluetoothScanMode = .idle

    /// RIGHT EYE — Absolute time of the next idle peek. Non-nil only while bluetoothScanMode == .idle.
    /// Used together with `nowTick` to render the live "Próx. scan em Xs" countdown.
    @Published var bluetoothNextIdleScanAt: Date?

    /// 1Hz heartbeat used to age the countdown ("4:23 → 4:22 → 4:21...") without forcing the
    /// BluetoothManager to fire an SDK event every second. Updated by `tickTimer`.
    @Published var nowTick: Date = Date()
    private var tickTimer: Timer?

    /// True when active scanning (ranging + BLE) is running. Outside a region this stays false.
    @Published var isActiveScanRunning: Bool = false
    /// Rolling log of geofence events (most recent first, max 30).
    @Published var geofenceEventLog: [GeofenceEvent] = []
    private let maxGeofenceLogEntries = 30

    // Detection Log — separate queues for foreground, background, and background locked
    @Published var foregroundLog: [DetectionLogEntry] = []
    @Published var backgroundLog: [DetectionLogEntry] = []
    @Published var backgroundLockedLog: [DetectionLogEntry] = []
    private let maxForegroundLogEntries = 50000
    private let maxBackgroundLogEntries = 50000
    private let maxBackgroundLockedLogEntries = 50000

    /// Tracks whether the device is locked
    private(set) var isDeviceLocked: Bool = false

    var detectionLog: [DetectionLogEntry] {
        (foregroundLog + backgroundLog + backgroundLockedLog).sorted { $0.timestamp > $1.timestamp }
    }

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
    private var diagnosticTimer: Timer?

    override init() {
        super.init()
        locationManager.delegate = self

        loadSavedSettings()
        setupLockObservers()

        locationManager.requestAlwaysAuthorization()
        notificationManager.requestAuthorization()
        updatePermissionStatus()
        checkBluetoothStatus()
        checkNotificationStatus()
        requestTrackingPermission()
        initializeSDK()
        startDiagnosticTimer()
        startTickTimer()
    }

    /// 1Hz heartbeat that re-publishes `nowTick`. SwiftUI views observing the view model
    /// re-render with each tick, which is how the EyeCard's countdown stays live.
    private func startTickTimer() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.nowTick = Date()
            }
        }
    }

    private func setupLockObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceDidLock),
            name: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceDidUnlock),
            name: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil
        )
        // Check initial state
        isDeviceLocked = !UIApplication.shared.isProtectedDataAvailable
    }

    @objc private func deviceDidLock() {
        isDeviceLocked = true
    }

    @objc private func deviceDidUnlock() {
        isDeviceLocked = false
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

        if let precisionRaw = defaults.string(forKey: UserDefaultsKeys.scanPrecision),
           let precision = ScanPrecision(rawValue: precisionRaw) {
            self.scanPrecision = precision
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

        defaults.set(scanPrecision.rawValue, forKey: UserDefaultsKeys.scanPrecision)
        defaults.set(queueSize.rawValue, forKey: UserDefaultsKeys.queueSize)

        defaults.set(userPropertyInternalId, forKey: UserDefaultsKeys.userPropertyInternalId)
        defaults.set(userPropertyEmail, forKey: UserDefaultsKeys.userPropertyEmail)
        defaults.set(userPropertyName, forKey: UserDefaultsKeys.userPropertyName)
        defaults.set(userPropertyCustom, forKey: UserDefaultsKeys.userPropertyCustom)
    }

    private func updatePermissionStatus() {
        let locationAuth = locationManager.authorizationStatus

        var status: String = switch locationAuth {
        case .authorizedAlways: "Sempre (Background habilitado)"
        case .authorizedWhenInUse: "Quando em uso (Background não funciona)"
        case .denied, .restricted: "Negada"
        case .notDetermined: "Aguardando resposta..."
        @unknown default: "Status desconhecido"
        }

        // Check precise location — iOS disables all beacon APIs when off
        if #available(iOS 14.0, *) {
            if locationAuth == .authorizedAlways || locationAuth == .authorizedWhenInUse {
                if locationManager.accuracyAuthorization == .reducedAccuracy {
                    status += " | Precisa: OFF (beacons CL desabilitados)"
                }
            }
        }

        permissionStatus = status
    }

    @MainActor
    private func initializeSDK() {
        BeAroundSDK.shared.configure(
            businessToken: "ee2ec9c46d2b2ad99bddcdd0afe224e6",
            scanPrecision: scanPrecision,
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
            businessToken: "ee2ec9c46d2b2ad99bddcdd0afe224e6",
            scanPrecision: scanPrecision,
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

    var scanPrecisionLabel: String {
        switch BeAroundSDK.shared.currentScanPrecision ?? scanPrecision {
        case .high: return "Alta (Ininterrupto)"
        case .medium: return "Média (3x10s/min)"
        case .low: return "Baixa (1x10s/min)"
        }
    }

    var scanMode: String {
        return scanPrecisionLabel
    }

    var sdkVersion: String {
        return BeAroundSDK.version
    }

    private func startDiagnosticTimer() {
        diagnosticTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.bleDiagnostic = BeAroundSDK.shared.bleDiagnosticInfo
        }
    }

    deinit {
        diagnosticTimer?.invalidate()
        tickTimer?.invalidate()
    }
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

            // v2.5 — Two Eyes — accumulate unique beacon keys per detection source so each
            // EyeCard can show "Total detectados" independently. Sets dedupe automatically.
            // Also stamp the FIRST sighting per eye so the comparative analysis can compute
            // latency (who saw which beacon first, and by how many seconds).
            let now = Date()
            for beacon in sortedBeacons {
                let key = "\(beacon.major).\(beacon.minor)"
                if beacon.discoverySources.contains(.coreLocation) {
                    self.locationBeaconKeysSeen.insert(key)
                    if self.firstSeenByLocation[key] == nil {
                        self.firstSeenByLocation[key] = now
                    }
                }
                if beacon.discoverySources.contains(.serviceUUID) || beacon.discoverySources.contains(.name) {
                    self.bluetoothBeaconKeysSeen.insert(key)
                    if self.firstSeenByBluetooth[key] == nil {
                        self.firstSeenByBluetooth[key] = now
                    }
                }
            }

            // Record detection log entries
            let isBackground = UIApplication.shared.applicationState != .active
            self.recordDetections(beacons: sortedBeacons, isBackground: isBackground)

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
            self.recordDetections(beacons: beacons, isBackground: true)
        }
    }

    // MARK: - Detection Log

    private func recordDetections(beacons: [Beacon], isBackground: Bool) {
        guard !beacons.isEmpty else { return }
        let locked = isDeviceLocked
        let newEntries = beacons.map { DetectionLogEntry.from(beacon: $0, isBackground: isBackground, isLocked: locked) }
        if isBackground && locked {
            backgroundLockedLog.insert(contentsOf: newEntries, at: 0)
            if backgroundLockedLog.count > maxBackgroundLockedLogEntries {
                backgroundLockedLog = Array(backgroundLockedLog.prefix(maxBackgroundLockedLogEntries))
            }
        } else if isBackground {
            backgroundLog.insert(contentsOf: newEntries, at: 0)
            if backgroundLog.count > maxBackgroundLogEntries {
                backgroundLog = Array(backgroundLog.prefix(maxBackgroundLogEntries))
            }
        } else {
            foregroundLog.insert(contentsOf: newEntries, at: 0)
            if foregroundLog.count > maxForegroundLogEntries {
                foregroundLog = Array(foregroundLog.prefix(maxForegroundLogEntries))
            }
        }
    }

    func clearDetectionLog() {
        foregroundLog.removeAll()
        backgroundLog.removeAll()
        backgroundLockedLog.removeAll()
    }

    // MARK: - Geofence / Location Capture Delegate (v2.4)

    func didEnterBeaconRegion() {
        DispatchQueue.main.async {
            let now = Date()
            self.isInBeaconRegion = true
            self.lastLocationEnter = now
            self.locationRegionEnterCount += 1
            self.appendGeofenceEvent(.init(
                kind: .regionEnter,
                timestamp: now,
                detail: "👁 LOCATION (esquerdo) — iOS reportou entrada na região (CLBeaconRegion)"
            ))
        }
    }

    func didExitBeaconRegion() {
        DispatchQueue.main.async {
            let now = Date()
            self.isInBeaconRegion = false
            self.lastLocationExit = now
            self.appendGeofenceEvent(.init(
                kind: .regionExit,
                timestamp: now,
                detail: "👁 LOCATION (esquerdo) — iOS reportou saída da região"
            ))
        }
    }

    // MARK: - Bluetooth Zone Delegate (v2.5) — RIGHT EYE

    func didEnterBluetoothZone() {
        DispatchQueue.main.async {
            let now = Date()
            self.isInBluetoothZone = true
            self.lastBluetoothEnter = now
            self.bluetoothZoneEnterCount += 1
            self.appendGeofenceEvent(.init(
                kind: .bluetoothZoneEnter,
                timestamp: now,
                detail: "👁 BLUETOOTH (direito) — BLE detectou beacon (CBCentralManager)"
            ))
        }
    }

    func didExitBluetoothZone() {
        DispatchQueue.main.async {
            let now = Date()
            self.isInBluetoothZone = false
            self.lastBluetoothExit = now
            self.appendGeofenceEvent(.init(
                kind: .bluetoothZoneExit,
                timestamp: now,
                detail: "👁 BLUETOOTH (direito) — zona vazia por 10s (graça expirou)"
            ))
        }
    }

    // v2.5 — Duty cycle mode transition (Bluetooth eye)
    // BluetoothManager flips between .idle (5min cycle) and .active (continuous + 10s tick).
    // SDK already dispatches this on main, but we wrap defensively anyway.
    func didChangeBluetoothScanMode(_ mode: BluetoothScanMode, nextIdleScanAt: Date?) {
        DispatchQueue.main.async {
            self.bluetoothScanMode = mode
            self.bluetoothNextIdleScanAt = nextIdleScanAt
        }
    }

    func didChangeActiveScanState(isActive: Bool) {
        DispatchQueue.main.async {
            self.isActiveScanRunning = isActive
            self.appendGeofenceEvent(.init(
                kind: isActive ? .scanResumed : .scanPaused,
                timestamp: Date(),
                detail: isActive
                    ? "Scan ativo (ranging + BLE) LIGADO"
                    : "Scan ativo (ranging + BLE) DESLIGADO — só region monitoring rodando"
            ))
        }
    }

    private func appendGeofenceEvent(_ event: GeofenceEvent) {
        geofenceEventLog.insert(event, at: 0)
        if geofenceEventLog.count > maxGeofenceLogEntries {
            geofenceEventLog = Array(geofenceEventLog.prefix(maxGeofenceLogEntries))
        }
    }

    func clearGeofenceLog() {
        geofenceEventLog.removeAll()
    }
}
