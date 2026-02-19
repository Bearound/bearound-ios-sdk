import SwiftUI
import BearoundSDK
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {

        BeAroundSDK.shared.registerBackgroundTasks()

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
            }
        }
    }
}
