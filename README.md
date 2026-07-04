# 🐻 ``BearoundSDK``

Swift SDK for iOS — secure BLE beacon detection and indoor positioning by Bearound.

## Overview

BearoundSDK provides BLE beacon detection and indoor location technology for iOS applications. The SDK offers real-time beacon monitoring, delegate-based event callbacks, automatic API synchronization, and comprehensive device telemetry.

**Current Version:** 3.0.0

> **Version 2.0 Breaking Changes**: Complete SDK rewrite with new architecture. See migration guide below.
> **Version 2.3 Breaking Changes**: `foregroundScanInterval`/`backgroundScanInterval` replaced by `scanPrecision` (`.high`/`.medium`/`.low`). See Advanced Configuration.
> **Version 3.0 Breaking Changes**: GPS coordinate capture removed. `BeAroundLocationCapture` struct and `didStartLocationCapture` / `didCompleteLocationCapture` delegate methods deleted. Beacon presence (region monitoring + ranging) and the BLE eye remain fully functional. New `requestLocationAuthorization(_:)` API replaces ad-hoc CoreLocation calls in host apps. See [CHANGELOG](CHANGELOG.md) for migration notes.

## Topics

### Features

- **Real-time Beacon Detection**: Continuous monitoring using CoreLocation and CoreBluetooth
- **Delegate-Based Architecture**: Clean, protocol-based event handling with `BeAroundSDKDelegate`
- **Automatic API Synchronization**: Configurable sync intervals for beacon data
- **Smart Scanning Mode**: Configurable scan precision (high/medium/low) with automatic duty cycle management
- **Background Support**: Seamless transition between foreground and background modes
- **Bluetooth Metadata**: Optional enhanced beacon data (firmware, battery, temperature)
- **User Properties**: Attach custom user data to all beacon events
- **Robust Error Handling**: Circuit breaker pattern with exponential backoff retry logic
- **Comprehensive Device Info**: Automatic collection of device telemetry
- **Type-Safe API**: Modern Swift with proper type safety

### Requirements

- **Minimum iOS version**: 13.0+
- **Swift**: 5.0+
- **Xcode**: 11.0+
- **Location permissions** required for beacon detection
- **Bluetooth** enabled (optional, for enhanced metadata)

### Installation

#### Swift Package Manager (SPM)

Add the following URL to your package dependencies:
```
https://github.com/Bearound/bearound-ios-sdk.git
```

#### CocoaPods

Add to your `Podfile`:
```ruby
pod 'BearoundSDK', '~> 3.0'
```

Then run:
```bash
pod install
```

#### Manual Integration

1. Build the XCFramework: `./build_framework.sh`
2. Add `build/BearoundSDK.xcframework` to your project
3. Embed & Sign in your target's Frameworks

**Note**: Keep the SDK version updated. Check for the latest releases on the repository.

### Required Permissions

Add the following keys to your `Info.plist`:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>We use your location to show nearby content.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>We use your location in the background to deliver timely notifications.</string>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app uses Bluetooth to discover and connect to nearby devices.</string>
<key>NSUserTrackingUsageDescription</key>
<string>Your consent lets us tailor the experience and measure how features are used.</string>
```

For background mode support, add:

```xml
<key>UIBackgroundModes</key>
<array>
   <string>fetch</string>
   <string>location</string>
   <string>processing</string>
   <string>bluetooth-central</string>
</array>
```

For BGTaskScheduler support (iOS 13+), add:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
   <string>io.bearound.sdk.sync</string>
</array>
```

**Important**: The user must allow at least location or Bluetooth access for the SDK to function properly.

### Push Notifications & Push Token

The SDK captures the device's **APNs push token automatically** and sends it to the backend (mapped to the stable `deviceId`) so the device can be targeted for push — both the silent/background sync the SDK uses today and user-facing notifications in the future.

#### What the SDK does for you (no code required)

As soon as you call `BeAroundSDK.shared.configure(...)`, the SDK:

1. Triggers APNs registration (`registerForRemoteNotifications()`) — this only fetches the token and does **not** prompt the user.
2. Captures the token from your `AppDelegate` via method swizzling (the same technique Firebase/OneSignal use), even if your app never implements `didRegisterForRemoteNotificationsWithDeviceToken`.
3. Sends it with the next sync (as `device.pushToken`) plus `device.apnsEnvironment` (`sandbox`/`production`, so the backend routes to the right APNs host). Re-sends when the token changes **or** after 7 days (self-healing heartbeat).
4. Handles Bearound **silent pushes** (`content-available` carrying a `"bearound"` marker) by waking, refreshing the BLE scan and syncing — also via swizzle, no code required.

You do **not** need to write any token-forwarding code.

#### ⚠️ The one step you MUST do (it cannot be automated)

Enable the **Push Notifications** capability in your app target — this adds the signed `aps-environment` entitlement, which no SDK can add on your behalf:

> Xcode → your target → **Signing & Capabilities** → **+ Capability** → **Push Notifications**

For the **silent background sync** to wake the app, also enable **Background Modes** and check **Remote notifications** (plus **Location updates** and **Uses Bluetooth LE accessories**):

> **+ Capability** → **Background Modes** → ✅ Remote notifications

Without the Push Notifications capability, APNs will not issue a token and there is nothing to capture.

#### Showing user-facing notifications (separate from the token)

Fetching the token needs **no** user permission. Asking permission to **display** alerts/banners (`UNUserNotificationCenter.requestAuthorization`) shows a system prompt and is intentionally left to you — call it when it makes sense in your UX, only if/when you plan to send *visible* notifications.

#### Opting out / manual mode

If you prefer to forward the token yourself (e.g. you already manage `UNUserNotificationCenter`, or your app has no classic `AppDelegate`), disable the automatic capture by adding to your **Info.plist**:

```xml
<key>BearoundAppDelegateProxyEnabled</key>
<false/>
```

Then forward the token manually from your `AppDelegate`:

```swift
func application(_ application: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    BeAroundSDK.shared.setPushToken(token)
}
```

#### React Native & Flutter

The capture lives in the native `configure()`, so it works **automatically** in the React Native and Flutter wrappers too — the swizzle runs on the app's native `AppDelegate` (RN's / Flutter's) when you call `configure()` from JS/Dart. The **Push Notifications capability** still has to be enabled in the wrapper app's iOS target (the unavoidable manual step above).

### Advanced Background Integration

For maximum reliability when the app is completely closed, implement the following in your `AppDelegate`:

#### 1. Register Background Tasks (iOS 13+)

```swift
import BearoundSDK

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        // Register background tasks for beacon sync
        if #available(iOS 13.0, *) {
            BackgroundTaskManager.shared.registerTasks()
        }
        
        // Set minimum background fetch interval
        application.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
        
        return true
    }
}
```

#### 2. Handle Background Fetch

```swift
// AppDelegate.swift
func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    BeAroundSDK.shared.performBackgroundFetch { success in
        completionHandler(success ? .newData : .noData)
    }
}
```

#### Background Execution Summary

The SDK uses multiple mechanisms to ensure beacon data is synced even when the app is closed:

| Mechanism | Trigger | Permission required | Reliability |
|-----------|---------|--------------------|-------------|
| **CoreBluetooth State Restoration** | iOS detects BLE advertisement with Bearound service UUID | **Bluetooth only** | High — works when terminated, **independent of Location** |
| **CoreLocation Region Monitoring** | iOS detects beacon region entry/exit | Location "Always" | High — works when terminated |
| **Significant Location Changes** | User moves ~500m | Location "Always" | Medium — depends on movement |
| **Background Fetch** | iOS periodically wakes app | — | Low — not guaranteed timing |
| **BGTaskScheduler** | iOS schedules when resources available | — | Medium — opportunistic |

**Note**: When the user force-quits the app (swipe up from app switcher), most background execution is disabled by iOS. CoreBluetooth State Restoration still attempts to deliver but is less reliable in this case. This is expected system behavior.

### Basic Usage

#### Quick Start

The SDK uses a singleton pattern with delegate-based callbacks:

```swift
import BearoundSDK

class ViewController: UIViewController, BeAroundSDKDelegate {
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // 1. Configure the SDK (do once)
        BeAroundSDK.shared.configure(
            businessToken: "your-business-token-here"
            // Uses defaults: scanPrecision .high, queue 100 failed batches
        )
        // Note: appId is automatically extracted from Bundle.main.bundleIdentifier
        
        // 2. Set delegate to receive callbacks
        BeAroundSDK.shared.delegate = self
        
        // 3. Start scanning
        BeAroundSDK.shared.startScanning()
    }
    
    // MARK: - BeAroundSDKDelegate Methods
    
    func didUpdateBeacons(_ beacons: [Beacon]) {
        print("Found \(beacons.count) beacons")
        beacons.forEach { beacon in
            print("  \(beacon.major).\(beacon.minor) - RSSI: \(beacon.rssi)dB - Distance: \(String(format: "%.2f", beacon.accuracy))m")
        }
    }
    
    func didFailWithError(_ error: Error) {
        print("SDK Error: \(error.localizedDescription)")
    }
    
    func didChangeScanning(isScanning: Bool) {
        print("Scanning: \(isScanning ? "Active" : "Stopped")")
    }
    
    func didUpdateSyncStatus(secondsUntilNextSync: Int, isRanging: Bool) {
        print("Next sync in \(secondsUntilNextSync)s | Ranging: \(isRanging)")
    }
}
```

#### Stopping Scanning

To stop beacon detection:

```swift
BeAroundSDK.shared.stopScanning()
```

**Important Notes:**
- Always request location permissions before starting the SDK
- The SDK automatically handles background/foreground transitions
- Use `configure()` only once during app lifecycle

#### Runtime Permissions

Request the following permissions from the user:

**Core Location (Required):**
```swift
import CoreLocation

let locationManager = CLLocationManager()
locationManager.delegate = self
locationManager.requestAlwaysAuthorization()  // For background scanning
// or
locationManager.requestWhenInUseAuthorization()  // Foreground only
```

**Check Permission Status:**
```swift
if BeAroundSDK.isLocationAvailable() {
    let status = BeAroundSDK.authorizationStatus()
    switch status {
    case .authorizedAlways:
        print("✅ Full access - background enabled")
    case .authorizedWhenInUse:
        print("⚠️ Limited - background disabled")
    case .denied, .restricted:
        print("❌ No access - SDK won't work")
    case .notDetermined:
        print("⏳ Not requested yet")
    @unknown default:
        break
    }
}
```

**App Tracking Transparency (Optional):**
```swift
import AppTrackingTransparency
import AdSupport

if #available(iOS 14, *) {
    ATTrackingManager.requestTrackingAuthorization { status in
        switch status {
        case .authorized:
            print("ATT Authorized")
            let idfa = ASIdentifierManager.shared().advertisingIdentifier
            print("IDFA: \(idfa.uuidString)")
        case .denied:
            print("ATT Denied")
        default:
            break
        }
    }
}
```

### Advanced Configuration

#### Scan Precision Configuration

Configure the scan precision mode to balance accuracy vs. battery consumption:

```swift
BeAroundSDK.shared.configure(
    businessToken: "your-business-token-here",
    scanPrecision: .medium,                  // Balanced accuracy and battery
    maxQueuedPayloads: .large                // Store up to 200 failed batches
)
```

> **On iOS the BLE radio scans continuously in all precisions.** iOS performs its own
> power duty-cycling for background BLE scanning, and the SDK never stops the radio in
> steady state (stopping it would unregister the kernel scan filter and break
> terminated-app wake-up). Therefore `scanPrecision` on iOS does **not** change the radio
> duty cycle — it only controls the **sync cadence** and the **location accuracy**. (The
> per-precision scan/pause duty cycle is real on Android.)

**Available Configuration Options:**

- **Scan Precision** (`scanPrecision`) — on iOS, affects sync cadence and location accuracy only; the radio is always continuous
  - `.high` — 15s sync interval, 10m location accuracy (most frequent sync, higher battery usage). **Default.**
  - `.medium` — 60s sync interval, 10m location accuracy (balanced)
  - `.low` — 60s sync interval, 100m location accuracy (battery efficient)

| Precision | BLE Radio (iOS)        | Sync Interval | Location Accuracy |
|-----------|------------------------|---------------|-------------------|
| **High**  | Continuous             | 15s           | 10m               |
| **Medium**| Continuous             | 60s           | 10m               |
| **Low**   | Continuous             | 60s           | 100m              |

- **Retry Queue Size** (`maxQueuedPayloads`)
  - `.small` - 50 failed batches
  - `.medium` - 100 failed batches (default)
  - `.large` - 200 failed batches
  - `.xlarge` - 500 failed batches

**How it works (iOS):**
- The BLE radio is registered with iOS and scans continuously in every precision — iOS handles its own background power duty-cycling.
- `scanPrecision` selects the sync cadence (how often detected beacons are flushed to the API) and the CoreLocation accuracy used by the precision-location fix.
- No need to configure separate foreground/background intervals — the SDK handles transitions automatically.
- Failed API requests are queued for retry based on `maxQueuedPayloads` setting (each batch contains all beacons from one sync).

#### Bluetooth Metadata

Beacons automatically include metadata when available (firmware, battery, temperature):

```swift
// Metadata is automatically attached to beacons when detected via Bluetooth
func didUpdateBeacons(_ beacons: [Beacon]) {
    beacons.forEach { beacon in
        if let metadata = beacon.metadata {
            print("Battery: \(metadata.batteryLevel)%")
            print("Firmware: \(metadata.firmwareVersion)")
            print("Temperature: \(metadata.temperature)°C")
            print("TX Power: \(metadata.txPower ?? 0) dBm")
        }
    }
}
```

#### User Properties

`internalId` is **your own id for the user** (e.g. from your CRM / user spreadsheet) — a user property. Set it (and any other user data) via `setUserProperties` right after `configure()`, so every beacon event is tied back to that user on the backend:

```swift
BeAroundSDK.shared.configure(businessToken: "your-business-token-here")
BeAroundSDK.shared.setUserProperties(UserProperties(internalId: "user-12345"))

// Discovered more later? Call it again — fields you omit are kept:
BeAroundSDK.shared.setUserProperties(
    UserProperties(email: "user@example.com", name: "John Doe",
                   customProperties: ["tier": "premium", "region": "US-West"])
)

// Clear everything on logout (also clears the persisted id)
BeAroundSDK.shared.clearUserProperties()
```

- `setUserProperties` **merges** — omitted fields are kept, so adding `email`/`name` later does **not** wipe a previously-set `internalId`.
- `internalId` is **persisted** and restored when iOS relaunches the app in the background, so background events stay attributed to the user.

#### Checking SDK State

```swift
// Check if scanning (true if either BLE or CoreLocation is scanning)
if BeAroundSDK.shared.isScanning {
    print("SDK is scanning")
}

// Check current scan precision
if let precision = BeAroundSDK.shared.currentScanPrecision {
    print("Scan precision: \(precision)")
}

// Check pending failed batches
print("Pending batches: \(BeAroundSDK.shared.pendingBatchCount)")
```

### Device Telemetry (Collected Automatically)

The SDK automatically collects comprehensive device information:

#### SDK Information
- Version (3.0.0)
- Platform (ios)
- App ID (Bundle identifier)
- Build number

#### Device Information
- Manufacturer (Apple)
- Device model (iPhone 13, iPad Pro, etc.)
- OS and OS version
- Timezone and timestamp
- Battery level, charging status, low power mode
- Bluetooth state (on/off)
- Location permissions and accuracy level
- Notification permissions
- Network type (WiFi, Cellular, Ethernet)
- Cellular generation (2G, 3G, 4G, 5G) and roaming
- RAM total and available
- Screen resolution
- Advertising ID (IDFA) with tracking status
- App state (foreground/background)
- App uptime and cold start detection

### Beacon Data Model

Each `Beacon` object contains:

```swift
struct Beacon {
    let uuid: UUID              // Beacon UUID
    let major: Int              // Major value
    let minor: Int              // Minor value
    let rssi: Int               // Signal strength (dBm)
    let proximity: CLProximity  // .immediate, .near, .far, .unknown
    let accuracy: Double        // Estimated distance in meters
    let timestamp: Date         // Detection timestamp
    let metadata: BeaconMetadata?  // Optional BLE metadata
    let txPower: Int?           // Transmission power
}
```

Optional `BeaconMetadata` (when Bluetooth scanning is enabled):

```swift
struct BeaconMetadata {
    let firmwareVersion: String  // Beacon firmware
    let batteryLevel: Int        // Battery % (0-100)
    let movements: Int           // Movement count
    let temperature: Int         // Temperature (°C)
    let txPower: Int?            // TX power from BLE
    let rssiFromBLE: Int?        // RSSI from BLE scan
    let isConnectable: Bool?     // Connectivity status
}
```

### Background Behavior

The SDK intelligently manages background operation:

1. **Foreground**: Uses configured mode (periodic or continuous)
2. **Background**: Automatically switches to continuous mode
3. **Background Ranging**: Triggers sync when beacons detected
4. **Return to Foreground**: Restores original configuration

Background tasks are managed with `UIBackgroundTaskIdentifier` to ensure data syncs even when backgrounded.

### Terminated App Detection

The SDK runs a **hybrid two-eye model** — each "eye" is an independent wake-up path. The host app picks which eyes to enable based on its permission posture and force-quit-survival needs.

| | Bluetooth eye (Path A) | Location eye (Path B) |
|---|---|---|
| Permission required | Bluetooth | Location **Always** + Bluetooth |
| Foreground detection | ✅ | ✅ |
| Background detection | ✅ | ✅ |
| App killed by **iOS** (memory/battery pressure) | ✅ via `willRestoreState` | ✅ via `didEnterRegion` |
| App killed by **user** (swipe-up in app switcher) | ❌ iOS purges BT state restoration | ✅ Region monitoring persists |
| Battery cost | Low (BLE filter) | Low (kernel region monitoring) |
| Privacy footprint | Bluetooth only | Bluetooth + Location prompt |

> **Empirical note (v3.0):** A live capture from `bluetoothd` on a real iPhone confirmed that after the user manually force-quits the app via swipe-up, iOS removes the SDK's BLE scan filter from the kernel — `won't resurrect. Reason: killed by user`. The Bluetooth eye alone cannot survive that gesture. The Location eye remains the only path that survives a user force-quit, because CLBeaconRegion monitoring is registered with `locationd` and persists independently.

**Recommended posture:**

- **Privacy-first apps** that cannot ask for Location: ship with the Bluetooth eye only. Document to users that the app must not be swipe-up'd from the app switcher (system-initiated termination still wakes it).
- **Apps that need bulletproof wake-up:** opt into the Location eye via `BeAroundSDK.shared.requestLocationAuthorization(.always)`. The SDK keeps both eyes running side-by-side — whichever path fires first triggers ingest.

```swift
// Opt into the Location eye (force-quit survival)
BeAroundSDK.shared.requestLocationAuthorization(.always)

// Then start scanning. Both eyes will run if their permissions are granted.
BeAroundSDK.shared.startScanning()
```

#### Path A — Bluetooth-only (Location off or denied)

Uses `CBCentralManager` state preservation & restoration over the `bluetooth-central` background mode. **No Location permission required.**

**Beacon firmware requirement:** the beacon must advertise the Bearound BLE service UUID alongside (or instead of) the iBeacon frame. Pure iBeacon advertisements use Apple manufacturer data and carry no service UUID — CoreBluetooth background matching cannot fire on them. The Bearound reference firmware emits a dual advertisement (iBeacon + service UUID) and works out of the box.

**Host app requirements:**
1. `bluetooth-central` in `UIBackgroundModes` (Info.plist)
2. `NSBluetoothAlwaysUsageDescription` in Info.plist
3. **Touch `BeAroundSDK.shared` synchronously inside `application(_:didFinishLaunchingWithOptions:)`** — before any SwiftUI view renders. The singleton's `init()` rebuilds the `CBCentralManager` with the same restore identifier, which is what iOS targets when relaunching the process. Touching the SDK only from a view's `onAppear` will miss the restore window.
4. The user must have called `startScanning()` at least once during a foreground session (the SDK persists this and only auto-resumes if scanning was active before termination)
5. Bluetooth must be toggled on in Control Center and the app must hold `.allowedAlways` Bluetooth authorization

**How it works:**
- iOS keeps a low-power BLE scan filtered by the Bearound service UUID running while the app is suspended or terminated
- When a matching advertisement is seen, iOS relaunches the app in background and provides `launchOptions[.bluetoothCentrals]`
- The SDK receives `centralManager(_:willRestoreState:)`, switches to ACTIVE scan mode, and fires `didEnterBluetoothZone()` on the delegate

#### Path B — CoreLocation Region Monitoring (Location authorized)

Uses iBeacon region monitoring. **Requires "Always" Location permission.**

**Host app requirements:**
1. `location` in `UIBackgroundModes` (and `fetch` for periodic sync)
2. `NSLocationAlwaysAndWhenInUseUsageDescription` + `NSLocationWhenInUseUsageDescription` in Info.plist
3. User grants "Always" permission (not "When In Use")
4. Background App Refresh enabled in device Settings

**How it works:**
- CoreLocation monitors beacon regions at the kernel level even with the app terminated
- When a beacon region is entered, iOS wakes the app and provides `launchOptions[.location]`
- The SDK has ~30 seconds to scan, sync, and then may be suspended again

#### Host app integration checklist

For wake-up to work reliably, your AppDelegate must look like this:

```swift
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {

        // CRITICAL: touch the singleton synchronously here. This rebuilds the
        // CBCentralManager with the restore identifier that iOS targets when
        // relaunching the process for a BLE match.
        BeAroundSDK.shared.registerBackgroundTasks()

        if launchOptions?[.bluetoothCentrals] != nil {
            NSLog("Relaunched by iOS due to BLE state restoration")
        }
        if launchOptions?[.location] != nil {
            NSLog("Relaunched by iOS due to CoreLocation region event")
        }

        return true
    }
}

@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // ...
}
```

#### Testing terminated app detection

**Path A (Bluetooth-only):**
1. Install the app, open it once
2. Grant Bluetooth permission. **Deny Location** (to prove independence)
3. Tap **Start Scanning** in the app
4. Close the app via swipe-up in the app switcher
5. Move away from the beacon for ~1 minute
6. Walk back into beacon range
7. In Console.app (filter by your app name), expect to see:
   - `App launched due to BLUETOOTH event (state restoration)`
   - `[BluetoothManager] State restoration triggered (BT wake-up path)`
   - `[BluetoothManager] Restored: was scanning for BEAD service UUID — will enter ACTIVE mode`
   - `didEnterBluetoothZone()` firing on the delegate
8. Latency: typically 10–30s in background, can be longer under battery/memory pressure

**Path B (CoreLocation Region Monitoring):**
1. Grant **"Always"** location permission
2. Ensure Background App Refresh is enabled (Settings > General > Background App Refresh)
3. Tap **Start Scanning** in the app
4. Close the app completely
5. Walk near a beacon
6. In Console.app, expect:
   - `App launched due to LOCATION event (beacon region entry)`
   - `Entered beacon region`
   - Beacons being detected and synced

**Important notes (apply to both paths):**
- iOS may delay the wake-up — not instant by design
- Low Power Mode dramatically reduces background wake-up frequency
- iOS rate-limits how often it will wake your app
- **Force-quit by the user (swipe up) purges Path A's BLE state restoration from the kernel.** Only Path B (CoreLocation region monitoring) survives this gesture. Apps that need force-quit-survival must enable the Location eye via `requestLocationAuthorization(.always)`.

### Error Handling & Retry Logic

The SDK includes robust error handling:

- **Circuit Breaker**: After 10 consecutive API failures, triggers alert
- **Retry Queue**: Stores failed beacon batches for retry (configurable via `maxQueuedPayloads`: 50-500 batches)
- **Exponential Backoff**: Retries with delays: 5s, 10s, 20s, 40s (max 60s)
- **Automatic Recovery**: Resumes normal operation when API recovers

### Error telemetry

The SDK ships **first-party error telemetry** to help us keep it reliable in the field. When an
error originates **inside the Bearound SDK**, a compact report is sent to Bearound's ingest
endpoint (`POST https://ingest.bearound.io/sdk-errors`). This mirrors the Android SDK's
`ErrorReporter`, so both platforms behave identically.

**What is reported**

- Uncaught `NSException`s **only when a stack frame belongs to the Bearound SDK** — host-app
  crashes are never reported by us.
- SDK-internal failures already surfaced through the delegate/diagnostics: BLE/beacon manager
  errors, device-register failures, beacon-sync and retry-drain failures, and `startScanning`
  configuration/permission errors.

**What is NOT reported**

- Your app's own errors or crashes.
- Normal operational network errors from the beacon-upload client (these are transient and
  already handled by the retry logic above).

**Guarantees (never destabilizes your app)**

- It **never throws** and never breaks the host app.
- The uncaught-exception handler is **always chained**: any handler you already installed
  (Crashlytics, Sentry, Bugsnag, a custom one) is captured before ours and always invoked
  afterwards — we never replace or swallow it.
- Delivery is **fire-and-forget** over an isolated `URLSession` with a 5-second timeout, never
  the beacon-upload session. Reports are **rate-limited** (max 20/hour) and **de-duplicated**
  (identical errors collapse within a 5-minute window), and stack traces are capped at 8000
  characters.

**Payload shape** (`error`, `device` with per-platform `permissions`/`systemState`, `sdk`,
`occurredAt`). The `device` block reuses the same collector as the beacon payload, and the
`Authorization` header carries your business token when available (the endpoint also accepts
anonymous reports).

**Opt out** at any time — enabled by default:

```swift
BeAroundSDK.shared.setErrorReportingEnabled(false)
```

Disabling stops report delivery immediately; it does not affect scanning, sync, or your app's
own crash reporting.

> **Note — no POSIX signal handlers.** This version deliberately does **not** install signal
> handlers (`SIGABRT`, `SIGSEGV`, `SIGBUS`, …). Signal handlers are process-global and
> single-slot per signal; installing ours would clash with the host's crash reporter
> (Crashlytics/Sentry/Bugsnag), and a handler running inside an already-corrupted process can
> deadlock or re-crash. `NSException` coverage plus the reported internal errors are safe and
> sufficient. If signal capture is added later, it will be strictly chained and
> async-signal-safe.

### Monitoring & Debugging

The SDK logs important events with tag `[BeAroundSDK]`:

- `[BeAroundSDK] App launched in background (likely by beacon monitoring)`
- `[BeAroundSDK] App entered background - switching to continuous ranging mode`
- `[BeAroundSDK] App entered foreground - restoring periodic mode`
- `[BeAroundSDK] Sending N beacons to {API}/ingest`
- `[BeAroundSDK] Successfully sent N beacons (HTTP 200)`
- `[BeAroundSDK] Failed to send beacons - {error}`
- `[BeAroundSDK] Circuit breaker triggered - API may be down`
- `[BeAroundSDK] Cached metadata for beacon X.Y`

#### Diagnostics snapshot

`BeAroundSDK.shared.diagnostics()` returns a `BeAroundDiagnostics` (device id, masked push token + last-sent, `apnsEnvironment`, scanning state, pending batches, last scan/sync/push, recent errors). Use `.summary()` for a log-friendly string. Reads in-memory state only — no network.

### Security & Privacy

- Requires explicit user permission for location and Bluetooth
- Respects iOS privacy guidelines
- Ships Apple's **Privacy Manifest** (`PrivacyInfo.xcprivacy`) inside the framework — bundled automatically, no action needed by your app
- All beacon data transmitted to your configured API endpoint with secure business token authentication
- Authorization header sent as `Authorization: {businessToken}` (no Bearer prefix)
- No local data storage by default
- Does **not** collect IDFA / advertising identifier — identity is a per-app stable device id (Keychain UUID)
- Comprehensive device telemetry for analytics

### Testing

#### Requirements
- Physical iOS device with iOS 13+ (recommended) or Simulator
- Physical BLE beacons or beacon simulator (nRF Connect)
- Location "Always" permission for background testing
- Bluetooth enabled (if using metadata scanning)

#### Test Checklist
- [ ] Foreground beacon detection
- [ ] Background beacon detection
- [ ] API synchronization
- [ ] Scan precision modes (high/medium/low)
- [ ] Bluetooth metadata scanning
- [ ] User properties attachment
- [ ] Error handling and retries
- [ ] App state transitions (background ↔ foreground)
- [ ] Circuit breaker activation
- [ ] Permission handling

### How It Works

1. **Beacon Detection**: Uses CoreLocation's region monitoring and ranging
2. **Metadata Collection**: Optional CoreBluetooth scanning for enhanced data
3. **Data Aggregation**: Collects beacons and enriches with metadata
4. **Automatic Sync**: Sends beacon batches to API at configured intervals
5. **Error Recovery**: Retries failed requests with exponential backoff
6. **Background Mode**: Continues monitoring when app is backgrounded

### Migration from v1.x to v2.0

Version 2.0 is a complete rewrite with breaking changes.

#### API Changes

**Old API (v1.x):**
```swift
import BeAround

let bearound = Bearound(clientToken: token, isDebugEnable: true)
bearound.startServices()

// Listeners
class MyListener: BeaconListener {
    func onBeaconsDetected(_ beacons: [Beacon], eventType: String) {
        // Handle beacons
    }
}
bearound.addBeaconListener(MyListener())

// Access beacons
let active = bearound.getActiveBeacons()
let all = bearound.getAllBeacons()
```

**New API (v2.3+):**
```swift
import BearoundSDK

class MyViewController: BeAroundSDKDelegate {
    func setup() {
        BeAroundSDK.shared.configure(
            businessToken: "your-business-token-here"
            // Optional: scanPrecision (.high/.medium/.low), maxQueuedPayloads
        )
        // appId is now automatically extracted from Bundle ID
        BeAroundSDK.shared.delegate = self
        BeAroundSDK.shared.startScanning()
    }

    // Delegate methods
    func didUpdateBeacons(_ beacons: [Beacon]) {
        // Handle beacons
    }
}
```

#### Key Changes

1. **Singleton Pattern**: Use `BeAroundSDK.shared` instead of creating instances
2. **Delegate, not Listeners**: Implement `BeAroundSDKDelegate` protocol
3. **Configuration**: Use `configure(businessToken:...)` with `ScanPrecision` mode (v2.3+)
   - **businessToken parameter is now required**: Pass your business API token directly
   - **appId removed**: Now automatically extracted from `Bundle.main.bundleIdentifier`
   - **Authorization header**: Token sent as `Authorization: {businessToken}` (no Bearer prefix)
   - **Scan precision**: Use `ScanPrecision` enum (`.high`, `.medium`, `.low`) instead of separate foreground/background intervals
4. **Scanning Methods**: `startScanning()` / `stopScanning()` (was `startServices()` / `stopServices()`)
5. **Beacon Access**: Beacons delivered via delegate callbacks only
6. **No More Event Types**: No `enter`/`exit`/`lost` distinction

### Building the Framework

To build the XCFramework for distribution:

```bash
./build_framework.sh
```

Creates `build/BearoundSDK.xcframework` with:
- `ios-arm64` - Physical devices
- `ios-arm64_x86_64-simulator` - Simulators (Intel + Apple Silicon)

The framework can be distributed via CocoaPods, SPM, or manual integration.

### API Payload Format

The SDK automatically sends beacon data to your API endpoint in this structure:

```json
{
  "beacons": [
    {
      "uuid": "E25B8D3C-947A-452F-A13F-589CB706D2E5",
      "major": 1000,
      "minor": 2000,
      "rssi": -63,
      "proximity": "near",
      "accuracy": 1.8,
      "txPower": -59,
      "metadata": {
        "firmwareVersion": "2.1.0",
        "batteryLevel": 87,
        "movements": 42,
        "temperature": 24
      }
    }
  ],
  "sdk": {
    "version": "3.0.0",
    "platform": "ios",
    "appId": "com.example.app",
    "build": 210
  },
  "userDevice": {
    "manufacturer": "Apple",
    "model": "iPhone 13",
    "os": "ios",
    "osVersion": "17.2",
    "timestamp": 1735940400000,
    "timezone": "America/Sao_Paulo",
    "batteryLevel": 0.78,
    "isCharging": false,
    "lowPowerMode": false,
    "bluetoothState": "powered_on",
    "locationPermission": "authorizedAlways",
    "locationAccuracy": "full",
    "notificationsPermission": "authorized",
    "networkType": "wifi",
    "cellularGeneration": "4g",
    "isRoaming": false,
    "ramTotalMb": 4096,
    "ramAvailableMb": 1280,
    "screenWidth": 1170,
    "screenHeight": 2532,
    "advertisingId": "00000000-0000-0000-0000-000000000000",
    "adTrackingEnabled": true,
    "appInForeground": true,
    "appUptimeMs": 12345,
    "coldStart": false,
    "location": {
      "latitude": -23.5505,
      "longitude": -46.6333,
      "accuracy": 10.0
    }
  },
  "userProperties": {
    "internalId": "user-12345",
    "email": "user@example.com",
    "name": "John Doe",
    "customProperties": {
      "tier": "premium"
    }
  }
}
```

**Note:** The payload is automatically sent to your configured API endpoint at each sync interval.

### Complete Example

Here's a complete example integrating all features:

```swift
import BearoundSDK
import CoreLocation

class BeaconViewController: UIViewController, BeAroundSDKDelegate {
    private let locationManager = CLLocationManager()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Request permissions
        locationManager.requestAlwaysAuthorization()
        
        // Configure SDK with advanced options
        BeAroundSDK.shared.configure(
            businessToken: "your-business-token-here",
            scanPrecision: .medium,                 // Balanced accuracy and battery
            maxQueuedPayloads: .large               // Queue up to 200 failed batches
        )
        // Note: appId automatically extracted from Bundle Identifier
        
        // Set user properties
        let properties = UserProperties(
            internalId: "user-123",
            email: "user@example.com",
            name: "John Doe",
            customProperties: ["tier": "gold"]
        )
        BeAroundSDK.shared.setUserProperties(properties)
        
        // Set delegate
        BeAroundSDK.shared.delegate = self
        
        // Start scanning
        BeAroundSDK.shared.startScanning()
    }
    
    // MARK: - BeAroundSDKDelegate
    
    func didUpdateBeacons(_ beacons: [Beacon]) {
        print("📍 Found \(beacons.count) beacons")
        
        for beacon in beacons {
            let distance = String(format: "%.1f", beacon.accuracy)
            print("  Beacon \(beacon.major).\(beacon.minor)")
            print("    RSSI: \(beacon.rssi)dB | Distance: ~\(distance)m")
            
            if let meta = beacon.metadata {
                print("    Battery: \(meta.batteryLevel)% | Temp: \(meta.temperature)°C")
            }
        }
    }
    
    func didFailWithError(_ error: Error) {
        print("❌ Error: \(error.localizedDescription)")
    }
    
    func didChangeScanning(isScanning: Bool) {
        print(isScanning ? "🔍 Scanning started" : "⏸️ Scanning stopped")
    }
    
    func didUpdateSyncStatus(secondsUntilNextSync: Int, isRanging: Bool) {
        print("⏱️ Next sync in \(secondsUntilNextSync)s | Ranging: \(isRanging)")
    }
    
    deinit {
        BeAroundSDK.shared.stopScanning()
    }
}
```

## ⚠️ Technical Pending Issues

Due to iOS system restrictions and manufacturer-specific behaviors, the following limitations currently apply:

### 1. Background scanning with app fully closed

- **Background beacon scanning when the app is fully closed is not supported for any iOS version**
- This is a platform-level limitation imposed by iOS background execution policies.

**Impact:** iPhone and iOS devices may not detect beacons when the app is fully closed.

### Summary

| Scenario | Supported |
|--------|---------|
| App in foreground | ✅ Yes |
| App in background (in memory) | ✅ Yes |
| App closed | ❌ No |

### Support

For issues, feature requests, or questions:
- 📧 Email: support@bearound.com
- 🐛 Issues: GitHub Issues
- 📖 Docs: Full documentation at docs.bearound.com

### License

MIT © Bearound
