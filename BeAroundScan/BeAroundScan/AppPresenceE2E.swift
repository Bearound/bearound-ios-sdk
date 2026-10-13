import BearoundSDK
import Combine
import CoreBluetooth
import CoreLocation
import Foundation
import os.log
import SwiftUI

/// App presence device E2E mode (e2e/app-presence/run.sh, spec sdk-app-presence F5-01).
///
/// Active only when the harness launches the app with `BEAROUND_APP_PRESENCE_E2E=1`
/// (`xcrun devicectl device process launch -e ...`); a normal launch never enters it. Each
/// launch is one step in a fresh process (a restart): configure, subscribe, start scanning,
/// record every delivery, stop and exit. The expectations of a step depend on the steps before
/// it and on the real time elapsed (production 3600 s interval), so the harness asserts them
/// (e2e/app-presence/tests/test_device_results.py) from the records written here.
///
/// Launch environment:
/// - `BEAROUND_E2E_CLIENT`: client label; the business token is derived from it, so each label
///   is its own cooldown namespace (A/B/A isolation).
/// - `BEAROUND_E2E_ACTION`: `run` (enable the targets and start scanning) or `optout`
///   (`enabled = false`).
/// - `BEAROUND_E2E_WAIT_MS`: how long to collect callbacks before stopping (default 15000).
/// - `BEAROUND_E2E_STEP`: step name, copied into every record.
///
/// Every record is one JSON line appended to `Library/Caches/bearound-e2e/records/native.jsonl`
/// (pulled with `xcrun devicectl device copy from`) and logged as `BEAROUND_E2E {json}`. No
/// Bluetooth, location or notification permission is requested: the round must not depend on
/// any of them.
enum AppPresenceE2E {
    static let isActive = ProcessInfo.processInfo.environment["BEAROUND_APP_PRESENCE_E2E"] == "1"

    /// Same targets in every host of the E2E (native, Flutter, React Native).
    static let targets = [
        AppPresenceTarget(
            id: "fixture",
            iosScheme: "bearound-presence-fixture",
            androidPackageName: "io.bearound.fixture.presence"
        ),
        AppPresenceTarget(
            id: "undeclared",
            iosScheme: "bearound-presence-undeclared",
            androidPackageName: "io.bearound.fixture.undeclared"
        ),
        AppPresenceTarget(id: "ios-only", iosScheme: "bearound-presence-ios-only"),
    ]
}

final class AppPresenceE2EDriver: NSObject, ObservableObject, BeAroundSDKDelegate {
    @Published private(set) var status = "starting"

    private let environment = ProcessInfo.processInfo.environment
    private lazy var client = environment["BEAROUND_E2E_CLIENT"] ?? "A"
    private lazy var action = environment["BEAROUND_E2E_ACTION"] ?? "run"
    private lazy var step = environment["BEAROUND_E2E_STEP"] ?? "unnamed"
    private lazy var waitSeconds = Double(environment["BEAROUND_E2E_WAIT_MS"] ?? "").map { $0 / 1000 } ?? 15
    private let log = OSLog(subsystem: "io.bearound.BeAroundScan", category: "AppPresenceE2E")
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        UIApplication.shared.isIdleTimerDisabled = true

        let sdk = BeAroundSDK.shared
        sdk.configure(
            businessToken: "e2e-native-client-\(client)",
            collectAdvertisingId: false,
            collectLocation: false,
            collectWifi: false
        )
        sdk.configureAppPresence(
            AppPresenceConfiguration(enabled: action != "optout", targets: AppPresenceE2E.targets)
        )
        emit("getter_start", sdk.getLastAppPresenceSnapshot())
        sdk.delegate = self
        sdk.startScanning()
        emit("started", extra: permissionState())
        status = "running"

        DispatchQueue.main.asyncAfter(deadline: .now() + waitSeconds) { [self] in
            emit("getter_end", sdk.getLastAppPresenceSnapshot())
            // Disables the SDK's own background mechanisms too, so nothing runs a round
            // between steps outside the harness's control.
            sdk.stopScanning()
            emit("done", extra: permissionState())
            status = "done"
            // A step is one process: the next launch is a restart.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
        }
    }

    // MARK: BeAroundSDKDelegate

    func didUpdateBeacons(_: [Beacon]) {}

    func didUpdateAppPresence(_ snapshot: AppPresenceSnapshot) {
        emit("listener", snapshot)
    }

    func didFailWithError(_ error: Error) {
        let nsError = error as NSError
        let code = nsError.userInfo["code"] as? String ?? "\(nsError.domain):\(nsError.code)"
        emit("error", extra: ["code": code])
    }

    // MARK: Records

    private func permissionState() -> [String: Any] {
        let bluetooth: String
        switch CBManager.authorization {
        case .notDetermined: bluetooth = "notDetermined"
        case .restricted: bluetooth = "restricted"
        case .denied: bluetooth = "denied"
        case .allowedAlways: bluetooth = "allowedAlways"
        @unknown default: bluetooth = "unknown"
        }
        let location: String
        switch CLLocationManager().authorizationStatus {
        case .notDetermined: location = "notDetermined"
        case .restricted: location = "restricted"
        case .denied: location = "denied"
        case .authorizedAlways: location = "authorizedAlways"
        case .authorizedWhenInUse: location = "authorizedWhenInUse"
        @unknown default: location = "unknown"
        }
        return ["bluetoothAuthorization": bluetooth, "locationAuthorization": location]
    }

    private func emit(_ event: String, _ snapshot: AppPresenceSnapshot? = nil, extra: [String: Any] = [:]) {
        var record: [String: Any] = [
            "host": "native",
            "client": client,
            "action": action,
            "step": step,
            "event": event,
            "pid": Int(getpid()),
            "continuousTimeMs": Self.continuousTimeMs(),
            "systemUptimeS": ProcessInfo.processInfo.systemUptime,
            "epochMs": (Date().timeIntervalSince1970 * 1000).rounded(.down),
        ]
        if let snapshot,
           let data = try? JSONEncoder().encode(snapshot),
           let object = try? JSONSerialization.jsonObject(with: data) {
            record["snapshot"] = object
        } else {
            record["snapshot"] = NSNull()
        }
        extra.forEach { record[$0.key] = $0.value }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        let line = String(decoding: data, as: UTF8.self)
        os_log("BEAROUND_E2E %{public}@", log: log, type: .default, line)
        Self.append(line)
    }

    /// The clock the SDK's cooldown runs on (mach_continuous_time: monotonic, includes sleep).
    private static func continuousTimeMs() -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let nanos = Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom)
        return (nanos / 1_000_000).rounded(.down)
    }

    private static func append(_ line: String) {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let directory = caches.appendingPathComponent("bearound-e2e/records", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("native.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.synchronize()
        handle.closeFile()
    }
}

struct AppPresenceE2EView: View {
    @StateObject private var driver = AppPresenceE2EDriver()

    var body: some View {
        Text("App presence E2E: \(driver.status)")
            .onAppear { driver.start() }
    }
}
