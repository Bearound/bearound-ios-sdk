import UIKit
import CoreLocation

class ViewController: UIViewController {
    
    // MARK: - Outlets
    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet weak var proximityLabel: UILabel!
    @IBOutlet weak var uuidLabel: UILabel!
    @IBOutlet weak var majorLabel: UILabel!
    @IBOutlet weak var minorLabel: UILabel!
    @IBOutlet weak var idfaLabel: UILabel!
    @IBOutlet weak var syncStatusLabel: UILabel!
    
    // MARK: - Propriedades
    var beaconDetector: BeaconDetector!
    
    // MARK: - Ciclo de Vida
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Configurar a interface
        setupUI()
        
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            self.scanBeacon()
        }
        
        // Obter o detector de beacons do AppDelegate
//        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
//            beaconDetector = appDelegate.beaconDetector
//            
//            // Atualizar labels com informações do beacon
//            uuidLabel.text = beaconDetector.beaconUUID.uuidString
//            idfaLabel.text = beaconDetector.getIDFA()
//            
//            // Solicitar permissão de localização explicitamente no ViewController
//            // Isso garante que o diálogo de permissão seja exibido
//            beaconDetector.locationManager.requestAlwaysAuthorization()
//        } else {
//            // Se não conseguir obter o beaconDetector do AppDelegate, criar um novo
//            let locationManager = CLLocationManager()
//            locationManager.requestAlwaysAuthorization()
//        }
//        
//        // Registrar para notificações de mudança de proximidade
//        NotificationCenter.default.addObserver(self, selector: #selector(beaconProximityChanged(_:)), name: NSNotification.Name("BeaconProximityChanged"), object: nil)
        
        
    }
    
    @objc func scanBeacon() {
        let scanner = RNLBeaconScanner.shared()
        scanner?.startScanning()
        
        // Execute this code periodically (every second or so) to view the beacons detected
        if let detectedBeacons = scanner?.trackedBeacons() as? [RNLBeacon] {
            for beacon in detectedBeacons {
                if (beacon.beaconTypeCode.intValue == 0xbeac) {
                    // this is an AltBeacon
                    NSLog("Detected AltBeacon id1: %@ id2: %@ id3: %@", beacon.id1, beacon.id2, beacon.id3)
                }
                else if (beacon.beaconTypeCode.intValue == 0x00 && beacon.serviceUuid.intValue == 0xFEAA) {
                    // this is eddystone uid
                    NSLog("Detected EDDYSTONE-UID with namespace %@ instance %@", beacon.id1, beacon.id2)
                }
                else if (beacon.beaconTypeCode.intValue == 0x10 && beacon.serviceUuid.intValue == 0xFEAA) {
                    // this is eddystone url
                    NSLog("Detected EDDYSTONE-URL with %@", RNLURLBeaconCompressor.urlString(fromEddystoneURLIdentifier: beacon.id1))
                }
                else {
                    NSLog("Some other beacon detectd")
                    // some other beacon type
                }
                NSLog("The beacon is about %.1f meters away", beacon.distance)
                
            }
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Verificar status de autorização de localização
        checkLocationAuthorizationStatus()
    }
    
    deinit {
        // Remover observador de notificações
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Configuração da Interface
    
    private func setupUI() {
        title = "Detector de Beacon"
        
        statusLabel.text = "Aguardando autorização..."
        proximityLabel.text = "Desconhecida"
        uuidLabel.text = "---"
        idfaLabel.text = "---"
        syncStatusLabel.text = "Não sincronizado"
    }
    
    // MARK: - Ações
    
    @IBAction func syncButtonTapped(_ sender: UIButton) {
        syncWithAPI()
    }
    
    // MARK: - Métodos Auxiliares
    
    private func checkLocationAuthorizationStatus() {
        // Criar uma instância temporária do CLLocationManager se necessário
        let locationManager = self.beaconDetector?.locationManager ?? CLLocationManager()
        
        // Usar a propriedade da instância em vez do método estático (compatível com iOS 14+)
        let authStatus: CLAuthorizationStatus
        
        if #available(iOS 14.0, *) {
            authStatus = locationManager.authorizationStatus
        } else {
            // Fallback para versões anteriores do iOS
            authStatus = CLLocationManager.authorizationStatus()
        }
        
        switch authStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            statusLabel.text = "Monitorando beacons..."
        case .denied, .restricted:
            statusLabel.text = "Acesso à localização negado"
            showLocationPermissionAlert()
        case .notDetermined:
            statusLabel.text = "Aguardando autorização..."
        @unknown default:
            statusLabel.text = "Status desconhecido"
        }
    }
    
    private func showLocationPermissionAlert() {
        let alert = UIAlertController(
            title: "Permissão de Localização",
            message: "Para detectar beacons, o aplicativo precisa de acesso à sua localização. Por favor, vá para Configurações e permita o acesso à localização para este aplicativo.",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Configurações", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        
        alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel))
        
        present(alert, animated: true)
    }
    
    private func syncWithAPI() {
        syncStatusLabel.text = "Sincronizando..."
        
        beaconDetector.syncWithAPI { success, error in
            DispatchQueue.main.async {
                if success {
                    self.syncStatusLabel.text = "Sincronizado com sucesso"
                } else {
                    self.syncStatusLabel.text = "Falha na sincronização: \(error?.localizedDescription ?? "Erro desconhecido")"
                }
            }
        }
    }
    
    // MARK: - Notificações
    
    @objc func beaconProximityChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let proximity = userInfo["proximity"] as? CLProximity else {
            return
        }
        
        DispatchQueue.main.async {
            // Atualizar label de proximidade
            switch proximity {
            case .unknown:
                self.proximityLabel.text = "Desconhecida"
            case .immediate:
                self.proximityLabel.text = "Imediata"
            case .near:
                self.proximityLabel.text = "Próxima"
            case .far:
                self.proximityLabel.text = "Distante"
            @unknown default:
                self.proximityLabel.text = "Desconhecida"
            }
            
            // Verificar se beaconDetector não é nil antes de acessar suas propriedades
            guard let detector = self.beaconDetector else {
                self.majorLabel.text = "---"
                self.minorLabel.text = "---"
                return
            }
            
            // Atualizar labels de Major e Minor com os valores detectados
            if let major = detector.detectedMajor {
                self.majorLabel?.text = detector.detectedMajor
                            .map(String.init)           // converte Int -> String
                            ?? "---"
            } else {
                self.majorLabel.text = "---"
            }
            
            if let minor = detector.detectedMinor {
                self.minorLabel?.text = detector.detectedMinor
                            .map(String.init)
                            ?? "---"
            } else {
                self.minorLabel.text = "---"
            }
        }
    }
}
