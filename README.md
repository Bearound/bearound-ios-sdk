# 🐻 BeAround SDKs Documentation

Official SDKs for integrating Bearound's secure BLE beacon detection and indoor location technology across Android, iOS, React Native, and Flutter.

## 📱 beAround-ios-sdk

Swift SDK for iOS — secure BLE beacon detection and indoor positioning by Bearound.

## 🧩 Features

- **Continuous Beacon Detection**: Monitors BLE beacons in real-time using CoreLocation and CoreBluetooth
- **Event Listeners**: Three types of listeners for beacons, sync status, and region tracking
- **Automatic API Synchronization**: Sends beacon data every 5 seconds to remote API
- **Event Types**: Tracks `enter`, `exit`, and `lost` beacon events
- **Rich Beacon Data**: Captures distance, RSSI, UUID, major/minor, and IDFA
- **Background Support**: Continues monitoring beacons when app is in background
- **Active/Inactive Beacon Filtering**: Distinguishes between recently seen and lost beacons
- **Retry Logic**: Automatically retries failed API calls (up to 10 beacons)
- **Built-in Debug Logging**: Optional debug mode for troubleshooting

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
```

### Get All Beacons

Returns all detected beacons (including recently lost ones):

```swift
let allBeacons = bearound.getAllBeacons()
print("Total beacons: \(allBeacons.count)")
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

### ⚠️ After initializing it, it starts executing the service, you can follow this by activating the debug and looking at the Logs with the TAG: BeAroundSdk

- The SDK automatically monitors beacons with the UUID
- When entering or exiting beacon regions, it sends a JSON payload to the remote API.
- Events include beacon identifiers, RSSI, distance, app state (foreground/background/inactive), Bluetooth details, and IDFA.

### 🔐 Security

- AES-GCM encrypted payloads
- Obfuscated beacon identifiers
- Privacy-first architecture

### 🧪 Testing

- Use physical beacons or nRF Connect
- Check logs
- Ensure runtime permissions are granted

### 📄 License

MIT © Bearound

