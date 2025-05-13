import UIKit
import CoreLocation
import AdSupport

class BeaconDetector: NSObject, CLLocationManagerDelegate {
    
    // MARK: - Propriedades
    
    // UUID do beacon que estamos procurando (deve corresponder ao UUID configurado no Arduino)
    let beaconUUID = UUID(uuidString: "E25B8D3C-947A-452F-A13F-589CB706D2E5")!
    
    // Gerenciador de localização para monitorar e detectar beacons
    var locationManager: CLLocationManager!
    
    // Região do beacon que estamos monitorando
    var beaconRegion: CLBeaconRegion!
    
    // Armazenar os valores de Major e Minor detectados
    var detectedMajor: CLBeaconMajorValue?
    var detectedMinor: CLBeaconMinorValue?
    
    // Callback para quando o status de proximidade do beacon mudar
    var proximityHandler: ((CLProximity) -> Void)?
    
    // Callback para quando entrar na região do beacon
    var didEnterRegionHandler: (() -> Void)?
    
    // Callback para quando sair da região do beacon
    var didExitRegionHandler: (() -> Void)?
    
    // MARK: - Inicialização
    
    override init() {
        super.init()
        setupLocationManager()
    }
    
    // MARK: - Configuração
    
    private func setupLocationManager() {
        locationManager = CLLocationManager()
        locationManager.delegate = self
        
        // Configurações adicionais para melhorar a detecção de beacons
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        
        // Solicitar permissão "Always" explicitamente
        // No iOS 14+ e superior, isso mostrará um diálogo explicativo adicional
        locationManager.requestAlwaysAuthorization()
        
        // Configurar a região do beacon para monitoramento apenas com UUID
        // Não especificamos Major e Minor para detectar todos os beacons com este UUID
        if #available(iOS 13.0, *) {
            beaconRegion = CLBeaconRegion(uuid: beaconUUID, identifier: "BeaconRegion")
        } else {
            beaconRegion = CLBeaconRegion(proximityUUID: beaconUUID, identifier: "BeaconRegion")
        }
        
        // Configurar para notificar quando entrar/sair da região
        beaconRegion.notifyEntryStateOnDisplay = true
        beaconRegion.notifyOnEntry = true
        beaconRegion.notifyOnExit = true
    }
    
    // MARK: - Controle de Monitoramento
    
    func startMonitoring() {
        // Verificar se o monitoramento de beacons está disponível
        if CLLocationManager.isMonitoringAvailable(for: CLBeaconRegion.self) {
            // Iniciar o monitoramento da região do beacon
            locationManager.startMonitoring(for: beaconRegion)
            
            // Verificar se o ranging de beacons está disponível
            if CLLocationManager.isRangingAvailable() {
                // Iniciar o ranging de beacons na região
                if #available(iOS 13.0, *) {
                    locationManager.startRangingBeacons(satisfying: beaconRegion.beaconIdentityConstraint)
                } else {
                    locationManager.startRangingBeacons(in: beaconRegion)
                }
            }
        }
    }
    
    func stopMonitoring() {
        // Parar o monitoramento da região do beacon
        locationManager.stopMonitoring(for: beaconRegion)
        
        // Parar o ranging de beacons na região
        if #available(iOS 13.0, *) {
            locationManager.stopRangingBeacons(satisfying: beaconRegion.beaconIdentityConstraint)
        } else {
            locationManager.stopRangingBeacons(in: beaconRegion)
        }
    }
    
    // MARK: - Obter IDFA
    
    func getIDFA() -> String {
        // Obter o IDFA (Identifier for Advertisers) do dispositivo
        let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        return idfa
    }
    
    // MARK: - Sincronização com API
    
    func syncWithAPI(completion: @escaping (Bool, Error?) -> Void) {
        // Obter o IDFA do dispositivo
        let idfa = getIDFA()
        
        // Criar o objeto de dados para enviar para a API
        var data: [String: Any] = [
            "uuid": beaconUUID.uuidString,
            "idfa": idfa
        ]
        
        // Adicionar Major e Minor se detectados
        if let major = detectedMajor {
            data["major"] = major
        }
        
        if let minor = detectedMinor {
            data["minor"] = minor
        }
        
        // Converter o objeto de dados para JSON
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data) else {
            completion(false, NSError(domain: "BeaconDetector", code: 1, userInfo: [NSLocalizedDescriptionKey: "Falha ao serializar dados"]))
            return
        }
        
        // Criar a requisição para a API
        // Nota: O endpoint da API não está definido ainda, então estamos usando um placeholder
        let url = URL(string: "https://api.example.com/sync")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Enviar a requisição para a API
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(false, error)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                completion(false, NSError(domain: "BeaconDetector", code: 2, userInfo: [NSLocalizedDescriptionKey: "Resposta inválida da API"]))
                return
            }
            
            completion(true, nil)
        }
        
        task.resume()
    }
    
    // MARK: - CLLocationManagerDelegate
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            // Permissão concedida, iniciar o monitoramento
            startMonitoring()
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        if region is CLBeaconRegion {
            print("Entrou na região do beacon")
            didEnterRegionHandler?()
            
            // Sincronizar com a API quando entrar na região
            syncWithAPI { success, error in
                if let error = error {
                    print("Erro ao sincronizar com a API: \(error.localizedDescription)")
                } else if success {
                    print("Sincronização com a API bem-sucedida")
                }
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        if region is CLBeaconRegion {
            print("Saiu da região do beacon")
            didExitRegionHandler?()
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didRangeBeacons beacons: [CLBeacon], in region: CLBeaconRegion) {
        if let beacon = beacons.first {
            // Armazenar os valores de Major e Minor detectados
            detectedMajor = beacon.major.uint16Value
            detectedMinor = beacon.minor.uint16Value
            
            // Atualizar o status de proximidade
            proximityHandler?(beacon.proximity)
            
            // Exibir informações do beacon no console
            let proximityText: String
            switch beacon.proximity {
            case .unknown:
                proximityText = "Desconhecida"
            case .immediate:
                proximityText = "Imediata"
            case .near:
                proximityText = "Próxima"
            case .far:
                proximityText = "Distante"
            @unknown default:
                proximityText = "Desconhecida"
            }
            
            print("Beacon detectado - UUID: \(beacon.uuid.uuidString), Major: \(beacon.major), Minor: \(beacon.minor), Proximidade: \(proximityText), RSSI: \(beacon.rssi)")
            
            // Sincronizar com a API quando detectar um beacon
            syncWithAPI { success, error in
                if let error = error {
                    print("Erro ao sincronizar com a API: \(error.localizedDescription)")
                } else if success {
                    print("Sincronização com a API bem-sucedida")
                }
            }
        } else {
            // Nenhum beacon encontrado
            detectedMajor = nil
            detectedMinor = nil
            proximityHandler?(.unknown)
        }
    }
}
