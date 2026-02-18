# Prompt: Replicate BeAroundScan iOS App + BearoundSDK for Android

> **Target model:** Claude Opus 4.6
> **Language:** Kotlin
> **UI:** Jetpack Compose
> **Min SDK:** 26 (Android 8.0)
> **Architecture:** MVVM + Singleton SDK

---

## Objective

Replicate the **BeAroundScan** iOS demo app and its underlying **BearoundSDK** for Android. The SDK detects BLE beacons (iBeacon format + custom BEAD Service Data), collects device telemetry, and periodically syncs everything to an API. The demo app is a UI wrapper that configures the SDK, shows detected beacons, permissions, sync status, and sends local notifications.

The Android version must produce the **exact same API payload** as the iOS version, so the backend receives identical data structures regardless of platform.

---

## PART 1: SDK Architecture Overview

### Singleton Entry Point

```kotlin
// Equivalent to BeAroundSDK.shared (iOS singleton)
object BearoundSDK {
    const val VERSION = "2.3.0"

    fun configure(
        context: Context,
        businessToken: String,
        foregroundScanInterval: ForegroundScanInterval = ForegroundScanInterval.SECONDS_15,
        backgroundScanInterval: BackgroundScanInterval = BackgroundScanInterval.SECONDS_60,
        maxQueuedPayloads: MaxQueuedPayloads = MaxQueuedPayloads.MEDIUM
    )

    fun startScanning()
    fun stopScanning()
    val isScanning: Boolean

    fun setUserProperties(properties: UserProperties)
    fun clearUserProperties()

    val currentSyncInterval: Long?   // milliseconds
    val currentScanDuration: Long?   // milliseconds
    val pendingBatchCount: Int

    var delegate: BearoundSDKDelegate?
}
```

### Delegate / Listener Interface

```kotlin
interface BearoundSDKDelegate {
    fun didUpdateBeacons(beacons: List<Beacon>)
    fun didFailWithError(error: Throwable) {}
    fun didChangeScanning(isScanning: Boolean) {}
    fun willStartSync(beaconCount: Int) {}
    fun didCompleteSync(beaconCount: Int, success: Boolean, error: Throwable?) {}
    fun didDetectBeaconInBackground(beacons: List<Beacon>) {}
}
```

---

## PART 2: Data Models (must match iOS exactly)

### Beacon

```kotlin
data class Beacon(
    val uuid: UUID,
    val major: Int,
    val minor: Int,
    val rssi: Int,
    val proximity: BeaconProximity,
    val accuracy: Double,            // estimated distance in meters, -1 if unknown
    val timestamp: Date = Date(),
    val metadata: BeaconMetadata? = null,
    val txPower: Int? = null,
    val discoverySources: Set<BeaconDiscoverySource> = setOf(BeaconDiscoverySource.SERVICE_UUID)
)
```

### BeaconProximity

```kotlin
enum class BeaconProximity(val value: Int) {
    UNKNOWN(0),
    IMMEDIATE(1),   // < 0.5m
    NEAR(2),        // 0.5-4m
    FAR(3),         // > 4m
    BT(4);          // Bluetooth-only (no CoreLocation equivalent)
}
```

On Android, calculate proximity from RSSI + txPower:
- `rssi >= txPower - 5` → IMMEDIATE
- `rssi >= txPower - 20` → NEAR
- `rssi >= txPower - 40` → FAR
- else → UNKNOWN

### BeaconDiscoverySource

```kotlin
enum class BeaconDiscoverySource(val displayName: String) {
    SERVICE_UUID("Service UUID"),    // BEAD Service Data (primary)
    NAME("Name"),                    // Beacon name (unused currently)
    CORE_LOCATION("CoreLocation");   // iOS only — on Android, never used
}
```

On Android, all beacons come from BLE scanning, so the source will always be `SERVICE_UUID`.

### BeaconMetadata

Parsed from the 11-byte BEAD Service Data:

```kotlin
data class BeaconMetadata(
    val firmwareVersion: String,     // UInt16 LE → String
    val batteryLevel: Int,           // UInt16 LE (millivolts, e.g. 3000 = 3.0V)
    val movements: Int,              // UInt16 LE (motion counter)
    val temperature: Int,            // Int8 (celsius, signed)
    val txPower: Int? = null,
    val rssiFromBLE: Int? = null,
    val isConnectable: Boolean? = null
)
```

### UserProperties

```kotlin
data class UserProperties(
    val internalId: String? = null,
    val email: String? = null,
    val name: String? = null,
    val customProperties: Map<String, String> = emptyMap()
) {
    fun toDictionary(): Map<String, Any> { /* merge all into flat map */ }
    val hasProperties: Boolean get() = internalId != null || email != null || name != null || customProperties.isNotEmpty()
}
```

### SDKConfiguration

```kotlin
data class SDKConfiguration(
    val appId: String,               // applicationId from context
    val businessToken: String,
    val foregroundScanInterval: ForegroundScanInterval,
    val backgroundScanInterval: BackgroundScanInterval,
    val maxQueuedPayloads: MaxQueuedPayloads,
    val apiBaseURL: String = "https://ingest.bearound.io"
) {
    fun scanDuration(intervalMs: Long): Long {
        if (intervalMs == 5000L) return intervalMs  // continuous mode
        val calculated = intervalMs / 3
        return calculated.coerceIn(5000L, 20000L)
    }

    fun syncInterval(isInBackground: Boolean): Long {
        return if (isInBackground) backgroundScanInterval.ms else foregroundScanInterval.ms
    }
}
```

### Scan Interval Enums

```kotlin
enum class ForegroundScanInterval(val seconds: Int) {
    SECONDS_5(5), SECONDS_10(10), SECONDS_15(15), SECONDS_20(20),
    SECONDS_25(25), SECONDS_30(30), SECONDS_35(35), SECONDS_40(40),
    SECONDS_45(45), SECONDS_50(50), SECONDS_55(55), SECONDS_60(60);

    val ms: Long get() = seconds * 1000L
}

enum class BackgroundScanInterval(val seconds: Int) {
    SECONDS_15(15), SECONDS_30(30), SECONDS_45(45),
    SECONDS_60(60), SECONDS_90(90), SECONDS_120(120);

    val ms: Long get() = seconds * 1000L
}

enum class MaxQueuedPayloads(val value: Int) {
    SMALL(50), MEDIUM(100), LARGE(200), XLARGE(500);
}
```

### SDKInfo

```kotlin
data class SDKInfo(
    val version: String = "2.3.0",
    val platform: String = "android",  // IMPORTANT: "android" not "ios"
    val appId: String,
    val build: Int                      // versionCode
)
```

### UserDevice (full device telemetry)

```kotlin
data class UserDevice(
    val deviceId: String,               // Persistent device identifier
    val manufacturer: String,           // Build.MANUFACTURER
    val model: String,                  // Build.MODEL
    val osVersion: String,              // Build.VERSION.RELEASE
    val timestamp: Long,                // System.currentTimeMillis()
    val timezone: String,               // TimeZone.getDefault().id
    val batteryLevel: Int,              // 0-100
    val isCharging: Boolean,
    val bluetoothState: String,         // "powered_on" / "powered_off"
    val locationPermission: String,     // see permission strings below
    val notificationsPermission: String,
    val networkType: String,            // "wifi" / "cellular" / "none"
    val cellularGeneration: String?,    // "2G" / "3G" / "4G" / "5G"
    val ramTotalMb: Int,
    val ramAvailableMb: Int,
    val screenWidth: Int,               // physical pixels
    val screenHeight: Int,
    val adTrackingEnabled: Boolean,     // Google Advertising ID available
    val appInForeground: Boolean,
    val appUptimeMs: Int,               // time since SDK init
    val coldStart: Boolean,
    val advertisingId: String?,         // Google Advertising ID (GAID)
    val lowPowerMode: Boolean?,         // PowerManager.isPowerSaveMode
    val locationAccuracy: String?,      // "fine" / "coarse"
    val wifiSSID: String?,
    val connectionMetered: Boolean?,
    val connectionExpensive: Boolean?,
    val os: String = "Android",         // IMPORTANT: "Android" not "iOS"
    val deviceLocation: DeviceLocation?,
    val deviceName: String,             // Build.DEVICE or Settings.Global.DEVICE_NAME
    val carrierName: String?,
    val availableStorageMb: Int?,
    val systemLanguage: String,         // Locale.getDefault().language
    val thermalState: String,           // "nominal" / "moderate" / "severe" / "critical"
    val systemUptimeMs: Int             // SystemClock.elapsedRealtime()
)
```

### DeviceLocation

```kotlin
data class DeviceLocation(
    val latitude: Double,
    val longitude: Double,
    val accuracy: Double?,
    val altitude: Double?,
    val altitudeAccuracy: Double?,
    val heading: Double?,
    val speed: Double?,
    val speedAccuracy: Double?,
    val course: Double?,
    val courseAccuracy: Double?,
    val floor: Int?,                    // null on Android (no floor detection)
    val timestamp: Date,
    val sourceInfo: String?             // null on Android
)
```

---

## PART 3: BLE Scanning (BluetoothManager)

### Overview

The SDK scans for BLE advertisements with **Service UUID 0xBEAD**. When found, it parses an 11-byte Service Data payload in **Little Endian** format.

### BEAD Service Data Format (11 bytes, Little Endian)

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0-1 | UInt16 LE | firmware | Firmware version |
| 2-3 | UInt16 LE | major | Beacon major |
| 4-5 | UInt16 LE | minor | Beacon minor |
| 6-7 | UInt16 LE | motion | Movement counter |
| 8 | Int8 | temperature | Temperature (celsius, signed) |
| 9-10 | UInt16 LE | battery | Battery level |

### Parsing Code (Kotlin reference)

```kotlin
fun parseBeadServiceData(data: ByteArray, rssi: Int, isConnectable: Boolean): Triple<Int, Int, BeaconMetadata>? {
    if (data.size < 11) return null

    val firmware = (data[0].toInt() and 0xFF) or ((data[1].toInt() and 0xFF) shl 8)
    val major = (data[2].toInt() and 0xFF) or ((data[3].toInt() and 0xFF) shl 8)
    val minor = (data[4].toInt() and 0xFF) or ((data[5].toInt() and 0xFF) shl 8)
    val motion = (data[6].toInt() and 0xFF) or ((data[7].toInt() and 0xFF) shl 8)
    val temperature = data[8].toInt()  // signed byte
    val battery = (data[9].toInt() and 0xFF) or ((data[10].toInt() and 0xFF) shl 8)

    val metadata = BeaconMetadata(
        firmwareVersion = firmware.toString(),
        batteryLevel = battery,
        movements = motion,
        temperature = temperature,
        txPower = null,
        rssiFromBLE = rssi,
        isConnectable = isConnectable
    )

    return Triple(major, minor, metadata)
}
```

### iBeacon Manufacturer Data (Fallback)

Also parse Apple iBeacon manufacturer data (Company ID 0x004C) as a fallback:

| Offset | Size | Field |
|--------|------|-------|
| 0-1 | UInt16 LE | Company ID (0x004C) |
| 2 | UInt8 | Type (0x02) |
| 3 | UInt8 | Length (0x15 = 21) |
| 4-19 | 16 bytes | UUID |
| 20-21 | UInt16 BE | Major |
| 22-23 | UInt16 BE | Minor |
| 24 | Int8 | TX Power |

**Target UUID:** `E25B8D3C-947A-452F-A13F-589CB706D2E5`

### Scanning Behavior

- **Service UUID filter:** Scan for `0000BEAD-0000-1000-8000-00805F9B34FB` (full 128-bit UUID for Android)
- **Deduplication:** 1-second window per beacon (key: `"major.minor"`)
- **Grace period:** 10 seconds before removing a beacon from tracked list
- **Cleanup timer:** Every 5 seconds, remove expired beacons
- **RSSI filtering:** Ignore RSSI values of 0 or 127

### Android-specific BLE Notes

- Use `BluetoothLeScanner` with `ScanFilter` for Service UUID BEAD
- Use `ScanSettings.SCAN_MODE_LOW_LATENCY` in foreground
- Use `ScanSettings.SCAN_MODE_LOW_POWER` in background
- For background scanning, use a `ForegroundService` with `FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE`
- On Android 12+, need `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT` permissions
- On Android < 12, need `ACCESS_FINE_LOCATION` for BLE scanning
- `ScanResult.isConnectable` is available on API 26+

---

## PART 4: Sync Timer & Scan Pattern

### 1/3 Rule

For a given sync interval `I`:
- Scan duration `D = max(5s, min(I/3, 20s))`
- Pause duration `P = I - D`
- Special: if `I = 5s`, scan continuously (no pause)

### Foreground Pattern

1. Pause for `P` seconds
2. Start BLE scan for `D` seconds
3. Sync collected beacons
4. Repeat

### Background Pattern

1. Pause for `P` seconds (stop scanning to save battery)
2. Resume scanning for `D` seconds
3. Sync collected beacons
4. Repeat

### Sync Triggers

Every sync includes a `syncTrigger` field in the API payload identifying what caused the sync:

| Trigger Value | Description |
|---------------|-------------|
| `foreground_timer` | Foreground periodic timer |
| `background_timer` | Background periodic timer |
| `bluetooth_timer` | Bluetooth-only mode timer |
| `display_on` | Screen unlock / display on event |
| `significant_location` | Significant location change |
| `stop_scanning` | `stopScanning()` called |
| `background_fetch` | Legacy background fetch |
| `bg_task_refresh` | WorkManager periodic work (Android equivalent of BGAppRefreshTask) |
| `bg_task_processing` | WorkManager one-time work (Android equivalent of BGProcessingTask) |
| `background_ranging_complete` | Post-relaunch background ranging done |
| `unknown` | Fallback default |

---

## PART 5: API Payload (MUST MATCH iOS EXACTLY)

### Endpoint

`POST https://ingest.bearound.io/ingest`

### Headers

```
Content-Type: application/json
Authorization: {businessToken}
```

### JSON Payload Structure

```json
{
  "beacons": [
    {
      "uuid": "E25B8D3C-947A-452F-A13F-589CB706D2E5",
      "major": 1,
      "minor": 84,
      "rssi": -65,
      "accuracy": 2.5,
      "proximity": "near",
      "timestamp": 1705123456000,
      "txPower": -59,
      "metadata": {
        "battery": 3050,
        "firmware": "1024",
        "movements": 42,
        "temperature": 22,
        "txPower": -59,
        "rssiFromBLE": -68,
        "isConnectable": true
      }
    }
  ],
  "sdk": {
    "version": "2.3.0",
    "platform": "android",
    "appId": "com.bearound.scan",
    "build": 1
  },
  "device": {
    "deviceId": "550e8400-e29b-41d4-a716-446655440000",
    "timestamp": 1705123456000,
    "timezone": "America/Sao_Paulo",
    "hardware": {
      "manufacturer": "Samsung",
      "model": "SM-G991B",
      "os": "Android",
      "osVersion": "14"
    },
    "screen": {
      "width": 1080,
      "height": 2400
    },
    "battery": {
      "level": 85,
      "isCharging": false,
      "lowPowerMode": false
    },
    "network": {
      "type": "wifi",
      "cellularGeneration": "5G",
      "wifiSSID": "MyWiFi"
    },
    "permissions": {
      "location": "authorized_always",
      "notifications": "authorized",
      "bluetooth": "powered_on",
      "locationAccuracy": "fine",
      "adTrackingEnabled": true,
      "advertisingId": "550e8400-e29b-41d4-a716-446655440000"
    },
    "memory": {
      "totalMb": 5959,
      "availableMb": 1024
    },
    "appState": {
      "inForeground": true,
      "uptimeMs": 123456,
      "coldStart": true
    },
    "deviceName": "Galaxy S21",
    "systemLanguage": "pt",
    "thermalState": "nominal",
    "systemUptimeMs": 987654,
    "carrierName": "Vivo",
    "availableStorageMb": 50000,
    "deviceLocation": {
      "latitude": -23.5505,
      "longitude": -46.6333,
      "accuracy": 20.0,
      "altitude": 760.0,
      "speed": 0.0,
      "timestamp": 1705123456000
    }
  },
  "syncTrigger": "foreground_timer",
  "userProperties": {
    "internalId": "user123",
    "email": "user@test.com",
    "name": "Test User",
    "custom": "value"
  }
}
```

### Proximity String Values

| Enum | JSON String |
|------|-------------|
| IMMEDIATE | `"immediate"` |
| NEAR | `"near"` |
| FAR | `"far"` |
| BT | `"bt"` |
| UNKNOWN | `"unknown"` |

### Location Permission Strings (Android mapping)

| Android State | JSON Value |
|---------------|------------|
| `ACCESS_BACKGROUND_LOCATION` granted | `"authorized_always"` |
| `ACCESS_FINE_LOCATION` granted (no background) | `"authorized_when_in_use"` |
| Denied | `"denied"` |
| Never asked | `"not_determined"` |

### Notification Permission Strings

| State | JSON Value |
|-------|------------|
| Granted | `"authorized"` |
| Denied | `"denied"` |
| Not asked (< Android 13) | `"authorized"` |
| Not asked (>= Android 13) | `"not_determined"` |

---

## PART 6: Device Identifier (CRITICAL — must be permanent)

### Rules

1. **deviceId is PERMANENT.** Once generated, it NEVER changes. Persisted in SharedPreferences AND Android Keystore.
2. **Priority order:** GAID (Google Advertising ID) > Keystore UUID > Generated UUID
3. **Advertising ID (GAID):** Cached indefinitely. Only check if the system value changed. Update cache if different.

### Implementation

```kotlin
object DeviceIdentifier {
    private const val PREF_DEVICE_ID = "io.bearound.sdk.persistent.deviceId"
    private const val PREF_DEVICE_ID_TYPE = "io.bearound.sdk.persistent.deviceIdType"
    private const val PREF_ADVERTISING_ID = "io.bearound.sdk.persistent.advertisingId"

    // deviceId: compute ONCE, persist FOREVER
    fun getDeviceId(context: Context): String { /* ... */ }
    fun getDeviceIdType(context: Context): String { /* ... */ }

    // advertisingId: cached, update only when system value differs
    fun getAdvertisingId(context: Context): String? { /* ... */ }

    // Live check
    fun isAdTrackingEnabled(context: Context): Boolean { /* ... */ }
}
```

Use `AdvertisingIdClient.getAdvertisingIdInfo(context)` from Google Play Services for GAID.

---

## PART 7: Offline Batch Storage

### Behavior

- Store failed sync batches as JSON files in app internal storage
- Directory: `files/com.bearound.sdk.batches/`
- Filename format: `{timestamp}_{uuid}.json`
- FIFO: oldest batch sent first on retry
- Auto-cleanup: remove batches older than 7 days
- Respect `maxBatchCount` limit
- Exponential backoff for retries: `min(5 * 2^(failures-1), 60)` seconds
- Circuit breaker: fail after 10 consecutive errors

---

## PART 8: Background Execution (Android)

### Foreground Service

For continuous BLE scanning in background, use a `ForegroundService`:

```kotlin
class BearoundScanService : Service() {
    // Notification channel: "bearound_scan"
    // Notification: "BeAroundSDK scanning for beacons"
    // foregroundServiceType = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
}
```

### WorkManager (equivalent to iOS BGTaskScheduler)

Schedule periodic sync work:

```kotlin
// Periodic work (≈15 min minimum on Android)
val syncWork = PeriodicWorkRequestBuilder<BeaconSyncWorker>(15, TimeUnit.MINUTES)
    .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
    .build()
WorkManager.getInstance(context).enqueueUniquePeriodicWork(
    "io.bearound.sdk.sync",
    ExistingPeriodicWorkPolicy.KEEP,
    syncWork
)
```

### SDK Config Persistence

Use `SharedPreferences` with name `"com.bearound.sdk.config"`:

```
business_token: String
foreground_interval: Int
background_interval: Int
max_queued_payloads: Int
is_configured: Boolean
is_scanning: Boolean
```

This allows the SDK to auto-configure after process death / WorkManager trigger.

---

## PART 9: Device Info Collection

Collect the following on every sync:

| Field | Android API |
|-------|------------|
| manufacturer | `Build.MANUFACTURER` |
| model | `Build.MODEL` |
| osVersion | `Build.VERSION.RELEASE` |
| batteryLevel | `BatteryManager` via sticky broadcast |
| isCharging | `BatteryManager.isCharging` |
| lowPowerMode | `PowerManager.isPowerSaveMode` |
| networkType | `ConnectivityManager.getActiveNetwork()` |
| cellularGeneration | `TelephonyManager.getDataNetworkType()` → map to 2G/3G/4G/5G |
| wifiSSID | `WifiManager.connectionInfo.ssid` (requires location permission) |
| connectionMetered | `ConnectivityManager.isActiveNetworkMetered` |
| ramTotalMb | `ActivityManager.MemoryInfo.totalMem` |
| ramAvailableMb | `ActivityManager.MemoryInfo.availMem` |
| screenWidth/Height | `DisplayMetrics` (real metrics) |
| thermalState | `PowerManager.getCurrentThermalStatus()` (API 29+) |
| carrierName | `TelephonyManager.networkOperatorName` |
| availableStorageMb | `StatFs(Environment.getDataDirectory().path)` |
| systemLanguage | `Locale.getDefault().language` |
| systemUptimeMs | `SystemClock.elapsedRealtime()` |
| deviceName | `Settings.Global.getString(resolver, "device_name")` or `Build.DEVICE` |
| location | `FusedLocationProviderClient.lastLocation` |

### Thermal State Mapping (API 29+)

| Android | JSON |
|---------|------|
| `THERMAL_STATUS_NONE` | `"nominal"` |
| `THERMAL_STATUS_LIGHT` | `"fair"` |
| `THERMAL_STATUS_MODERATE` | `"fair"` |
| `THERMAL_STATUS_SEVERE` | `"serious"` |
| `THERMAL_STATUS_CRITICAL` | `"critical"` |
| `THERMAL_STATUS_EMERGENCY` | `"critical"` |
| `THERMAL_STATUS_SHUTDOWN` | `"critical"` |
| Not available (< API 29) | `"not_available"` |

---

## PART 10: BeAroundScan Demo App (Jetpack Compose)

### App Structure

```
app/
├── BeAroundScanApp.kt          // Application class + WorkManager init
├── MainActivity.kt             // Single activity
├── ui/
│   ├── ContentScreen.kt        // Main screen
│   ├── SettingsScreen.kt       // Settings sheet/screen
│   ├── BeaconRow.kt            // Individual beacon item
│   └── theme/                  // Material3 theme
├── viewmodel/
│   └── BeaconViewModel.kt      // Main ViewModel
├── notification/
│   └── NotificationManager.kt  // Local notifications with cooldowns
└── sdk/                        // BearoundSDK package
    ├── BearoundSDK.kt
    ├── BluetoothManager.kt
    ├── DeviceInfoCollector.kt
    ├── DeviceIdentifier.kt
    ├── models/
    │   ├── Beacon.kt
    │   ├── BeaconMetadata.kt
    │   ├── UserDevice.kt
    │   ├── UserProperties.kt
    │   ├── SDKConfiguration.kt
    │   └── SDKInfo.kt
    ├── network/
    │   └── APIClient.kt
    └── storage/
        ├── SDKConfigStorage.kt
        ├── OfflineBatchStorage.kt
        └── KeystoreHelper.kt
```

### Main Screen (ContentScreen.kt)

The UI must replicate the iOS ContentView exactly. All labels are in **Portuguese (pt-BR)**:

```
┌─────────────────────────────────┐
│          BeAroundScan           │
│     [status message]            │  ← "Pronto", "Scaneando...", "2 beacons"
│                                 │
│  Permissões                     │
│  ┌─────────────────────────────┐│
│  │ 📍 Localização:    Sempre   ││  ← green/orange/red based on status
│  │ 📶 Bluetooth:      Ligado   ││
│  │ 🔔 Notificações:   Autorizada││
│  └─────────────────────────────┘│
│                                 │
│  Informações do Scan            │  ← only shown when scanning
│  ┌─────────────────────────────┐│
│  │ Modo:         Periódico     ││
│  │ Intervalo:    15s           ││
│  │ Duração:      5s            ││
│  └─────────────────────────────┘│
│                                 │
│  Informações do Sync            │  ← only shown when scanning
│  ┌─────────────────────────────┐│
│  │ Último sync:      14:30:22  ││
│  │ Beacons sync:     3         ││
│  │ Resposta ingest:  Sucesso   ││  ← green for success, red for failure
│  └─────────────────────────────┘│
│                                 │
│  ┌─[Iniciar Scan / Parar Scan]─┐│  ← blue/red toggle
│  ┌─[⚙ Configurações do SDK]────┐│  ← opens settings
│                                 │
│  Ordenar:    [Proximidade ▼]    │  ← dropdown: "Proximidade" / "ID"
│  Última atualização: 14:30:25   │
│                                 │
│  ┌─────────────────────────────┐│
│  │ Beacon 1.84                 ││
│  │ E25B8D3C-947A-452F-...     ││
│  │ 🟢 Imediato  1.2m          ││
│  │ [Service UUID] [iBeacon]    ││  ← colored badges
│  │                    📶 -65dB ││
│  └─────────────────────────────┘│
│  ┌─────────────────────────────┐│
│  │ Beacon 2.10                 ││
│  │ ...                         ││
│  └─────────────────────────────┘│
└─────────────────────────────────┘
```

### Proximity Colors & Labels (Portuguese)

| Proximity | Label | Color |
|-----------|-------|-------|
| IMMEDIATE | "Imediato" | Green |
| NEAR | "Perto" | Orange |
| FAR | "Longe" | Red |
| BT | "Bluetooth" | Blue |
| UNKNOWN | "Desconhecido" | Gray |

### Discovery Source Badges

| Source | Label | Badge Color |
|--------|-------|-------------|
| SERVICE_UUID | "Service UUID" | Purple |
| NAME | "Name" | Teal |
| CORE_LOCATION | "iBeacon" | Indigo |

On Android, you'll mostly see "Service UUID" only.

### Beacon Sorting

- **Proximidade:** Sort by proximity order (IMMEDIATE > NEAR > FAR > BT > UNKNOWN), then by RSSI descending, then by accuracy ascending
- **ID:** Sort by `"major.minor"` string lexicographically

### Settings Screen (SettingsScreen.kt)

```
┌─────────────────────────────────┐
│  Configurações            Fechar│
│                                 │
│  Versão do SDK         2.3.0   │
│                                 │
│  ── Intervalos de Sync ──       │
│  Foreground     [15s ▼]         │  ← 5s to 60s (5s steps)
│  Background     [60s ▼]         │  ← 15s, 30s, 45s, 60s, 90s, 120s
│                                 │
│  ── Fila de Retry ──            │
│  Tamanho da Fila  [Medium ▼]    │  ← Small(50), Medium(100), Large(200), XLarge(500)
│                                 │
│  ── Propriedades do Usuário ──  │
│  [ID do usuário         ]       │
│  [E-Mail do usuário     ]       │
│  [Nome do usuário       ]       │
│  [Propriedade customizada]      │
│                                 │
│  ┌─[Aplicar Configurações]─────┐│
└─────────────────────────────────┘
```

When "Aplicar Configurações" is tapped:
1. If scanning, stop scanning
2. Re-configure SDK with new settings
3. Set user properties
4. Save settings to SharedPreferences
5. If was scanning, restart scanning

### BeaconViewModel

```kotlin
class BeaconViewModel(application: Application) : AndroidViewModel(application), BearoundSDKDelegate {
    val isScanning = mutableStateOf(false)
    val beacons = mutableStateOf<List<Beacon>>(emptyList())
    val statusMessage = mutableStateOf("Pronto")
    val permissionStatus = mutableStateOf("Verificando...")
    val bluetoothStatus = mutableStateOf("Verificando...")
    val notificationStatus = mutableStateOf("Verificando...")
    val sortOption = mutableStateOf(BeaconSortOption.PROXIMITY)

    val foregroundInterval = mutableStateOf(ForegroundScanInterval.SECONDS_15)
    val backgroundInterval = mutableStateOf(BackgroundScanInterval.SECONDS_60)
    val queueSize = mutableStateOf(MaxQueuedPayloads.MEDIUM)

    val lastSyncTime = mutableStateOf<Date?>(null)
    val lastSyncBeaconCount = mutableStateOf(0)
    val lastSyncResult = mutableStateOf("Aguardando...")

    val userPropertyInternalId = mutableStateOf("")
    val userPropertyEmail = mutableStateOf("")
    val userPropertyName = mutableStateOf("")
    val userPropertyCustom = mutableStateOf("")

    // Load saved settings from SharedPreferences on init
    // Configure SDK with businessToken = "BUSINESS_TOKEN"
    // Start scanning automatically
}
```

### Permission Status Strings (Portuguese)

| Location | Display |
|----------|---------|
| Always | `"Sempre (Background habilitado)"` |
| When in use | `"Quando em uso (Background não funciona)"` |
| Denied | `"Negada"` |
| Not determined | `"Aguardando resposta..."` |

| Bluetooth | Display |
|-----------|---------|
| ON | `"Ligado"` |
| OFF | `"Desligado"` |
| Not supported | `"Não suportado"` |
| Not authorized | `"Não autorizado"` |

| Notifications | Display |
|---------------|---------|
| Authorized | `"Autorizada"` |
| Denied | `"Negada"` |
| Not asked | `"Não solicitada"` |

---

## PART 11: Notification System

### Notification Types with Cooldowns

| Type | Cooldown | Title | Body |
|------|----------|-------|------|
| scanningStarted | 10s | "Escaneamento Iniciado" | "BeAroundSDK está escaneando beacons" |
| scanningStopped | 10s | "Escaneamento Parado" | "BeAroundSDK parou de escanear" |
| beaconDetected | 300s | "Beacon Detectado" | "{major}.{minor} [sources]" (up to 5) |
| beaconDetectedBackground | 60s | "Beacon Detectado (Background)" | same as above |
| apiSyncStarted | 30s | "Sincronizando" | "Enviando {n} beacon(s) para o servidor" |
| apiSyncSuccess | 60s | "Sync Completo" | "{n} beacon(s) enviado(s) com sucesso" |
| apiSyncFailed | 30s | "Sync Falhou" | "Falha ao enviar {n} beacon(s). Tentando novamente." |
| appRelaunched | 60s | "App Reativado" | "BeAroundSDK detectou região de beacons em segundo plano" |

### Notification Channel

- Channel ID: `"BEAROUND_SDK"`
- Channel Name: `"BeAroundSDK"`
- Importance: `NotificationManager.IMPORTANCE_DEFAULT`
- Sound: default for scan/detection, silent for sync start

### Per-Type Enable/Disable Flags

```kotlin
var enableScanningNotifications = true
var enableBeaconNotifications = true
var enableAPISyncNotifications = true
var enableBackgroundNotifications = true
```

---

## PART 12: Required Permissions

### AndroidManifest.xml

```xml
<!-- BLE Scanning -->
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />

<!-- Location (required for BLE scanning on Android < 12, and for location data) -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />

<!-- Network info -->
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
<uses-permission android:name="android.permission.CHANGE_WIFI_STATE" />

<!-- Background execution -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />
<uses-permission android:name="android.permission.WAKE_LOCK" />
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />

<!-- Notifications (Android 13+) -->
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

<!-- Phone state for carrier info -->
<uses-permission android:name="android.permission.READ_PHONE_STATE" />
```

### Runtime Permission Flow

Request in this order:
1. Location (fine) → then background location (separate prompt on Android 11+)
2. Bluetooth scan + connect (Android 12+)
3. Notifications (Android 13+)

---

## PART 13: Key Differences from iOS

| Feature | iOS | Android |
|---------|-----|---------|
| BLE background scan | `CBCentralManager` with state restoration | ForegroundService with notification |
| Region monitoring | `CLBeaconRegion` (wakes terminated app) | Not available natively — use ForegroundService for continuous scan |
| Background task | `BGTaskScheduler` (15-30 min) | `WorkManager` (15 min minimum) |
| IDFA | `ASIdentifierManager` + ATT framework | `AdvertisingIdClient` (Google Play Services) |
| Keychain | iOS Keychain (`kSecAttrAccessibleAfterFirstUnlock`) | Android Keystore or EncryptedSharedPreferences |
| Config storage | `UserDefaults(suiteName:)` | `SharedPreferences` |
| Proximity | Provided by `CLBeacon.proximity` | Must calculate from RSSI + txPower |
| Accuracy | Provided by `CLBeacon.accuracy` | Must estimate from RSSI + txPower |
| notifyEntryStateOnDisplay | Built into `CLBeaconRegion` | Register `BroadcastReceiver` for `ACTION_SCREEN_ON` |
| Significant location | `CLLocationManager.startMonitoringSignificantLocationChanges()` | `FusedLocationProviderClient` with `PRIORITY_LOW_POWER` |
| platform field in SDK info | `"ios"` | `"android"` |
| os field in device info | `"iOS"` | `"Android"` |

### Distance Estimation (Android — no CoreLocation equivalent)

```kotlin
fun estimateDistance(rssi: Int, txPower: Int): Double {
    if (rssi == 0) return -1.0
    val ratio = rssi.toDouble() / txPower.toDouble()
    return if (ratio < 1.0) {
        ratio.pow(10.0)
    } else {
        0.89976 * ratio.pow(7.7095) + 0.111
    }
}
```

---

## PART 14: Build Dependencies

```kotlin
// build.gradle.kts (app)
dependencies {
    // Jetpack Compose
    implementation("androidx.compose.ui:ui:1.6.+")
    implementation("androidx.compose.material3:material3:1.2.+")
    implementation("androidx.activity:activity-compose:1.9.+")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.+")

    // WorkManager
    implementation("androidx.work:work-runtime-ktx:2.9.+")

    // Google Play Services (Advertising ID)
    implementation("com.google.android.gms:play-services-ads-identifier:18.+")
    implementation("com.google.android.gms:play-services-location:21.+")

    // Networking
    implementation("com.squareup.okhttp3:okhttp:4.12.+")

    // JSON
    implementation("com.google.code.gson:gson:2.10.+")
    // or use kotlinx.serialization
}
```

---

## PART 15: Implementation Checklist

### SDK Core
- [ ] `BearoundSDK` singleton with `configure()`, `startScanning()`, `stopScanning()`
- [ ] `BearoundSDKDelegate` interface with all 6 callbacks
- [ ] All data models matching iOS exactly
- [ ] Sync timer with 1/3 rule (foreground + background patterns)
- [ ] `syncTrigger` tracking at all sync call points

### BLE Scanning
- [ ] `BluetoothManager` scanning for Service UUID `0xBEAD`
- [ ] Parse 11-byte BEAD Service Data (Little Endian)
- [ ] Parse iBeacon manufacturer data 0x004C (fallback)
- [ ] Deduplication (1s window)
- [ ] Grace period (10s) + cleanup timer (5s)
- [ ] RSSI filtering (ignore 0 and 127)
- [ ] Tracked beacons dictionary with `onBeaconsUpdated` callback

### Networking
- [ ] `APIClient` with POST to `/ingest`
- [ ] Exact JSON payload matching iOS structure
- [ ] HTTP status validation (200-299)
- [ ] Error handling with `Result<Unit>`

### Offline Storage
- [ ] `OfflineBatchStorage` with JSON files
- [ ] FIFO ordering
- [ ] 7-day auto-cleanup
- [ ] Max batch count enforcement
- [ ] Exponential backoff for retries
- [ ] Circuit breaker (10 failures)

### Device Info
- [ ] `DeviceInfoCollector` collecting all 30+ fields
- [ ] `DeviceIdentifier` with permanent deviceId + cached GAID
- [ ] Location data from FusedLocationProviderClient
- [ ] All permission status strings matching iOS format

### Background Execution
- [ ] ForegroundService for continuous BLE scanning
- [ ] WorkManager for periodic sync (~15 min)
- [ ] Config persistence in SharedPreferences
- [ ] Auto-restore on process death

### Demo App
- [ ] Main screen with permissions, scan info, sync info, beacon list
- [ ] Settings screen with intervals, queue size, user properties
- [ ] Sorting (proximity / ID)
- [ ] All Portuguese labels matching iOS exactly
- [ ] NotificationManager with cooldowns per type
- [ ] Runtime permission requests (Location → BT → Notifications)

---

## IMPORTANT NOTES

1. **API payload must be identical** to iOS except for `platform: "android"` and `os: "Android"`. The backend processes both platforms with the same schema.

2. **All UI labels are in Portuguese (pt-BR).** Copy them exactly from this document.

3. **deviceId is permanent and must NEVER change.** This is the single most important rule. Use EncryptedSharedPreferences + Keystore for durability.

4. **The BEAD Service Data is Little Endian.** Do not confuse with iBeacon which uses Big Endian for major/minor.

5. **Test with real beacons.** The UUID is `E25B8D3C-947A-452F-A13F-589CB706D2E5` and Service UUID is `0xBEAD`.

6. **The businessToken in the demo app is `"BUSINESS_TOKEN"`.** This is a placeholder — the real token is set by the user.
