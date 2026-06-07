import SwiftUI
import BearoundSDK
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {

        BeAroundSDK.shared.registerBackgroundTasks()

        // Silent push: register with APNs so the server can wake the app in background
        // to refresh the BLE scan + sync (handled in didReceiveRemoteNotification).
        application.registerForRemoteNotifications()

        if launchOptions?[.location] != nil {
            NSLog("[BeAroundScan] App launched due to LOCATION event (beacon region entry)")
            NotificationManager.shared.notifyAppRelaunchedInBackground()
        }

        if launchOptions?[.bluetoothCentrals] != nil {
            NSLog("[BeAroundScan] App launched due to BLUETOOTH event (state restoration)")
            NotificationManager.shared.notifyAppRelaunchedInBackground()
        }

        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            if granted {
                NSLog("[BeAroundScan] Notification permission granted")
            } else if let error = error {
                NSLog("[BeAroundScan] Notification permission error: %@", error.localizedDescription)
            } else {
                NSLog("[BeAroundScan] Notification permission denied")
            }
        }

        return true
    }

    func application(
        _ application: UIApplication,
        performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        NSLog("[BeAroundScan] Background fetch triggered")
        BeAroundSDK.shared.performBackgroundFetch { success in
            completionHandler(success ? .newData : .noData)
        }
    }

    // APNs registration result — the device token is what the server (or a test push)
    // targets. Logged with a greppable tag so we can extract it from the device console.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        NSLog("[BeAroundScan] APNS_DEVICE_TOKEN %@", token)
        Self.writeApnsStatus("token=\(token)")
        // NOTE: no setPushToken() call here — the SDK captures the token automatically via
        // AppDelegate swizzling (PushTokenAutoCapture). This proves the zero-client-code path.
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("[BeAroundScan] APNs registration FAILED: %@", error.localizedDescription)
        Self.writeApnsStatus("error=\(error.localizedDescription)")
    }

    // Persist the APNs token (or failure) to a file so it can be pulled from the device
    // container deterministically, independent of log-capture timing.
    private static func writeApnsStatus(_ s: String) {
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? s.write(to: dir.appendingPathComponent("apns_status.txt"), atomically: true, encoding: .utf8)
        }
    }

    // NOTE: no didReceiveRemoteNotification here — the SDK handles Bearound silent pushes
    // automatically (PushTokenAutoCapture swizzles it, gated on the "bearound" payload marker).
    // The scan result is surfaced to the app via the didCompletePushScan delegate callback
    // (see BeaconViewModel). This proves the zero-client-code receive path.

    /// The OS relaunches the app (or wakes it) to deliver results of the SDK's background
    /// beacon-uploads. Forward the event to the SDK, which finalizes the pending upload(s)
    /// and invokes the system completion handler once events finish draining.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        NSLog("[BeAroundScan] handleEventsForBackgroundURLSession: %@", identifier)
        BeAroundSDK.shared.handleBackgroundURLSessionEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}

@main
struct BeAroundScanApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = BeaconViewModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView(viewModel: viewModel)
                    .tabItem {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text("Beacons")
                    }

                RetryQueueView(viewModel: viewModel)
                    .tabItem {
                        Image(systemName: "arrow.clockwise.circle")
                        Text("Retry Queue")
                    }

                DetectionLogView(viewModel: viewModel)
                    .tabItem {
                        Image(systemName: "list.bullet.rectangle")
                        Text("Log")
                    }
            }
        }
    }
}
