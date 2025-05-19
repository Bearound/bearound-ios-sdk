import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    var beaconDetector: BeaconDetector!

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Configurar o detector de beacons
        beaconDetector = BeaconDetector()
        
        // Solicitar permissão para notificações
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("Permissão para notificações concedida")
            } else if let error = error {
                print("Erro ao solicitar permissão para notificações: \(error.localizedDescription)")
            }
        }
        
        // Configurar handlers para eventos de beacon
        beaconDetector.didEnterRegionHandler = {
            self.sendNotification(title: "Beacon Detectado (!)", body: "Você entrou na região do beacon")
            
            // Sincronizar com a API quando entrar na região
            self.beaconDetector.syncWithAPI(eventType: "enter") { success, error in
                if let error = error {
                    print("Erro ao sincronizar com a API: \(error.localizedDescription)")
                } else if success {
                    print("Sincronização com a API bem-sucedida (Beacon Detectad)")
                    self.sendNotification(title: "Beacon Detectado (API OK)", body: "Gravei no DynamoDB")
                }
            }
        }
        
        beaconDetector.didExitRegionHandler = {
            self.sendNotification(title: "Beacon Perdido", body: "Você saiu da região do beacon")
          
        }
        
        beaconDetector.proximityHandler = { proximity in
            // Atualizar a interface do usuário com base na proximidade
            NotificationCenter.default.post(name: NSNotification.Name("BeaconProximityChanged"), object: nil, userInfo: ["proximity": proximity])
        }
        
        return true
    }
    
    // Enviar notificação local
    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Mostrar notificação mesmo quando o app estiver em primeiro plano
        completionHandler([.alert, .sound])
    }
}
