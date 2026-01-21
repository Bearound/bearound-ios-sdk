# 🐻 ``BearoundSDK``

Swift SDK for iOS — secure BLE beacon detection and indoor positioning by Bearound.

## Overview

BearoundSDK provides BLE beacon detection and indoor location technology for iOS applications. The SDK offers real-time beacon monitoring, delegate-based event callbacks, automatic API synchronization, and comprehensive device telemetry.

**Current Version:** 2.2.0

> **Version 2.0.1 Breaking Changes**: Complete SDK rewrite with new architecture. See migration guide below.

## Topics

### Features

- **Real-time Beacon Detection**: Continuous monitoring using CoreLocation and CoreBluetooth
- **Delegate-Based Architecture**: Clean, protocol-based event handling with `BeAroundSDKDelegate`
- **Automatic API Synchronization**: Configurable sync intervals for beacon data
- **Periodic Scanning Mode**: Battery-efficient scanning with configurable scan/pause durations
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
pod 'BearoundSDK', '~> 2.2'
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
<string>Precisamos da sua localização para mostrar conteúdos próximos.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Precisamos da sua localização mesmo em segundo plano para enviar notificações relevantes.</string>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Este aplicativo precisa acessar o Bluetooth para se conectar a dispositivos próximos.</string>
<key>NSUserTrackingUsageDescription</key>
<string>Precisamos do seu consentimento para rastrear sua atividade e oferecer uma experiência personalizada.</string>
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

**Important**: The user must allow at least location or Bluetooth access for the SDK to function properly.

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
            businessToken: "your-business-token-here",
            syncInterval: 10  // Sync every 10 seconds
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

#### Periodic Scanning (Battery Efficient)

Enable periodic scanning to save battery:

```swift
BeAroundSDK.shared.configure(
    businessToken: "your-business-token-here",
    syncInterval: 30,  // Sync every 30 seconds
    enablePeriodicScanning: true  // Scan only 5s before sync
)
// Note: appId is automatically extracted from your app's Bundle Identifier
```

**How it works:**
- Scans for 5 seconds before each sync interval
- Pauses scanning between sync times
- Automatically switches to continuous mode in background
- Ideal for battery-conscious applications

#### Bluetooth Metadata Scanning

Get enhanced beacon information (firmware, battery, temperature):

```swift
BeAroundSDK.shared.configure(
    appId: "com.example.app",
    syncInterval: 10,
    enableBluetoothScanning: true  // Enable metadata
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

#### User Properties

Attach custom user data to beacon events:

```swift
let properties = UserProperties(
    internalId: "user-12345",
    email: "user@example.com",
    name: "John Doe",
    customProperties: [
        "tier": "premium",
        "region": "US-West"
    ]
)

BeAroundSDK.shared.setUserProperties(properties)

// Clear when user logs out
BeAroundSDK.shared.clearUserProperties()
```

#### Checking SDK State

```swift
// Check if scanning
if BeAroundSDK.shared.isScanning {
    print("SDK is scanning")
}

// Check sync interval
if let interval = BeAroundSDK.shared.currentSyncInterval {
    print("Syncing every \(interval)s")
}

// Check periodic mode
if BeAroundSDK.shared.isPeriodicScanningEnabled {
    print("Periodic scanning active")
}
```

### Device Telemetry (Collected Automatically)

The SDK automatically collects comprehensive device information:

#### SDK Information
- Version (2.0.0)
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

### Error Handling & Retry Logic

The SDK includes robust error handling:

- **Circuit Breaker**: After 10 consecutive API failures, triggers alert
- **Retry Queue**: Stores up to 10 failed beacon batches for retry
- **Exponential Backoff**: Retries with delays: 5s, 10s, 20s, 40s (max 60s)
- **Automatic Recovery**: Resumes normal operation when API recovers

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

### Security & Privacy

- Requires explicit user permission for location and Bluetooth
- Respects iOS privacy guidelines
- All beacon data transmitted to your configured API endpoint with secure business token authentication
- Authorization header sent as `Authorization: {businessToken}` (no Bearer prefix)
- No local data storage by default
- IDFA collected only with user consent (ATT framework)
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
- [ ] Periodic scanning mode
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

**New API (v2.0):**
```swift
import BearoundSDK

class MyViewController: BeAroundSDKDelegate {
    func setup() {
        BeAroundSDK.shared.configure(
            businessToken: "your-business-token-here",
            syncInterval: 10
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
3. **Configuration**: Use `configure(businessToken:syncInterval:)` instead of initializer
   - **businessToken parameter is now required**: Pass your business API token directly
   - **appId removed**: Now automatically extracted from `Bundle.main.bundleIdentifier`
   - **Authorization header**: Token sent as `Authorization: {businessToken}` (no Bearer prefix)
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
    "version": "2.2.0",
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
            syncInterval: 30,
            enableBluetoothScanning: true,  // Get battery, firmware, etc.
            enablePeriodicScanning: true    // Save battery
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

### Support

For issues, feature requests, or questions:
- 📧 Email: support@bearound.com
- 🐛 Issues: GitHub Issues
- 📖 Docs: Full documentation at docs.bearound.com

### License

MIT © Bearound
