# ``BearoundSDK``

Swift SDK for iOS — secure BLE beacon detection and indoor positioning by Bearound.

## Overview

BearoundSDK provides secure BLE beacon detection and indoor location technology for iOS applications. The SDK offers continuous region monitoring, automatic event handling, and secure data transmission with built-in encryption and privacy features.

## Topics

### Features

- Continuous region monitoring for beacons
- Sends `enter` and `exit` events to a remote API  
- Captures distance, RSSI, UUID, major/minor, Advertising ID
- Foreground service support for background execution
- Sends telemetry data (if available)
- Built-in debug logging with tag BeAroundSdk

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

Initialize the SDK after checking required permissions:

```swift
import BeAround

Bearound(clientToken: "", isDebugEnable: true).startServices()
```

**Note**: Prompt the user for permissions before initializing the SDK.

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
            let idfa = ASIdentifierManager.shared().advertisingIdentifier
            print("IDFA: \(idfa.uuidString)")
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

### Security Features

- AES-GCM encrypted payloads
- Obfuscated beacon identifiers  
- Privacy-first architecture

### Testing

- Use physical beacons or nRF Connect app
- Check logs with tag "BeAroundSdk"
- Ensure runtime permissions are granted

### How It Works

- The SDK automatically monitors beacons with the configured UUID
- When entering or exiting beacon regions, it sends JSON payload to the remote API
- Events include beacon identifiers, RSSI, distance, app state (foreground/background/inactive), Bluetooth details, and IDFA

### License

MIT © Bearound