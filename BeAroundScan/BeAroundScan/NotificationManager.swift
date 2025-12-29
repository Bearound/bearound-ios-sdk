import UserNotifications
import Foundation

class NotificationManager {
    static let shared = NotificationManager()
    
    private let notificationIdentifier = "beacon-region-entered"
    private var lastNotificationDate: Date?
    private let notificationCooldown: TimeInterval = 300 // 5 minutos para evitar spam
    
    private init() {
        requestAuthorization()
    }
    
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("[NotificationManager] Permissão de notificação concedida")
            } else if let error = error {
                print("[NotificationManager] Erro ao solicitar permissão: \(error.localizedDescription)")
            } else {
                print("[NotificationManager] Permissão de notificação negada")
            }
        }
    }
    
    func notifyBeaconRegionEntered(beaconCount: Int) {
        // Evita notificações muito frequentes
        if let lastDate = lastNotificationDate {
            let timeSinceLastNotification = Date().timeIntervalSince(lastDate)
            if timeSinceLastNotification < notificationCooldown {
                print("[NotificationManager] Notificação ignorada - muito recente (\(Int(timeSinceLastNotification))s atrás)")
                return
            }
        }
        
        let content = UNMutableNotificationContent()
        content.title = "Beacon Detectado"
        content.body = "Você entrou na zona de \(beaconCount) beacon\(beaconCount == 1 ? "" : "s")"
        content.sound = .default
        content.badge = NSNumber(value: beaconCount)
        
        // Categoria para ações (opcional)
        content.categoryIdentifier = "BEACON_DETECTED"
        
        let request = UNNotificationRequest(
            identifier: "\(notificationIdentifier)-\(UUID().uuidString)",
            content: content,
            trigger: nil // Notificação imediata
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[NotificationManager] Erro ao enviar notificação: \(error.localizedDescription)")
            } else {
                print("[NotificationManager] Notificação enviada: \(beaconCount) beacon(s) detectado(s)")
                self.lastNotificationDate = Date()
            }
        }
    }
    
    func clearAllNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}

