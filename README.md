# 🐻 BearoundSDK for iOS

Official iOS SDK for integrating Bearound's secure BLE beacon detection and indoor location technology.

## 📱 beAround-ios-sdk

Swift SDK for iOS — secure BLE beacon detection and indoor positioning by Bearound.

[![Version](https://img.shields.io/cocoapods/v/BearoundSDK.svg?style=flat)](https://cocoapods.org/pods/BearoundSDK)
[![Platform](https://img.shields.io/cocoapods/p/BearoundSDK.svg?style=flat)](https://cocoapods.org/pods/BearoundSDK)
[![License](https://img.shields.io/cocoapods/l/BearoundSDK.svg?style=flat)](https://cocoapods.org/pods/BearoundSDK)

**Current Version:** 1.3.1

### What's New in 1.3.1

- 🎨 **Modular Architecture**: Complete project reorganization for better maintainability
- ⚙️ **Configurable Sync**: Adjustable sync intervals (5-60 seconds)
- 💾 **Configurable Backup**: Customizable lost beacons backup (5-50 beacons)
- 📊 **Enhanced Telemetry**: Comprehensive device information collection
- 🔋 **Battery Optimized**: Smart location accuracy settings
- ✅ **RSSI Validation**: Improved beacon filtering (-120 to -1 dBm)
- 🧪 **Full Test Coverage**: Comprehensive unit test suite

See [CHANGELOG.md](CHANGELOG.md) for complete release notes.

---

## 📚 Table of Contents

- [Features](#-features)
- [Requirements](#️-requirements)
- [Installation](#-installation)
- [Usage](#-usage)
  - [Initialization](#initialization)
  - [Configuration](#configuration-optional)
  - [Stop Services](#stop-services)
- [Event Listeners](#-event-listeners)
- [Getting Beacon Data](#-getting-beacon-data)
- [Runtime Permissions](#-runtime-permissions)
- [Architecture](#️-architecture)
- [Security & Privacy](#-security--privacy)
- [Testing](#-testing)
- [Device Telemetry](#-device-telemetry)
- [API Synchronization](#-api-synchronization)
- [Troubleshooting](#-troubleshooting)
- [Best Practices](#-best-practices)
- [FAQ](#-faq)
- [Support](#-support)
- [License](#-license)

---

## 🧩 Features

- **Continuous Beacon Detection**: Monitors BLE beacons in real-time using CoreLocation and CoreBluetooth
- **Event Listeners**: Three types of listeners for beacons, sync status, and region tracking
- **Configurable API Synchronization**: Adjustable sync intervals from 5 to 60 seconds (default: 20s)
- **Configurable Backup System**: Customizable lost beacons backup size from 5 to 50 beacons (default: 40)
- **Event Types**: Tracks `enter`, `exit`, and `lost` beacon events
- **Rich Device Telemetry**: Comprehensive device info including battery, network, permissions, and app state
- **Rich Beacon Data**: Captures distance, RSSI, UUID, major/minor, and IDFA
- **Background Support**: Optimized background monitoring with battery-efficient location settings
- **Smart RSSI Validation**: Filters invalid beacons with RSSI validation (-120 to -1 dBm)
- **Active/Inactive Beacon Filtering**: Distinguishes between recently seen and lost beacons
- **Automatic Retry Logic**: Configurable backup system for failed API calls
- **Modular Architecture**: Clean, maintainable code structure with separated concerns
- **Built-in Debug Logging**: Optional debug mode for troubleshooting
- **Comprehensive Test Suite**: Full unit test coverage for reliability

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



### 🚀 Usage

#### Initialization

Initialize the SDK after checking the required permissions:

```swift
import BearoundSDK

// Initialize the SDK
let bearound = Bearound(clientToken: "YOUR_CLIENT_TOKEN", isDebugEnable: true)

// Start beacon detection services
bearound.startServices()
```

#### Configuration (Optional)

Customize the SDK behavior to match your app's needs:

```swift
// Configure sync interval (how often beacons are sent to API)
// Available: .time5, .time10, .time15, .time20 (default), .time25, .time30, 
//            .time35, .time40, .time45, .time50, .time55, .time60
bearound.setSyncInterval(.time20)  // 20 seconds (default)

// Configure backup size for failed API calls
// Available: .size5, .size10, .size15, .size20, .size25, .size30, 
//            .size35, .size40 (default), .size45, .size50
bearound.setBackupSize(.size40)    // 40 beacons (default)

// Get current configuration
let currentInterval = bearound.getSyncInterval()
let currentBackupSize = bearound.getBackupSize()

// Monitor lost beacons backup usage
let lostCount = bearound.getLostBeaconsCount()
print("Lost beacons in backup: \(lostCount)")
```

**Configuration Recommendations:**

| Scenario | Sync Interval | Backup Size | Reason |
|----------|--------------|-------------|---------|
| Real-time tracking | `.time5` - `.time10` | `.size15` - `.size20` | Immediate updates, lower backup needed |
| Standard monitoring | `.time20` - `.time30` | `.size30` - `.size40` | Balanced performance and battery |
| Battery-optimized | `.time40` - `.time60` | `.size40` - `.size50` | Longer intervals, larger backup for reliability |
| Offline-first apps | `.time30` - `.time60` | `.size50` | Handle poor network conditions |

#### Stop Services

To stop beacon detection and API synchronization:

```swift
bearound.stopServices()
```

☝️ You must prompt the user for permissions before initializing the SDK — see example below.

---

## 📡 Event Listeners

The SDK provides three types of listeners to monitor different aspects of beacon detection:

### BeaconListener

Receives callbacks when beacons are detected, lost, or exit the range:

```swift
class MyBeaconListener: BeaconListener {
    func onBeaconsDetected(_ beacons: [Beacon], eventType: String) {
        print("Beacons detected - Event: \(eventType), Count: \(beacons.count)")
        // eventType can be: "enter", "exit", or "failed"
    }
}

// Register the listener
let beaconListener = MyBeaconListener()
bearound.addBeaconListener(beaconListener)

// Remove when no longer needed
bearound.removeBeaconListener(beaconListener)
```

### SyncListener

Monitors API synchronization status for beacon events:

```swift
class MySyncListener: SyncListener {
    func onSyncSuccess(eventType: String, beaconCount: Int, message: String) {
        print("Sync successful - Type: \(eventType), Beacons: \(beaconCount)")
    }

    func onSyncError(eventType: String, beaconCount: Int, errorCode: Int?, errorMessage: String) {
        print("Sync failed - Error: \(errorMessage)")
    }
}

// Register the listener
let syncListener = MySyncListener()
bearound.addSyncListener(syncListener)

// Remove when no longer needed
bearound.removeSyncListener(syncListener)
```

### RegionListener

Tracks when the device enters or exits beacon regions:

```swift
class MyRegionListener: RegionListener {
    func onRegionEnter(regionName: String) {
        print("Entered region: \(regionName)")
    }

    func onRegionExit(regionName: String) {
        print("Exited region: \(regionName)")
    }
}

// Register the listener
let regionListener = MyRegionListener()
bearound.addRegionListener(regionListener)

// Remove when no longer needed
bearound.removeRegionListener(regionListener)
```

---

## 📊 Getting Beacon Data

### Get Active Beacons

Returns only beacons detected within the last 5 seconds:

```swift
let activeBeacons = bearound.getActiveBeacons()
print("Active beacons: \(activeBeacons.count)")

for beacon in activeBeacons {
    print("Beacon: \(beacon.bluetoothName)")
    print("  RSSI: \(beacon.rssi) dBm")
    print("  Distance: \(beacon.distanceMeters ?? 0) meters")
    print("  Major: \(beacon.major), Minor: \(beacon.minor)")
}
```

### Get All Beacons

Returns all detected beacons (including recently lost ones):

```swift
let allBeacons = bearound.getAllBeacons()
print("Total beacons: \(allBeacons.count)")
```

### Beacon Data Structure

Each beacon contains the following information:

```swift
public struct Beacon {
    let uuid: UUID                    // Beacon UUID (default: E25B8D3C-947A-452F-A13F-589CB706D2E5)
    let major: String                 // Major identifier
    let minor: String                 // Minor identifier
    var rssi: Int                     // Signal strength (-120 to -1 dBm)
    let bluetoothName: String         // Beacon name (format: "B:...")
    var bluetoothAddress: String?     // MAC address (optional)
    var distanceMeters: Float?        // Approximate distance in meters
    var lastSeen: Date                // Last detection timestamp
}
```

**RSSI to Distance Mapping:**
- `-50 to -60 dBm`: Very close (< 1 meter)
- `-60 to -70 dBm`: Close (1-3 meters)
- `-70 to -80 dBm`: Medium range (3-7 meters)
- `-80 to -90 dBm`: Far (7-15 meters)
- `-90 to -100 dBm`: Very far (> 15 meters)

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

## 🐛 Troubleshooting

### Debug Logging

Enable debug mode to see detailed SDK logs:

```swift
let bearound = Bearound(clientToken: "YOUR_TOKEN", isDebugEnable: true)
```

Look for logs with the tag `[BeAroundSDK]` in Xcode console.

### Common Issues

**No beacons detected:**
- ✅ Check that Bluetooth and Location permissions are granted
- ✅ Verify beacons are broadcasting (use nRF Connect to test)
- ✅ Ensure beacons use UUID: `E25B8D3C-947A-452F-A13F-589CB706D2E5`
- ✅ Check that beacon names start with "B:"
- ✅ Confirm device Bluetooth is enabled

**Beacons not syncing to API:**
- ✅ Verify `clientToken` is correct
- ✅ Check network connectivity
- ✅ Review `SyncListener` for error messages
- ✅ Ensure beacons have valid RSSI (-120 to -1 dBm)
- ✅ Check lost beacons backup: `getLostBeaconsCount()`

**Background detection issues:**
- ✅ Verify `UIBackgroundModes` in Info.plist includes `location` and `bluetooth-central`
- ✅ Request `Always` location authorization, not just `WhenInUse`
- ✅ Enable "Background App Refresh" in device settings
- ✅ Note: iOS may limit background scanning to save battery

**High battery usage:**
- ✅ Increase sync interval: `setSyncInterval(.time40)` or higher
- ✅ SDK already uses optimized location accuracy (`kCLLocationAccuracyThreeKilometers`)
- ✅ Consider stopping services when not needed
- ✅ Monitor active beacons vs. total beacons ratio

---

## 💡 Best Practices

1. **Permission Handling**
   - Request permissions before initializing SDK
   - Explain to users why permissions are needed
   - Handle permission denial gracefully

2. **Configuration**
   - Use default settings (20s sync, 40 beacons backup) for most cases
   - Lower sync interval only when real-time tracking is critical
   - Increase backup size for offline-capable apps

3. **Listeners**
   - Always remove listeners when no longer needed to prevent memory leaks
   - Use weak references in listener implementations
   - Handle both success and error cases in `SyncListener`

4. **Testing**
   - Test with debug mode enabled first
   - Verify beacon detection in both foreground and background
   - Monitor battery usage during extended testing
   - Test with poor network conditions

5. **Production**
   - Disable debug mode in production builds
   - Monitor `getLostBeaconsCount()` to detect API issues
   - Implement proper error handling for all listener callbacks
   - Keep SDK version updated

---

## 🔄 API Synchronization

### How it Works

- Beacons are sent to your API at the configured sync interval (default: 20s)
- Failed requests are stored in a backup queue (default: 40 beacons max)
- The SDK automatically retries failed requests
- Each beacon includes comprehensive device telemetry

### Payload Format

```json
{
  "clientToken": "your-token-here",
  "beacons": [
    {
      "uuid": "E25B8D3C-947A-452F-A13F-589CB706D2E5",
      "name": "B:1.0_1000.2000_100_0_20",
      "rssi": -63,
      "approxDistanceMeters": 1.8,
      "txPower": -59
    }
  ],
  "sdk": {
    "version": "1.3.1",
    "platform": "ios",
    "appId": "com.example.app",
    "build": 210
  },
  "userDevice": {
    "manufacturer": "Apple",
    "model": "iPhone 13",
    "os": "ios",
    "osVersion": "17.2",
    "batteryLevel": 0.78,
    "isCharging": false,
    "bluetoothState": "on",
    "networkType": "wifi",
    ...
  },
  "scanContext": {
    "scanSessionId": "scan_98DF10",
    "detectedAt": 1735940400000
  }
}
```

---

## 🏗️ Architecture

The SDK follows a modular architecture for better maintainability and extensibility:

```
BearoundSDK/
├── Configuration/      # SDK configuration and constants
│   ├── Constants.swift
│   └── SyncConfiguration.swift
├── Core/              # Core SDK functionality
│   ├── BearoundSDK.swift
│   └── DeviceInfoService.swift
├── Models/            # Data models
│   ├── Beacon.swift
│   ├── IngestPayload.swift
│   └── Session.swift
├── Networking/        # API communication
│   └── APIService.swift
├── Protocols/         # Protocol definitions
│   ├── BeaconActionsDelegate.swift
│   └── BeaconListeners.swift
├── Scanning/          # Beacon scanning functionality
│   ├── BeaconParser.swift
│   ├── BeaconScanner.swift
│   └── BeaconTracker.swift
└── Utils/             # Utility classes
    └── DebuggerHelper.swift
```

**Key Components:**

- **Core**: Main SDK class and device information service
- **Scanning**: BLE beacon detection using CoreBluetooth and CoreLocation
- **Networking**: API communication with automatic retry logic
- **Models**: Data structures for beacons and API payloads
- **Configuration**: Customizable sync intervals and backup sizes
- **Protocols**: Listener interfaces for extensibility

---

## 🔐 Security & Privacy

- **Privacy-First**: No data collection without explicit user consent
- **Permission-Based**: Respects iOS permission system
- **Secure API Communication**: HTTPS endpoints with token authentication
- **IDFA Compliance**: Follows iOS 14+ App Tracking Transparency guidelines
- **Background Optimization**: Battery-efficient location accuracy settings
- **Data Validation**: RSSI filtering and beacon validation before transmission

---

## 🧪 Testing

The SDK includes a comprehensive test suite covering:

- ✅ Beacon detection and validation
- ✅ Configuration management (sync intervals, backup sizes)
- ✅ API payload creation and validation
- ✅ Device information collection
- ✅ IDFA handling and permissions
- ✅ Session management
- ✅ Listener registration and callbacks

**Manual Testing:**

- Use physical BLE beacons or nRF Connect app
- Enable debug mode to see detailed logs
- Ensure all runtime permissions are granted
- Test in both foreground and background modes
- Monitor battery usage in Settings → Battery

**Running Unit Tests:**

```bash
xcodebuild -project BearoundSDK.xcodeproj \
  -scheme BearoundSDKTests \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  test
```

---

## 📊 Device Telemetry

The SDK automatically collects comprehensive device information (with user consent):

**SDK Info:**
- Version, platform, app ID, build number

**Device Info:**
- Model, manufacturer, OS version
- Battery level, charging status, low power mode
- Network type (WiFi, Cellular, Ethernet)
- Cellular generation (2G, 3G, 4G, 5G)
- Bluetooth state, roaming status

**Permissions:**
- Location permission and accuracy level
- Notification permission status

**App State:**
- Foreground/background status
- App uptime, cold start detection

**Beacon Context:**
- RSSI, TX Power, approximate distance
- Scan session ID, detection timestamp

---

## ❓ FAQ

**Q: What iOS versions are supported?**  
A: iOS 13.0 and above.

**Q: Can I use a different beacon UUID?**  
A: Currently, the SDK is configured for UUID `E25B8D3C-947A-452F-A13F-589CB706D2E5`. Custom UUIDs may be supported in future versions.

**Q: How many beacons can be detected simultaneously?**  
A: There's no hard limit, but iOS may limit BLE connections. The SDK handles hundreds of beacons efficiently.

**Q: Does the SDK work offline?**  
A: Beacon detection works offline. API sync requires network connectivity, but failed requests are backed up and retried automatically.

**Q: How much battery does the SDK consume?**  
A: The SDK is optimized for battery efficiency with configurable intervals. Typical usage: < 5% additional battery drain per day.

**Q: Can I track beacons from multiple apps?**  
A: Each app instance runs independently. Beacons are tracked per app installation.

**Q: Is the SDK compatible with SwiftUI?**  
A: Yes! The SDK works seamlessly with both UIKit and SwiftUI projects.

**Q: How do I migrate from an older version?**  
A: See [CHANGELOG.md](CHANGELOG.md) for migration guides and breaking changes.

---

## 📖 Complete Example

Here's a complete example showing best practices:

```swift
import UIKit
import BearoundSDK
import CoreLocation
import AppTrackingTransparency

class BeaconViewController: UIViewController {
    
    private var bearound: Bearound?
    private let locationManager = CLLocationManager()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        requestPermissions()
    }
    
    private func requestPermissions() {
        // Request Location Permission
        locationManager.delegate = self
        locationManager.requestAlwaysAuthorization()
        
        // Request Tracking Permission (iOS 14+)
        if #available(iOS 14, *) {
            ATTrackingManager.requestTrackingAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    self?.initializeSDK()
                }
            }
        } else {
            initializeSDK()
        }
    }
    
    private func initializeSDK() {
        // Initialize SDK with debug mode
        bearound = Bearound(clientToken: "YOUR_CLIENT_TOKEN", isDebugEnable: true)
        
        // Configure sync behavior
        bearound?.setSyncInterval(.time20)  // 20 seconds
        bearound?.setBackupSize(.size40)    // 40 beacons backup
        
        // Register listeners
        bearound?.addBeaconListener(self)
        bearound?.addSyncListener(self)
        bearound?.addRegionListener(self)
        
        // Start services
        bearound?.startServices()
        
        print("✅ BearoundSDK initialized successfully")
    }
    
    deinit {
        // Clean up listeners
        if let bearound = bearound {
            bearound.removeBeaconListener(self)
            bearound.removeSyncListener(self)
            bearound.removeRegionListener(self)
            bearound.stopServices()
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension BeaconViewController: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        print("Location authorization: \(status.rawValue)")
    }
}

// MARK: - BeaconListener

extension BeaconViewController: BeaconListener {
    func onBeaconsDetected(_ beacons: [Beacon], eventType: String) {
        print("📡 Beacons detected - Event: \(eventType), Count: \(beacons.count)")
        
        for beacon in beacons {
            print("  • \(beacon.bluetoothName) | RSSI: \(beacon.rssi) dBm")
            if let distance = beacon.distanceMeters {
                print("    Distance: ~\(String(format: "%.1f", distance))m")
            }
        }
        
        // Update UI or trigger app logic
        DispatchQueue.main.async {
            // Update your UI here
        }
    }
}

// MARK: - SyncListener

extension BeaconViewController: SyncListener {
    func onSyncSuccess(eventType: String, beaconCount: Int, message: String) {
        print("✅ Sync successful - Type: \(eventType), Beacons: \(beaconCount)")
    }
    
    func onSyncError(eventType: String, beaconCount: Int, errorCode: Int?, errorMessage: String) {
        print("❌ Sync failed - Error: \(errorMessage)")
        
        // Check backup status
        if let lostCount = bearound?.getLostBeaconsCount() {
            print("📦 Lost beacons in backup: \(lostCount)")
        }
    }
}

// MARK: - RegionListener

extension BeaconViewController: RegionListener {
    func onRegionEnter(regionName: String) {
        print("🚪 Entered region: \(regionName)")
        // Trigger notification or app-specific logic
    }
    
    func onRegionExit(regionName: String) {
        print("🚶 Exited region: \(regionName)")
        // Clean up region-specific resources
    }
}
```

---

## 🤝 Support

- **Issues**: [GitHub Issues](https://github.com/Bearound/bearound-ios-sdk/issues)
- **Documentation**: [API Reference](https://cocoapods.org/pods/BearoundSDK)
- **Changelog**: [CHANGELOG.md](CHANGELOG.md)

---

## 📄 License

MIT © Bearound

See [LICENSE](LICENSE) file for details.

---

## 🔗 Links

- [CocoaPods](https://cocoapods.org/pods/BearoundSDK)
- [GitHub Repository](https://github.com/Bearound/bearound-ios-sdk)
- [Release Notes](https://github.com/Bearound/bearound-ios-sdk/releases)
- [Bearound Website](https://bearound.com)

---

**Made with ❤️ by Bearound**

