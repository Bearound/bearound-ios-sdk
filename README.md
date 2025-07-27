# 🐻 BeAround SDKs Documentation

Official SDKs for integrating Bearound's secure BLE beacon detection and indoor location technology across Android, iOS, React Native, and Flutter.

## 📱 beAround-ios-sdk

Swift SDK for iOS — secure BLE beacon detection and indoor positioning by Bearound.

## 🧩 Features

- Continuous region monitoring for beacons
- Sends `enter` and `exit` events to a remote API
- Captures distance, RSSI, UUID, major/minor, Advertising ID
- Foreground service support for background execution
- Sends telemetry data (if available)
- Built-in debug logging with tag BeAroundSdk

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
```

And in case you want to run it on background mode add the following:
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

So far the sdk only supports SPM installation, to move forward you must add the following URL to your package dependencies:
https://github.com/Bearound/bearound-ios-sdk.git <br>
*We recommend you to keep the sdk version updated always as possible, to find the newest versions, check for the latest tags on the sdk repository <br>
In case your xcode is not configured with your github access, you must do it, since the repository is private. <br><br>

Here are the steps visually:<br>
- In order to add your your github account to xcode you need to have an AccessToken, generated on github. You should go to your github account settings page > Developer Settings > Personal Access Tokens > [Token classic]([https://exemplo.com](https://github.com/settings/tokens)). We recommend to enable all options, however the only write and read access are needed.
<img width="1034" height="433" alt="Screenshot 2025-07-27 at 13 14 04" src="https://github.com/user-attachments/assets/ebf05708-e20f-4c2a-83c4-7665b65d3557" />

- Add github account to xcode, first add your github account to xcode, open xcode preferences and goes to Accounts tab (Don't worry, you can have more than one synced at once)
<img width="733" height="488" alt="Screenshot 2025-07-27 at 13 02 57" src="https://github.com/user-attachments/assets/657fb5eb-9c21-432b-97b2-dc80f5a85a72" />

- Use your github token in order to connect your account to xcode
<img width="736" height="489" alt="Screenshot 2025-07-27 at 13 18 06" src="https://github.com/user-attachments/assets/180ae951-e70b-4bac-b66e-8196483d4608" />

- Add the package to your project
<img width="1524" height="470" alt="Screenshot 2025-07-27 at 13 23 47" src="https://github.com/user-attachments/assets/0bc4d725-5b45-4e51-83a5-ee3ecf3189e6" />

- Use the given URL and select the desired version
<img width="967" height="542" alt="Screenshot 2025-07-27 at 13 25 22" src="https://github.com/user-attachments/assets/b1c3add3-0137-4264-9b29-4b1628221f04" />



### Initialization
Initialize the SDK inside your Application class after checking the required permissions:

```swift
import BeAround

#Add this next line on wherever you want
Bearound(clientToken: "", isDebugEnable: true).startServices()
```
☝️ You must prompt the user for permissions before initializing the SDK — see example below.

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

