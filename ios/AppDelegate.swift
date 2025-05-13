import UIKit
import BackgroundTasks

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    var beaconDetector: BeaconDetector!
    
    // Identificador para a tarefa de background fetch
    let backgroundFetchIdentifier = "com.yourcompany.beacondetector.backgroundfetch"

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
            self.sendNotification(title: "Beacon Detectado", body: "Você entrou na região do beacon")
            
            // Sincronizar com a API quando entrar na região
            self.beaconDetector.syncWithAPI { success, error in
                if let error = error {
                    print("Erro ao sincronizar com a API: \(error.localizedDescription)")
                } else if success {
                    print("Sincronização com a API bem-sucedida")
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
        
        // Registrar o background fetch
        registerBackgroundFetch()
        
        return true
    }
    
    // Registrar o background fetch
    func registerBackgroundFetch() {
        // Para iOS 13 e superior, usar o novo sistema BGTaskScheduler
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundFetchIdentifier, using: nil) { task in
                self.handleBackgroundFetch(task: task as! BGAppRefreshTask)
            }
            scheduleBackgroundFetch()
        } else {
            // Para iOS 12 e inferior, usar o sistema antigo
            UIApplication.shared.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
        }
    }
    
    // Agendar a próxima execução do background fetch (iOS 13+)
    @available(iOS 13.0, *)
    func scheduleBackgroundFetch() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundFetchIdentifier)
        // Solicitar execução em pelo menos 15 minutos
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("Background fetch agendado com sucesso")
        } catch {
            print("Não foi possível agendar o background fetch: \(error.localizedDescription)")
        }
    }
    
    // Manipular a tarefa de background fetch (iOS 13+)
    @available(iOS 13.0, *)
    func handleBackgroundFetch(task: BGAppRefreshTask) {
        // Criar um task de expiração para garantir que completamos a tarefa antes do tempo limite
        let expirationHandler = {
            task.setTaskCompleted(success: false)
            print("Background fetch expirou antes de ser concluído")
        }
        
        // Definir o handler de expiração
        task.expirationHandler = expirationHandler
        
        // Verificar se há beacons próximos e sincronizar com a API
        if let detector = self.beaconDetector {
            detector.syncWithAPI { success, error in
                // Reagendar a próxima execução
                if #available(iOS 13.0, *) {
                    self.scheduleBackgroundFetch()
                }
                
                // Completar a tarefa
                task.setTaskCompleted(success: success)
                
                if let error = error {
                    print("Erro ao sincronizar com a API durante background fetch: \(error.localizedDescription)")
                } else if success {
                    print("Sincronização com a API durante background fetch bem-sucedida")
                    
                    // Enviar notificação informando sobre a sincronização em segundo plano
                    self.sendNotification(title: "Atualização em Segundo Plano", body: "Dados sincronizados com sucesso")
                }
            }
        } else {
            // Se o detector não estiver disponível, completar a tarefa com falha
            task.setTaskCompleted(success: false)
            print("Background fetch falhou: detector de beacons não disponível")
        }
    }
    
    // Manipular background fetch para iOS 12 e inferior
    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // Verificar se há beacons próximos e sincronizar com a API
        if let detector = self.beaconDetector {
            detector.syncWithAPI { success, error in
                if let error = error {
                    print("Erro ao sincronizar com a API durante background fetch: \(error.localizedDescription)")
                    completionHandler(.failed)
                } else if success {
                    print("Sincronização com a API durante background fetch bem-sucedida")
                    
                    // Enviar notificação informando sobre a sincronização em segundo plano
                    self.sendNotification(title: "Atualização em Segundo Plano", body: "Dados sincronizados com sucesso")
                    
                    completionHandler(.newData)
                } else {
                    completionHandler(.noData)
                }
            }
        } else {
            // Se o detector não estiver disponível, completar com falha
            completionHandler(.failed)
            print("Background fetch falhou: detector de beacons não disponível")
        }
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
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }
}
