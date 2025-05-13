# 🐻 Bearound SDKs Documentation

Official SDKs for integrating Bearound's secure BLE beacon detection and indoor location.

## 🍏 bearound-ios-sdk

Swift SDK for iOS — secure beacon proximity events and indoor location.

### 📦 Installation

Via Swift Package Manager:

```swift
.package(url: "https://github.com/bearound/bearound-ios-sdk.git", from: "1.0.0")
```

Or via CocoaPods:

```ruby
pod 'BearoundSDK'
```

### ⚙️ Required Permissions

Add to Info.plist:

- NSBluetoothAlwaysUsageDescription
- NSLocationWhenInUseUsageDescription

### 🚀 Features

- Beacon scanning using CoreBluetooth + CoreLocation
- Geofence-based proximity detection
- AES-GCM encryption
- iOS 12+ support, macOS Catalyst compatible

### 🛠️ Usage

```swift
BeaconDetector.shared.startScanning { beacon in
    print("Detected \(beacon.identifier) at \(beacon.distance)m")
}
```

### 🔐 Security

- End-to-end encrypted payloads
- Minimal local processing
- No analytics or tracking

### 🧪 Testing

- Test with real BLE beacons or simulators
- Enable Location & Bluetooth in Settings
- Ensure Info.plist is configured properly

### 📄 License

MIT © Bearound
