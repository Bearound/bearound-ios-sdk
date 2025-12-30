# 🐻 BeAround SDK for iOS

Official iOS SDK for integrating Bearound's BLE beacon detection and indoor location technology.

> **Version 2.0.0** - Complete SDK rewrite with modern Swift architecture

## 📱 Overview

Swift SDK for iOS — secure BLE beacon detection and indoor positioning by Bearound.

## ✨ Features

- **Real-time Beacon Detection**: Monitors BLE beacons using CoreLocation and CoreBluetooth
- **Delegate-Based Architecture**: Clean, protocol-based event handling
- **Automatic API Synchronization**: Configurable sync intervals for beacon data
- **Periodic Scanning Mode**: Battery-efficient scanning with configurable scan/pause durations
- **Background Support**: Seamless transition between foreground and background modes
- **Bluetooth Metadata**: Optional enhanced beacon data (firmware, battery, temperature)
- **User Properties**: Attach custom user data to beacon events
- **Robust Error Handling**: Circuit breaker pattern with exponential backoff retry logic
- **Comprehensive Device Info**: Collects device telemetry (battery, network, permissions, etc.)
- **Type-Safe API**: Modern Swift with proper type safety and error handling

---

## ⚙️ Requirements

- **Minimum iOS version**: 13 
- **Location or Bluetooth** must be enabled on the device

### ⚙️ Required Permissions

Add the following to info.plist:
```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Precisamos da sua localização para mostrar conteúdos próximos.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Precisamos da sua localização mesmo em segundo plano para enviar notificações relevantes.</string>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Este aplicativo precisa acessar o Bluetooth para se conectar a dispositivos próximos.</string>
<key>NSUserTrackingUsageDescription</key>
<string>Precisamos do seu consentimento para rastrear sua atividade e oferecer uma experiência personalizada.</string>
<key>NSUserTrackingUsageDescription</key>
<string>Precisamos de sua permissão para rastrear sua atividade e oferecer uma experiência personalizada.</string>
```

Also, in order to run it on background mode, you must add the following:
```xml
<key>UIBackgroundModes</key>
<array>
   <string>fetch</string>
   <string>location</string>
   <string>processing</string>
   <string>bluetooth-central</string>
</array>
```
✅ Important: In case the user doesn't allow location neither bluetooth access, the SDK won't be able to find possible beacons. So for the SDK works properly the user must has allow at least one of the permissions.

### 📦 Installation

The SDK is available via CocoaPods. Add the following line to your `Podfile`:

```ruby
pod 'BearoundSDK'
```

Then run:
```bash
pod install
```

For more information and the latest version, visit: https://cocoapods.org/pods/BearoundSDK

*We recommend keeping the SDK version updated. Check the [releases page](https://github.com/Bearound/bearound-ios-sdk/tags) for the latest versions.



## 🚀 Quick Start

### 1. Initialize the SDK

```swift
import BearoundSDK

class ViewController: UIViewController, BeAroundSDKDelegate {
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Configure the SDK (do this once)
        BeAroundSDK.shared.configure(
            appId: "com.example.app",
            syncInterval: 10  // Sync every 10 seconds
        )
        
        // Set delegate to receive callbacks
        BeAroundSDK.shared.delegate = self
        
        // Start scanning for beacons
        BeAroundSDK.shared.startScanning()
    }
    
    // MARK: - BeAroundSDKDelegate
    
    func didUpdateBeacons(_ beacons: [Beacon]) {
        print("Found \(beacons.count) beacons:")
        beacons.forEach { beacon in
            print("  - \(beacon.major).\(beacon.minor) | RSSI: \(beacon.rssi) | Distance: \(String(format: "%.2f", beacon.accuracy))m")
        }
    }
    
    func didFailWithError(_ error: Error) {
        print("SDK Error: \(error.localizedDescription)")
    }
    
    func didChangeScanning(isScanning: Bool) {
        print("Scanning state: \(isScanning ? "Active" : "Stopped")")
    }
    
    func didUpdateSyncStatus(secondsUntilNextSync: Int, isRanging: Bool) {
        print("Next sync in \(secondsUntilNextSync)s | Ranging: \(isRanging)")
    }
}
```

### 2. Stop Scanning

```swift
BeAroundSDK.shared.stopScanning()
```

☝️ You must request location permissions before starting the SDK — see [Required Permissions](#️-required-permissions) below.

---

## ⚙️ Advanced Configuration

### Periodic Scanning (Battery Efficient)

Enable periodic scanning to save battery by scanning only near sync time:

```swift
BeAroundSDK.shared.configure(
    appId: "com.example.app",
    syncInterval: 30,  // Sync every 30 seconds
    enablePeriodicScanning: true  // Scan only 5s before sync
)
```

**How it works:**
- Scans for 5 seconds before each sync
- Pauses scanning between syncs
- Automatically switches to continuous mode in background
- Great for battery-conscious applications

### Bluetooth Metadata Scanning

Get enhanced beacon information like firmware version, battery level, temperature:

```swift
BeAroundSDK.shared.configure(
    appId: "com.example.app",
    syncInterval: 10,
    enableBluetoothScanning: true  // Enable metadata scanning
)

// Metadata is automatically attached to beacons
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

### User Properties

Attach custom user data to all beacon events:

```swift
let properties = UserProperties(
    internalId: "user-12345",
    email: "user@example.com",
    name: "John Doe",
    customProperties: [
        "tier": "premium",
        "region": "US-West",
        "age_group": "25-34"
    ]
)

BeAroundSDK.shared.setUserProperties(properties)

// Clear user properties when user logs out
BeAroundSDK.shared.clearUserProperties()
```

### Check Scanning State

```swift
if BeAroundSDK.shared.isScanning {
    print("SDK is actively scanning")
}

// Check sync interval
if let interval = BeAroundSDK.shared.currentSyncInterval {
    print("Syncing every \(interval) seconds")
}

// Check if periodic scanning is enabled
if BeAroundSDK.shared.isPeriodicScanningEnabled {
    print("Periodic scanning active")
}
```

### Check Location Permissions

```swift
if BeAroundSDK.isLocationAvailable() {
    let status = BeAroundSDK.authorizationStatus()
    switch status {
    case .authorizedAlways:
        print("✅ Full access - background scanning enabled")
    case .authorizedWhenInUse:
        print("⚠️ Limited access - background scanning disabled")
    case .denied, .restricted:
        print("❌ No access - SDK won't work")
    case .notDetermined:
        print("⏳ Not requested yet")
    @unknown default:
        break
    }
}
```

---

### 🔐 Runtime Permissions

You need to manually request permissions from the user, especially:

- CoreBlutooth (Ask for permission automatically)
- CoreLocation
```swift
import CoreLocation

#Add these next lines on wherever you want, just make sure the app is showing the alert
let locationManager = CLLocationManager()
locationManager.delegate = self
locationManager.requestAlwaysAuthorization()
```
- AppTrackingTransparency
```swift
if #available(iOS 14, *) {
    ATTrackingManager.requestTrackingAuthorization { status in
        switch status {
        case .authorized:
            // User granted permission, you can now access IDFA and track
            print("ATT Authorized")
            // Example: Retrieve IDFA
            let idfa = ASIdentifierManager.shared().advertisingIdentifier
            print("IDFA: \(idfa.uuidString)")
        case .denied:
            // User denied permission, disable tracking functionalities
            print("ATT Denied")
        case .notDetermined:
            // Status is not determined, prompt will be shown
            print("ATT Not Determined")
        case .restricted:
            // Tracking is restricted by system settings (e.g., parental controls)
            print("ATT Restricted")
        @unknown default:
            // Handle future cases
            print("Unknown ATT Status")
        }
    }
}
```

📌 Without these permissions, the SDK will not function properly and will not be able to detect beacons in the background.

---

## 📊 Beacon Data Model

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
    let firmwareVersion: String  // Beacon firmware version
    let batteryLevel: Int        // Battery percentage (0-100)
    let movements: Int           // Movement count
    let temperature: Int         // Temperature in Celsius
    let txPower: Int?            // TX power from BLE
    let rssiFromBLE: Int?        // RSSI from BLE scan
    let isConnectable: Bool?     // Whether beacon is connectable
}
```

---

## 🔍 Monitoring & Debugging

The SDK logs important events with the tag `[BeAroundSDK]`. Look for:

- `[BeAroundSDK] App launched in background (likely by beacon monitoring)`
- `[BeAroundSDK] App entered background - switching to continuous ranging mode`
- `[BeAroundSDK] App entered foreground - restoring periodic mode`
- `[BeAroundSDK] Sending N beacons to {API_URL}/ingest`
- `[BeAroundSDK] Successfully sent N beacons (HTTP 200)`
- `[BeAroundSDK] Failed to send beacons - {error}`
- `[BeAroundSDK] Circuit breaker triggered - API may be down`

---

## 🔄 Background Behavior

The SDK intelligently manages background scanning:

1. **Foreground**: Uses configured mode (periodic or continuous)
2. **Background**: Automatically switches to continuous mode
3. **Background Ranging**: Triggers sync when beacons are detected
4. **Return to Foreground**: Restores original configuration

Background tasks are properly managed with `UIBackgroundTaskIdentifier` to ensure data is synced even when the app is backgrounded.

---

## 🛠️ Building the Framework

To build the XCFramework for distribution:

```bash
./build_framework.sh
```

This creates `build/BearoundSDK.xcframework` containing:
- `ios-arm64` - Physical devices
- `ios-arm64_x86_64-simulator` - Simulators (Intel + Apple Silicon)

The framework can then be distributed via CocoaPods, SPM, or manual integration.

---

## 🧪 Testing

### Requirements
- Physical iOS device with iOS 13+ (recommended) or Simulator
- Physical BLE beacons or beacon simulator (e.g., nRF Connect)
- Location "Always" permission
- Bluetooth enabled

### Test Checklist
- [ ] Foreground beacon detection
- [ ] Background beacon detection
- [ ] API synchronization
- [ ] Periodic scanning mode
- [ ] Bluetooth metadata scanning
- [ ] User properties attachment
- [ ] Error handling and retries
- [ ] App state transitions (background ↔ foreground)

---

## 🔐 Privacy & Security

- Requires explicit user permission for location and Bluetooth
- Respects iOS privacy guidelines
- All beacon data transmitted securely to your API endpoint
- No data stored locally by default
- Comprehensive device telemetry for analytics

---

## 📄 License

MIT License - See [LICENSE](LICENSE) file for details.

---

## 🆘 Support

For issues, feature requests, or questions:
- 📧 Email: support@bearound.com
- 🐛 Issues: [GitHub Issues](https://github.com/bearound/bearound-ios-sdk/issues)
- 📖 Docs: [Full Documentation](https://docs.bearound.com)

---

**Made with ❤️ by Bearound**

