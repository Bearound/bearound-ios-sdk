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

    // Deterministic, pullable proof that the silent-push handler actually ran (and its result),
    // independent of flaky log capture. Each line: "<unixTime> | RECEIVED|DONE didIngest=...".
    private static func appendPushLog(_ s: String) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("push_log.txt")
        let line = "\(Date().timeIntervalSince1970) | \(s)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url)
        }
    }

    // Silent push (content-available:1) wakes the app in background. Refresh the BLE scan,
    // collect Service Data, and sync — then call the completion handler so iOS knows we're done.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        NSLog("[BeAroundScan] SILENT PUSH received — refreshing BLE scan + sync")
        Self.appendPushLog("RECEIVED")
        BeAroundSDK.shared.performBackgroundBLERefreshAndSync(bleScanDuration: 10.0, trigger: "silent_push") { ingestStarted in
            let info = BeAroundSDK.shared.lastBackgroundScanInfo
            let beaconsFound = info?.beaconsFound ?? 0
            let pendingBatches = info?.pendingBatches ?? 0
            NSLog("[BeAroundScan] Silent push scan done (beacons=%d, ingestStarted=%d, pending=%d)",
                  beaconsFound, ingestStarted ? 1 : 0, pendingBatches)
            Self.appendPushLog("DONE beacons=\(beaconsFound) ingestStarted=\(ingestStarted) pending=\(pendingBatches)")
            // App-level: surface the push-triggered SCAN result immediately (scan ran + count).
            // The real HTTP ingest result arrives later via didCompleteSync -> notifyAPISyncCompleted.
            NotificationManager.shared.notifyPushTriggeredSync(
                beaconsFound: beaconsFound,
                ingestStarted: ingestStarted,
                pendingBatches: pendingBatches
            )
            completionHandler(ingestStarted ? .newData : .noData)
        }
    }

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
