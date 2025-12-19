# ``BearoundSDK``

Swift SDK for iOS — secure BLE beacon detection and indoor positioning by Bearound.

## Overview

BearoundSDK provides secure BLE beacon detection and indoor location technology for iOS applications. The SDK offers continuous region monitoring, automatic event handling, and secure data transmission with built-in encryption and privacy features.

**Current Version:** 1.3.0

## Topics

### Features

- Continuous region monitoring for beacons
- Sends `enter` and `exit` events to a remote API  
- Captures distance, RSSI, UUID, major/minor, Advertising ID
- **Comprehensive device telemetry** including battery, network, memory, and system info
- Foreground service support for background execution
- Built-in debug logging with tag BeAroundSdk
- Support for both legacy and enhanced ingest payload formats

### Requirements

- **Minimum iOS version**: 13
- **Location or Bluetooth** must be enabled on the device

### Installation

The SDK supports SPM installation. Add the following URL to your package dependencies:
```
https://github.com/Bearound/bearound-ios-sdk.git
```

**Note**: Keep the SDK version updated. Check for the latest tags on the SDK repository. Since the repository is private, ensure your Xcode is configured with GitHub access using a Personal Access Token.

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

#### Initialization

The SDK uses a singleton pattern and must be configured before use:

```swift
import BeAround

// Configure the SDK (call this once, typically in your AppDelegate or App struct)
Bearound.configure(clientToken: "your_client_token", isDebugEnable: true)

// Request permissions using async/await (iOS 13+)
await Bearound.shared.requestPermissions()

// Start services
Bearound.shared.startServices()
```

**Important Notes:**
- The SDK **must** be configured using `Bearound.configure()` before accessing `Bearound.shared`
- `configure()` can only be called once. Subsequent calls will return the existing instance with a warning.
- Always prompt the user for permissions before initializing the SDK.

#### Resetting the SDK (Testing Only)

For testing purposes, you can reset the SDK instance:

```swift
// ⚠️ Use with caution - stops all services and clears the instance
Bearound.reset()
```

#### Runtime Permissions

Request the following permissions from the user:

**Core Location:**
```swift
import CoreLocation

let locationManager = CLLocationManager()
locationManager.delegate = self
locationManager.requestAlwaysAuthorization()
```

**App Tracking Transparency:**
```swift
import AppTrackingTransparency
import AdSupport

if #available(iOS 14, *) {
    ATTrackingManager.requestTrackingAuthorization { status in
        switch status {
        case .authorized:
            print("ATT Authorized")
            // Use the SDK's safe accessor for IDFA
            let idfa = Bearound.shared.currentIDFA()
            print("IDFA: \(idfa)")
        case .denied:
            print("ATT Denied")
        case .notDetermined:
            print("ATT Not Determined")
        case .restricted:
            print("ATT Restricted")
        @unknown default:
            print("Unknown ATT Status")
        }
    }
}
```

**Using the SDK's IDFA Accessor:**
```swift
// Safe accessor - returns empty string if not authorized
let idfa = Bearound.shared.currentIDFA()
if !idfa.isEmpty {
    print("IDFA available: \(idfa)")
} else {
    print("IDFA not available or not authorized")
}
```

### Enhanced Device Telemetry

The SDK now collects comprehensive device information automatically, including:

#### SDK Information
- Version
- Platform (iOS)
- App ID (Bundle identifier)
- Build number

#### Device Information
- Manufacturer (Apple)
- Device model (e.g., iPhone 13, iPad Pro)
- OS version
- Timezone
- Battery level and charging status
- Low power mode status
- Bluetooth state
- Location permissions and accuracy
- Notification permissions
- Network type (WiFi, Cellular, Ethernet)
- Cellular generation (2G, 3G, 4G, 5G)
- Roaming status
- Memory (RAM) information
- Screen resolution
- Advertising ID (IDFA) and tracking status
- App state (foreground/background)
- App uptime
- Cold start detection

#### Scan Context
- RSSI (signal strength)
- TX Power
- Approximate distance in meters
- Scan session ID
- Detection timestamp

### Using the Enhanced Ingest Payload

To send beacons with full device telemetry:

```swift
// Get currently active beacons (last seen within 5 seconds)
let activeBeacons = Bearound.shared.getActiveBeacons()

// Get all beacons (including recently lost ones)
let allBeacons = Bearound.shared.getAllBeacons()

// Send with full device info
await Bearound.shared.sendBeaconsWithFullInfo(activeBeacons) { result in
    switch result {
    case .success(let data):
        print("Beacons sent successfully with full telemetry")
    case .failure(let error):
        print("Error sending beacons: \(error.localizedDescription)")
    }
}
```

### Checking Scanning Status

You can check if the SDK is currently scanning:

```swift
if Bearound.shared.isCurrentlyScanning() {
    print("SDK is actively scanning for beacons")
} else {
    print("SDK is not scanning")
}
```

### Manually Creating Ingest Payloads

You can also create payloads manually for custom processing:

```swift
// Create a complete ingest payload
let payload = await Bearound.shared.createIngestPayload(for: activeBeacons)

// The payload includes:
// - beacons: Array of beacon data (uuid, name, rssi, approxDistanceMeters, txPower)
// - sdk: SDK information
// - userDevice: Complete device telemetry
// - scanContext: Scan session details

// Use the payload as needed (send to API, store locally, etc.)
```

### Listening to Beacon Events

The SDK provides several listener protocols for monitoring beacon activity:

#### BeaconListener
```swift
class MyBeaconHandler: BeaconListener {
    func onBeaconsDetected(_ beacons: [Beacon], eventType: String) {
        print("Beacons detected: \(beacons.count), event: \(eventType)")
    }
}

let handler = MyBeaconHandler()
Bearound.shared.addBeaconListener(handler)

// Remove when no longer needed
Bearound.shared.removeBeaconListener(handler)
```

#### SyncListener
```swift
class MySyncHandler: SyncListener {
    func onSyncSuccess(eventType: String, beaconCount: Int, message: String) {
        print("Sync successful: \(message)")
    }
    
    func onSyncError(eventType: String, beaconCount: Int, errorCode: Int?, errorMessage: String) {
        print("Sync failed: \(errorMessage)")
    }
}

let syncHandler = MySyncHandler()
Bearound.shared.addSyncListener(syncHandler)

// Remove when no longer needed
Bearound.shared.removeSyncListener(syncHandler)
```

#### RegionListener
```swift
class MyRegionHandler: RegionListener {
    func onRegionEnter(regionName: String) {
        print("Entered region: \(regionName)")
    }
    
    func onRegionExit(regionName: String) {
        print("Exited region: \(regionName)")
    }
}

let regionHandler = MyRegionHandler()
Bearound.shared.addRegionListener(regionHandler)

// Remove when no longer needed
Bearound.shared.removeRegionListener(regionHandler)
```

### Security Features

- AES-GCM encrypted payloads
- Obfuscated beacon identifiers  
- Privacy-first architecture
- IDFA only collected with user consent (ATT)
- Location data protected by iOS permissions

### Testing

- Use physical beacons or nRF Connect app
- Check logs with tag "BeAroundSdk"
- Ensure runtime permissions are granted
- Test in both foreground and background modes

### How It Works

- The SDK automatically monitors beacons with the configured UUID
- When entering or exiting beacon regions, it sends JSON payload to the remote API
- Events include beacon identifiers, RSSI, distance, comprehensive device telemetry
- All data collection respects user privacy settings and iOS permissions

### Device Info Service

The `DeviceInfoService` is a singleton that collects device telemetry:

```swift
// Access the shared instance
let deviceService = DeviceInfoService.shared

// Get SDK info (uses BeAroundSDKConfig.version automatically)
let sdkInfo = deviceService.getSDKInfo()

// Or specify a custom version if needed
let customSdkInfo = deviceService.getSDKInfo(version: "1.2.0")

// Get user device info (async)
let deviceInfo = await deviceService.getUserDeviceInfo()

// Create scan context for a beacon
let scanContext = deviceService.createScanContext(
    rssi: -63,
    txPower: -59,
    approxDistanceMeters: 1.8
)

// Generate a new scan session ID
deviceService.generateNewScanSession()

// Mark that cold start has completed
deviceService.markWarmStart()
```

### SDK Version Management

The SDK version is centrally managed in `Constants.swift`:

```swift
// ✅ CORRECT: Always use BeAroundSDKConfig.version
let version = BeAroundSDKConfig.version // "1.3.0"

// ✅ SDK name and log tag are also available
let sdkName = BeAroundSDKConfig.name // "BeAroundSDK"
let logTag = BeAroundSDKConfig.logTag // "[BeAroundSDK]"
```

**Important:** To update the SDK version, only modify `BeAroundSDKConfig.version` in `Constants.swift`. All other parts of the SDK will automatically use the updated version.

**Deprecated APIs:**
```swift
// ⚠️ Deprecated: Don't use these
let oldVersion1 = SDK.version // Deprecated
let oldVersion2 = DesignSystemVersion.current // Deprecated
```

### API Payload Format

The enhanced ingest payload follows this structure:

```json
{
  "beacons": [
    {
      "uuid": "E25B8D3C-947A-452F-A13F-589CB706D2E5",
      "name": "B:FIRMWARE_MAJOR.MINOR_BATTERY_MOVEMENTS_TEMPERATURE",
      "rssi": -63,
      "approxDistanceMeters": 1.8,
      "txPower": -59
    }
  ],
  "sdk": {
    "version": "1.3.0",
    "platform": "ios",
    "appId": "com.shop.app",
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
    "bluetoothState": "on",
    "locationPermission": "authorized_when_in_use",
    "locationAccuracy": "full",
    "notificationsPermission": "authorized",
    "networkType": "wifi",
    "cellularGeneration": "4g",
    "isRoaming": false,
    "connectionExpensive": false,
    "ramTotalMb": 4096,
    "ramAvailableMb": 1280,
    "screenWidth": 1170,
    "screenHeight": 2532,
    "advertisingId": "idfa_or_aaid",
    "adTrackingEnabled": true,
    "appInForeground": true,
    "appUptimeMs": 12345,
    "coldStart": false
  },
  "scanContext": {
    "rssi": -63,
    "txPower": -59,
    "approxDistanceMeters": 1.8,
    "scanSessionId": "scan_98DF10",
    "detectedAt": 1735940400000
  }
}
```

**Note:** Only beacons with valid Bluetooth names starting with `"B:"` will be included in the payload. Beacons without proper names are automatically filtered out.

### License

MIT © Bearound
