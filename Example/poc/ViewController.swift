import UIKit
import CoreLocation
import BeAround

class ViewController: UIViewController, CLLocationManagerDelegate {

    override func viewDidLoad() {
        super.viewDidLoad()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        let locationManager = CLLocationManager()
        locationManager.delegate = self
        locationManager.requestAlwaysAuthorization()
        
        Bearound(clientToken: "", isDebugEnable: true).startServices()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways:
            print("✅ Permissão concedida para sempre")
        case .authorizedWhenInUse:
            print("✅ Permissão concedida enquanto em uso")
        case .denied, .restricted:
            print("❌ Permissão negada")
        case .notDetermined:
            print("🔸 Permissão ainda não solicitada")
        @unknown default:
            break
        }
    }
    
}
