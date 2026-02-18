import BearoundSDK
import UserNotifications
import Foundation

class NotificationManager {
    static let shared = NotificationManager()

    private enum NotificationIdentifier: String {
        case scanningStarted = "scanning-started"
        case scanningStopped = "scanning-stopped"
        case beaconDetected = "beacon-detected"
        case beaconDetectedBackground = "beacon-detected-background"
        case apiSyncStarted = "api-sync-started"
        case apiSyncSuccess = "api-sync-success"
        case apiSyncFailed = "api-sync-failed"
        case appRelaunched = "app-relaunched-background"
    }

    private var lastNotificationDates: [NotificationIdentifier: Date] = [:]
    private let cooldowns: [NotificationIdentifier: TimeInterval] = [
        .scanningStarted: 10,
        .scanningStopped: 10,
        .beaconDetected: 300,
        .beaconDetectedBackground: 60,
        .apiSyncStarted: 30,
        .apiSyncSuccess: 60,
        .apiSyncFailed: 30,
        .appRelaunched: 60
    ]

    var enableScanningNotifications = true
    var enableBeaconNotifications = true
    var enableAPISyncNotifications = true
    var enableBackgroundNotifications = true

    private init() {
        requestAuthorization()
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                NSLog("[NotificationManager] Permissão de notificação concedida")
            } else if let error = error {
                NSLog("[NotificationManager] Erro ao solicitar permissão: %@", error.localizedDescription)
            } else {
                NSLog("[NotificationManager] Permissão de notificação negada")
            }
        }
    }

    func notifyScanningStarted() {
        guard enableScanningNotifications else { return }
        guard canSendNotification(for: .scanningStarted) else { return }

        sendNotification(
            identifier: .scanningStarted,
            title: "Escaneamento Iniciado",
            body: "BeAroundSDK está escaneando beacons",
            sound: .default
        )
    }

    func notifyScanningStopped() {
        guard enableScanningNotifications else { return }
        guard canSendNotification(for: .scanningStopped) else { return }

        sendNotification(
            identifier: .scanningStopped,
            title: "Escaneamento Parado",
            body: "BeAroundSDK parou de escanear",
            sound: .default
        )
    }

    func notifyBeaconDetected(beaconCount: Int, isBackground: Bool = false) {
        guard enableBeaconNotifications else { return }

        let identifier: NotificationIdentifier = isBackground ? .beaconDetectedBackground : .beaconDetected
        guard canSendNotification(for: identifier) else { return }

        let title = isBackground ? "Beacon Detectado (Background)" : "Beacon Detectado"
        let body = "Encontrado \(beaconCount) beacon\(beaconCount == 1 ? "" : "s") próximo\(beaconCount == 1 ? "" : "s")"

        sendNotification(
            identifier: identifier,
            title: title,
            body: body,
            sound: .default,
            badge: beaconCount
        )
    }

    func notifyBeaconDetectedWithDetails(beacons: [Beacon], isBackground: Bool = false) {
        guard enableBeaconNotifications else { return }

        let identifier: NotificationIdentifier = isBackground ? .beaconDetectedBackground : .beaconDetected
        guard canSendNotification(for: identifier) else { return }

        let title = isBackground ? "Beacon Detectado (Background)" : "Beacon Detectado"

        let beaconDetails = beacons.prefix(5).map { beacon in
            let sources = beacon.discoverySources
                .sorted { $0.rawValue < $1.rawValue }
                .map { $0.rawValue }
                .joined(separator: " + ")
            return "\(beacon.major).\(beacon.minor) [\(sources)]"
        }.joined(separator: ", ")

        let body: String
        if beacons.count <= 5 {
            body = beaconDetails
        } else {
            body = "\(beaconDetails) (+\(beacons.count - 5) mais)"
        }

        sendNotification(
            identifier: identifier,
            title: title,
            body: body,
            sound: .default,
            badge: beacons.count
        )
    }

    func notifyAPISyncStarted(beaconCount: Int) {
        guard enableAPISyncNotifications else { return }
        guard canSendNotification(for: .apiSyncStarted) else { return }

        sendNotification(
            identifier: .apiSyncStarted,
            title: "Sincronizando",
            body: "Enviando \(beaconCount) beacon\(beaconCount == 1 ? "" : "s") para o servidor",
            sound: nil // Silent for start
        )
    }

    func notifyAPISyncCompleted(beaconCount: Int, success: Bool) {
        guard enableAPISyncNotifications else { return }

        let identifier: NotificationIdentifier = success ? .apiSyncSuccess : .apiSyncFailed
        guard canSendNotification(for: identifier) else { return }

        let title = success ? "Sync Completo" : "Sync Falhou"
        let body = success
            ? "\(beaconCount) beacon\(beaconCount == 1 ? "" : "s") enviado\(beaconCount == 1 ? "" : "s") com sucesso"
            : "Falha ao enviar \(beaconCount) beacon\(beaconCount == 1 ? "" : "s"). Tentando novamente."

        sendNotification(
            identifier: identifier,
            title: title,
            body: body,
            sound: success ? nil : .default
        )
    }

    func notifyAppRelaunchedInBackground() {
        guard enableBackgroundNotifications else { return }
        guard canSendNotification(for: .appRelaunched) else { return }

        sendNotification(
            identifier: .appRelaunched,
            title: "App Reativado",
            body: "BeAroundSDK detectou região de beacons em segundo plano",
            sound: .default
        )
    }

    private func canSendNotification(for identifier: NotificationIdentifier) -> Bool {
        if let lastDate = lastNotificationDates[identifier],
           let cooldown = cooldowns[identifier] {
            let elapsed = Date().timeIntervalSince(lastDate)
            if elapsed < cooldown {
                NSLog("[NotificationManager] Cooldown ativo para %@ (%.0fs restantes)",
                      identifier.rawValue, cooldown - elapsed)
                return false
            }
        }
        return true
    }

    private func sendNotification(
        identifier: NotificationIdentifier,
        title: String,
        body: String,
        sound: UNNotificationSound?,
        badge: Int? = nil
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let sound = sound {
            content.sound = sound
        }
        if let badge = badge {
            content.badge = NSNumber(value: badge)
        }
        content.categoryIdentifier = "BEAROUND_SDK"

        let request = UNNotificationRequest(
            identifier: "\(identifier.rawValue)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("[NotificationManager] Erro ao enviar notificação: %@", error.localizedDescription)
            } else {
                self.lastNotificationDates[identifier] = Date()
                NSLog("[NotificationManager] Notificação enviada: %@ - %@", title, body)
            }
        }
    }

    func clearAllNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
