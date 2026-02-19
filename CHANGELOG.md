# Changelog

All notable changes to BearoundSDK for iOS will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.3.2] - 2026-02-19

### Added

- **Bluetooth-Only Fallback Scanning**: When Location permission is not authorized, the SDK now automatically falls back to Bluetooth-only mode using CoreBluetooth, allowing beacon detection without Location Services.
- **`BeaconProximity` enum**: Replaces `CLProximity` with a custom enum that includes `.bt` case for beacons detected via Bluetooth-only mode.
- **`BeaconDiscoverySource` enum**: Tracks how each beacon was discovered (`.coreLocation`, `.serviceUUID`, `.name`).
- **`discoverySources` property on `Beacon`**: Set indicating which discovery methods detected the beacon.
- **Sync lifecycle delegate methods**: `willStartSync(beaconCount:)` and `didCompleteSync(beaconCount:success:error:)` for monitoring sync operations.
- **Background beacon detection delegate**: `didDetectBeaconInBackground(beacons:)` now provides the full array of detected beacons instead of just a count.
- **BLE scan refresh on unlock**: Automatically refreshes BLE scanning when the device is unlocked to capture fresh Service Data.
- **Background BLE scanning with state restoration**: CoreBluetooth state restoration support for background wake-ups.
- **Device identifier caching**: Persistent device identifier with cache support.
- **Background task processing**: Added `scheduleProcessingTask()` for BGTaskScheduler.

### Changed

- **`Beacon.proximity`** type changed from `CLProximity` to `BeaconProximity`.
- **`didDetectBeaconInBackground`** delegate signature changed from `beaconCount: Int` to `beacons: [Beacon]`.
- **`startScanning()`** now checks Location authorization and automatically selects between Location+Bluetooth or Bluetooth-only mode.
- **Auto-configuration from storage** now supports both Location and Bluetooth-only relaunch paths.
- BLE beacons are merged with CoreLocation beacons before sync, enriching data with metadata from both sources.

### Breaking Changes

- `Beacon.proximity` is now `BeaconProximity` instead of `CLProximity`.
- `didDetectBeaconInBackground(beaconCount:)` replaced by `didDetectBeaconInBackground(beacons:)`.

---

## [2.2.2] - 2026-01-22

### Changed

- **5s Interval Continuous Mode**: When `foregroundScanInterval` is set to `.seconds5`, the SDK now operates in continuous mode (scanDuration = 5s, pauseDuration = 0s) for real-time beacon detection without pauses.
- **Beacon Persistence**: Collected beacons are no longer cleared after sync. This allows continuous tracking of beacon presence and prevents gaps in detection during rapid scans.

### Technical Details

- Modified `SDKConfiguration.scanDuration(for:)` to return full interval when interval == 5s
- Removed `collectedBeacons.removeAll()` from sync operations to maintain beacon state

---

## [2.2.1] - 2026-01-20

### 🔧 Code Quality Improvements

This patch release fixes compiler warnings and improves code quality.

### 🐛 Fixed

- **APIClient.swift**: Changed `var` to `let` for immutable variables (`hardware`, `screen`, `memory`, `appState`)
- **DeviceInfoCollector.swift**: Fixed `NSLock` usage in async contexts (Swift 6 compatibility)
- **DeviceInfoCollector.swift**: Updated deprecated `subscriberCellularProvider` API

### 📚 Documentation

- Updated README.md to reflect v2.2.0 changes
- Fixed BackgroundScanInterval enum documentation (added `.seconds15`, `.seconds30`, `.seconds45`)
- Removed references to deprecated `enableBluetoothScanning` and `enablePeriodicScanning` parameters
- Updated SDK version references from 2.1.0 to 2.2.0 in examples

---

## [2.2.0] - 2026-01-17

### 🚀 Major Background Improvements

This release adds comprehensive background execution support with multiple fallback mechanisms to ensure beacon data is synced even when the app is completely closed.

### ⚠️ Breaking Changes

- **Removed `enableBluetoothScanning` parameter**: Bluetooth scanning is now always enabled when available
- **Removed `enablePeriodicScanning` parameter**: Periodic scanning behavior is now automatic based on app state

**Before (v2.1.x):**
```swift
BeAroundSDK.shared.configure(
    businessToken: "token",
    foregroundScanInterval: .seconds30,
    backgroundScanInterval: .seconds90,
    maxQueuedPayloads: .large,
    enableBluetoothScanning: true,    // ❌ REMOVED
    enablePeriodicScanning: true      // ❌ REMOVED
)
```

**After (v2.2.0):**
```swift
BeAroundSDK.shared.configure(
    businessToken: "token",
    foregroundScanInterval: .seconds30,
    backgroundScanInterval: .seconds90,
    maxQueuedPayloads: .large
)
```

### ✨ Added

#### BGTaskScheduler Support (iOS 13+)
- **New `BackgroundTaskManager` class**: Manages `BGTaskScheduler` for scheduled background syncs
  - `registerTasks()`: Register background task identifiers (call in AppDelegate)
  - `scheduleSync()`: Schedule sync for ~15 minutes later
  - `cancelPendingTasks()`: Cancel pending background tasks
- Task identifier: `io.bearound.sdk.sync`

#### Significant Location Changes
- SDK now monitors significant location changes (~500m movement)
- When user moves significantly, SDK wakes up and syncs pending beacons
- New `onSignificantLocationChange` callback in `BeaconManager`
- Automatic start/stop with `startScanning()`/`stopScanning()`

#### Background Fetch Support
- New public `performBackgroundFetch(completion:)` method
- Call from `application(_:performFetchWithCompletionHandler:)` in AppDelegate
- Auto-configures SDK from saved settings if needed

#### Scanning State Persistence
- `isScanning` state now persisted to `UserDefaults`
- SDK respects user intention on background relaunch
- If user had stopped scanning, SDK won't auto-restart

### 🐛 Fixed

1. **Empty beacons sync logging**: Added `NSLog` when `syncBeacons()` is called with no beacons collected
2. **Background logging visibility**: Replaced all `print()` with `NSLog()` in `SDKConfigStorage` (print doesn't work in background)
3. **Unused variable cleanup**: Removed unused `isTemporaryRanging` variable
4. **Duplicate Region Monitoring**: Added guard in `startMonitoring()` to prevent duplicate region setup
5. **Duplicate `didEnterRegion` calls**: Added `isProcessingRegionEntry` flag to prevent double processing

### Changed

- `startScanning()` now:
  - Persists scanning state to storage
  - Schedules BGTaskScheduler sync
  - Starts significant location monitoring
- `stopScanning()` now:
  - Persists scanning state to storage
  - Cancels pending background tasks
  - Stops significant location monitoring
- `autoConfigureFromStorage()` now respects `isScanning` state

### 📚 Documentation

- Added comprehensive background integration guide to README
- Added BGTaskScheduler setup instructions
- Added Background Fetch integration example
- Added background execution mechanism comparison table

### Technical Details

#### Background Execution Architecture

```
┌────────────────────────────────────────────────────────────┐
│                  Background Triggers                        │
├─────────────┬─────────────┬─────────────┬─────────────────┤
│   Region    │ Significant │  Background │ BGTaskScheduler │
│  Monitoring │  Location   │    Fetch    │                 │
└──────┬──────┴──────┬──────┴──────┬──────┴────────┬────────┘
       │             │             │               │
       ▼             ▼             ▼               ▼
┌────────────────────────────────────────────────────────────┐
│                     BeAroundSDK                            │
│  autoConfigureFromStorage() → performBackgroundFetch() →   │
│               syncBeacons()                                │
└────────────────────────────────────────────────────────────┘
```

#### Info.plist Requirements

```xml
<key>UIBackgroundModes</key>
<array>
   <string>location</string>
   <string>fetch</string>
   <string>processing</string>
   <string>bluetooth-central</string>
</array>

<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
   <string>io.bearound.sdk.sync</string>
</array>
```

#### AppDelegate Integration

```swift
func application(_ application: UIApplication, didFinishLaunchingWithOptions...) -> Bool {
    if #available(iOS 13.0, *) {
        BackgroundTaskManager.shared.registerTasks()
    }
    application.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
    return true
}

func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    BeAroundSDK.shared.performBackgroundFetch { success in
        completionHandler(success ? .newData : .noData)
    }
}
```

### Requirements

- iOS 13.0+
- `location` in UIBackgroundModes
- `fetch` in UIBackgroundModes
- `processing` in UIBackgroundModes
- "Always" location permission recommended

---

## [2.1.1] - 2026-01-17

### 🐛 Fixed - Background Execution (Critical)

This release fixes critical issues preventing the SDK from working when the app is completely closed (terminated).

#### Problems Fixed

1. **Configuration Persistence**: Added `SDKConfigStorage` to persist SDK configuration
   - When iOS relaunches the app via Region Monitoring, the SDK now auto-configures from saved settings
   - Configuration is saved to `UserDefaults` when `configure()` is called
   - SDK automatically loads configuration on init when launched in background

2. **Background Ranging Timeout**: Reduced background ranging timer from 30s to 10s
   - iOS only allows ~30 seconds of background execution
   - Previous 30-second ranging caused background task expiration before sync
   - Now ranging completes well within iOS time limits

3. **Beacon Region Storage**: Fixed `beaconRegion` being nil when app is relaunched
   - Region is now stored from `didEnterRegion` callback
   - `onBackgroundRangingComplete` callback now works correctly

4. **Immediate Background Sync**: Added immediate sync when first beacon is detected in background
   - New `onFirstBackgroundBeaconDetected` callback triggers sync immediately
   - Ensures beacons are sent before iOS terminates the app
   - Final sync still occurs when ranging completes

### ✨ Added

- `SDKConfigStorage` class for persistent configuration storage
- Auto-configuration on background relaunch
- `onFirstBackgroundBeaconDetected` callback for immediate sync
- `CaseIterable` conformance to all scan interval enums

### Changed

- `ForegroundScanInterval`, `BackgroundScanInterval`, and `MaxQueuedPayloads` enums now use `rawValue`
- Background ranging timer reduced from 30s to 10s
- SDK now marks `isScanning = true` when relaunched by beacon monitoring

### Technical Details

#### Background Execution Flow (Fixed)

```
1. App terminated by user (swipe up)
2. User enters beacon region
3. iOS relaunches app via Region Monitoring
4. SDK auto-configures from UserDefaults ← NEW
5. didEnterRegion triggers 10-second ranging ← REDUCED from 30s
6. First beacon detected → immediate sync ← NEW
7. 10 seconds later → final sync
8. Background task ends properly ← FIXED
9. iOS suspends app (not terminated)
```

#### Configuration Persistence

```swift
// Configuration is automatically saved when you call configure()
BeAroundSDK.shared.configure(businessToken: "your-token")

// When app is relaunched in background, SDK loads saved config
// No code changes required - it's automatic!
```

### Requirements

- iOS 13.0+
- `location` in UIBackgroundModes
- `fetch` in UIBackgroundModes (recommended for background refresh)
- "Always" location permission for best results

---

## [2.1.0] - 2026-01-12

### ✨ Added

- **Configurable Scan Intervals**: New enums for fine-grained control over scan behavior
  - `ForegroundScanInterval`: Configure foreground scan intervals from 5 to 60 seconds (in 5-second increments)
  - `BackgroundScanInterval`: Configure background scan intervals (60s, 90s, or 120s)
  - Default: 15 seconds for foreground, 60 seconds for background

- **Configurable Retry Queue**: New `MaxQueuedPayloads` enum to control retry queue size
  - `.small` (50 failed batches)
  - `.medium` (100 failed batches) - default
  - `.large` (200 failed batches)
  - `.xlarge` (500 failed batches)
  - Replaces fixed limit of 10 batches with configurable options
  - Each batch can contain multiple beacons from a single sync

### Changed

- **Configuration API**: `configure()` method now accepts enum parameters instead of raw `TimeInterval`
  - `foregroundScanInterval: ForegroundScanInterval = .seconds15`
  - `backgroundScanInterval: BackgroundScanInterval = .seconds60`
  - `maxQueuedPayloads: MaxQueuedPayloads = .medium`
  - Old `syncInterval` parameter removed in favor of separate foreground/background intervals

- **Dynamic Interval Switching**: SDK now automatically switches between foreground and background intervals based on app state
- **Improved Resilience**: Increased default retry queue from 10 to 100 failed batches

### Migration

**Before (v2.0.1):**
```swift
BeAroundSDK.shared.configure(
    businessToken: "your-token",
    syncInterval: 15
)
```

**After (v2.1.0):**
```swift
// Using defaults (recommended)
BeAroundSDK.shared.configure(businessToken: "your-token")

// Custom configuration
BeAroundSDK.shared.configure(
    businessToken: "your-token",
    foregroundScanInterval: .seconds30,
    backgroundScanInterval: .seconds90,
    maxQueuedPayloads: .large
)
```

### Technical Details

- Scan duration formula unchanged: `scanDuration = max(5, min(syncInterval / 3, 10))`
- Backoff retry logic unchanged: exponential backoff with max 60s delay
- All existing scanning and sync behaviors preserved

---

## [2.0.1] - 2026-01-07

### ⚠️ Breaking Changes

**Authentication Update**: SDK now requires business token instead of appId for authentication.

### Changed

- **Configuration**: `configure()` now requires `businessToken` parameter (replaces `appId`)
- **Auto-detection**: `appId` automatically extracted from `Bundle.main.bundleIdentifier`
- **Authorization**: Business token sent in `Authorization` header for all API requests

### Fixed

- BeaconManager stability improvements (guards to prevent operations after scanning stopped)
- Memory cleanup in `stopScanning()` method
- Race conditions in ranging operations

### Migration

**Before (v2.0.0):**
```swift
BeAroundSDK.shared.configure(appId: "com.example.app", syncInterval: 10)
```

**After (v2.0.1):**
```swift
BeAroundSDK.shared.configure(businessToken: "your-token-here", syncInterval: 10)
```

---

## [2.0.0] - 2025-12-29

### 🔥 BREAKING CHANGES - Complete SDK Rewrite

This is a **major rewrite** of the SDK with a completely new architecture. The entire codebase was refactored from scratch.

### ⚠️ Migration Required

**This version is NOT backward compatible with v1.x.** You will need to update your integration code.

### What Changed

#### Architecture
- **Complete rewrite** of the SDK core
- New modular architecture with clear separation of concerns
- Improved background processing with proper app state management
- Better memory management and lifecycle handling

#### New API

**Old API (v1.x - REMOVED):**
```swift
let bearound = Bearound(clientToken: token, isDebugEnable: true)
bearound.startServices()
bearound.addBeaconListener(listener)
```

**New API (v2.0):**
```swift
let sdk = BeAroundSDK.shared
sdk.configure(appId: appId, syncInterval: 10)
sdk.delegate = self
sdk.startScanning()
```

#### Key Changes

1. **Singleton Pattern**: Now uses `BeAroundSDK.shared` instead of creating instances
2. **Delegate-Based**: Replaced listener pattern with protocol-based delegates
3. **Simplified Configuration**: One-time configuration with `configure()`
4. **Better Sync Control**: Configurable sync intervals with periodic/continuous modes
5. **Enhanced Metadata**: Optional Bluetooth scanning for beacon metadata (firmware, battery, etc.)
6. **User Properties**: Support for custom user properties attached to beacon data

### Added

- `BeAroundSDK` class with singleton pattern
- `BeAroundSDKDelegate` protocol for event callbacks:
  - `didUpdateBeacons(_:)` - Beacon detection updates
  - `didFailWithError(_:)` - Error handling
  - `didChangeScanning(isScanning:)` - Scanning state changes
  - `didUpdateSyncStatus(secondsUntilNextSync:isRanging:)` - Sync countdown
- `UserProperties` model for custom user data
- `BeaconMetadata` for enhanced beacon information via Bluetooth
- Periodic scanning mode with configurable scan/pause durations
- Background ranging support with proper state management
- Circuit breaker pattern for API failure handling (10 consecutive failures)
- Retry queue for failed beacon batches (up to 10 batches)
- Exponential backoff for retry logic (5s, 10s, 20s, 40s, max 60s)

### Changed

- **Module name**: Still `BearoundSDK` but class is now `BeAroundSDK`
- **Configuration**: Now uses `configure(appId:syncInterval:enableBluetoothScanning:enablePeriodicScanning:)`
- **Scanning control**: `startScanning()` / `stopScanning()` instead of `startServices()` / `stopServices()`
- **Event handling**: Delegate pattern instead of listener pattern
- **Background mode**: Automatic switching between periodic and continuous modes
- **API payload structure**: More comprehensive device and SDK information
- **Logs**: All logs now use `[BeAroundSDK]` tag (was inconsistent before)

### Removed

- `Bearound` class (replaced by `BeAroundSDK`)
- Listener pattern (`BeaconListener`, `SyncListener`, `RegionListener`)
- `clientToken` configuration (now uses `appId`)
- `isDebugEnable` parameter (logging is always enabled)
- Old API methods: `addBeaconListener()`, `removeBeaconListener()`, etc.
- Event type tracking (`enter`, `exit`, `lost`)

### Features

#### Periodic Scanning
```swift
sdk.configure(
    appId: "com.example.app",
    syncInterval: 30,  // Sync every 30 seconds
    enablePeriodicScanning: true  // Save battery
)
```

#### Bluetooth Metadata Scanning
```swift
sdk.configure(
    appId: "com.example.app",
    syncInterval: 10,
    enableBluetoothScanning: true  // Get battery, firmware, etc.
)
```

#### User Properties
```swift
let properties = UserProperties(
    internalId: "user123",
    email: "user@example.com",
    name: "John Doe",
    customProperties: ["tier": "premium"]
)
sdk.setUserProperties(properties)
```

#### Delegate Implementation
```swift
class MyViewController: UIViewController, BeAroundSDKDelegate {
    func didUpdateBeacons(_ beacons: [Beacon]) {
        print("Found \(beacons.count) beacons")
    }
    
    func didFailWithError(_ error: Error) {
        print("Error: \(error.localizedDescription)")
    }
    
    func didChangeScanning(isScanning: Bool) {
        print("Scanning: \(isScanning)")
    }
    
    func didUpdateSyncStatus(secondsUntilNextSync: Int, isRanging: Bool) {
        print("Next sync in: \(secondsUntilNextSync)s, Ranging: \(isRanging)")
    }
}
```

### Fixed

- Module/class name conflict that prevented framework builds
- Background state detection issues
- Memory leaks in timer management
- Inconsistent logging tags
- Thread safety issues in beacon collection
- Background task lifecycle management

### Technical Details

#### New Models

- `Beacon`: UUID, major, minor, RSSI, proximity, accuracy, timestamp, metadata, txPower
- `BeaconMetadata`: Firmware version, battery level, movements, temperature, txPower, RSSI from BLE, connectivity
- `SDKConfiguration`: App ID, sync interval, Bluetooth scanning, periodic scanning, scan duration
- `SDKInfo`: App ID, SDK version, platform, build number
- `UserDevice`: Comprehensive device information (manufacturer, model, OS, battery, network, permissions, etc.)
- `UserProperties`: Internal ID, email, name, custom properties dictionary

#### New Managers

- `BeaconManager`: CoreLocation-based beacon ranging
- `BluetoothManager`: CoreBluetooth-based metadata scanning
- `DeviceInfoCollector`: Device telemetry collection
- `APIClient`: Network communication with retry logic

### Migration Guide

#### Step 1: Update Initialization

**Before (v1.x):**
```swift
let bearound = Bearound(clientToken: "your-token", isDebugEnable: true)
bearound.startServices()
```

**After (v2.0):**
```swift
let sdk = BeAroundSDK.shared
sdk.configure(appId: "com.example.app", syncInterval: 10)
sdk.delegate = self  // Conform to BeAroundSDKDelegate
sdk.startScanning()
```

#### Step 2: Replace Listeners with Delegate

**Before (v1.x):**
```swift
class MyBeaconListener: BeaconListener {
    func onBeaconsDetected(_ beacons: [Beacon], eventType: String) {
        // Handle beacons
    }
}
bearound.addBeaconListener(MyBeaconListener())
```

**After (v2.0):**
```swift
class MyViewController: UIViewController, BeAroundSDKDelegate {
    func didUpdateBeacons(_ beacons: [Beacon]) {
        // Handle beacons
    }
}
```

#### Step 3: Update Beacon Access

**Before (v1.x):**
```swift
let activeBeacons = bearound.getActiveBeacons()
let allBeacons = bearound.getAllBeacons()
```

**After (v2.0):**
```swift
// Beacons are now delivered via delegate callbacks
func didUpdateBeacons(_ beacons: [Beacon]) {
    self.beacons = beacons
}
```

### Requirements

- iOS 13.0+
- Swift 5.0+
- Xcode 11.0+

### Dependencies

- CoreLocation
- CoreBluetooth
- Foundation
- UIKit

---

## [1.2.1] - 2025-12-10

### Added
- `clientToken` field now included in `IngestPayload` for proper authentication
- Beacon-specific telemetry data in `BeaconPayload`:
  - `rssi`: Signal strength for each beacon
  - `approxDistanceMeters`: Distance estimation per beacon
  - `txPower`: Transmission power per beacon
- `Sendable` conformance to `Beacon` struct for Swift concurrency safety

### Changed
- **IngestPayload structure improvement**:
  - Moved `clientToken` from scan context to root level of payload
  - Moved beacon-specific metrics (`rssi`, `approxDistanceMeters`, `txPower`) from `ScanContext` to individual `BeaconPayload` items
  - `ScanContext` now contains only session-level data (`scanSessionId`, `detectedAt`)
- **Swift concurrency improvements**:
  - `BeaconActionsDelegate` protocol marked with `@MainActor` for thread safety
  - `Bearound` class marked with `@MainActor`
  - `BeaconScanner` and `BeaconTracker` now dispatch delegate calls to main actor using `Task { @MainActor in }`
  - Removed unnecessary `DispatchQueue.main.async` calls, relying on `@MainActor` isolation
- **DeviceInfoService**:
  - `createScanContext()` simplified - no longer requires beacon-specific parameters
- **Version bump**: Updated to 1.2.1 in `BeAroundSDKConfig.version`

### Fixed
- Thread safety issues with beacon delegate calls now properly isolated to main actor
- Concurrency warnings when updating beacon lists from background threads
- Data structure inconsistency where beacon metrics were shared across all beacons instead of per-beacon

### Technical Details

#### New Payload Structure (v1.2.1):
```json
{
  "clientToken": "your-client-token-here",
  "beacons": [
    {
      "uuid": "E25B8D3C-947A-452F-A13F-589CB706D2E5",
      "name": "B:1.0_1000.2000_100_0_20",
      "rssi": -63,
      "approxDistanceMeters": 1.8,
      "txPower": -59
    },
    {
      "uuid": "E25B8D3C-947A-452F-A13F-589CB706D2E5",
      "name": "B:1.0_2000.3000_95_0_22",
      "rssi": -78,
      "approxDistanceMeters": 5.2,
      "txPower": -59
    }
  ],
  "sdk": { ... },
  "userDevice": { ... },
  "scanContext": {
    "scanSessionId": "scan_98DF10",
    "detectedAt": 1735940400000
  }
}
```

**Key improvements over 1.2.0:**
- Each beacon now has its own signal strength and distance data
- Authentication token moved to root level for better API design
- Session context simplified to only session-level data

### Migration from 1.2.0

No breaking changes for public API consumers. The changes are internal to payload structure and concurrency handling. If you're upgrading from 1.2.0, no code changes are required.

## [1.2.0] - 2025-12-08

### Added
- **DeviceInfoService**: Novo serviço singleton para coleta abrangente de informações do dispositivo
  - Informações do SDK (versão, plataforma, app ID, build)
  - Informações completas do dispositivo do usuário:
    - Fabricante, modelo, OS, versão do OS
    - Timestamp, timezone
    - Nível de bateria, status de carregamento
    - Modo de economia de energia
    - Estado do Bluetooth
    - Permissões de localização e precisão
    - Permissões de notificações
    - Tipo de rede (WiFi, Cellular, Ethernet)
    - Geração celular (2G, 3G, 4G, 5G)
    - Status de roaming
    - Informações de memória RAM
    - Resolução da tela
    - Advertising ID (IDFA) e status de tracking
    - Estado do app (foreground/background)
    - Tempo de atividade do app
    - Detecção de cold start
  - Contexto do scan:
    - RSSI (força do sinal)
    - TX Power
    - Distância aproximada em metros
    - ID da sessão de scan
    - Timestamp da detecção

- **IngestPayload**: Novo modelo de dados estruturado para o endpoint de ingest
  - `BeaconPayload`: Representa um beacon individual
  - `SDKInfo`: Informações do SDK
  - `UserDeviceInfo`: Informações completas do dispositivo
  - `ScanContext`: Contexto do scan de beacons

- **Novos métodos públicos no Bearound SDK**:
  - `createIngestPayload(for:sdkVersion:)`: Cria um payload completo de ingest
  - `sendBeaconsWithFullInfo(_:completion:)`: Envia beacons com telemetria completa

- **BeAroundSDKConfig**: Nova estrutura centralizada para configurações do SDK
  - `version`: Versão do SDK (único ponto de definição)
  - `name`: Nome do SDK ("BeAroundSDK")
  - `logTag`: Tag usada em todos os logs ("[BeAroundSDK]")

### Changed
- **APIService**: 
  - Removido `PostData` legado (não mantemos mais compatibilidade com versões antigas)
  - Removido método `sendBeacons(_:completion:)` legado
  - Mantido apenas `sendIngestPayload(_:completion:)` para o novo formato

- **BearoundSDK**:
  - Método interno `sendBeacons(type:_:)` agora usa o novo formato `IngestPayload`
  - Todas as comunicações com a API agora incluem telemetria completa do dispositivo
  - Método `createIngestPayload()` agora usa `BeAroundSDKConfig.version` como default
  - Log de inicialização em `startServices()` atualizado para usar versão centralizada

- **Constants.swift**:
  - Reestruturado para centralizar configurações do SDK
  - Introduzido `BeAroundSDKConfig` como struct pública para configs globais
  - `Constants` agora é internal e usa valores de `BeAroundSDKConfig`
  
- **DeviceInfoService**:
  - `getSDKInfo()` agora usa `BeAroundSDKConfig.version` como valor default

### Removed
- `PostData` struct (formato legado descontinuado)
- Método `sendBeacons(_:completion:)` do APIService

### Deprecated
- `SDK.version` (use `BeAroundSDKConfig.version` em vez disso)
- `DesignSystemVersion.current` (use `BeAroundSDKConfig.version` em vez disso)

### Migration Guide

Se você estava usando a API legada, atualize seu código da seguinte forma:

#### Antes (formato legado - não funciona mais):
```swift
// Este código não funciona mais
let postData = PostData(
    deviceType: "iOS",
    clientToken: token,
    sdkVersion: "1.1.0",
    idfa: idfa,
    eventType: "enter",
    appState: "foreground",
    beacons: beacons
)
```

#### Agora (novo formato):
```swift
// Opção 1: Usar o método de conveniência (recomendado)
await sdk.sendBeaconsWithFullInfo(beacons) { result in
    switch result {
    case .success(let data):
        print("Beacons enviados com sucesso")
    case .failure(let error):
        print("Erro: \(error)")
    }
}

// Opção 2: Criar o payload manualmente
let payload = await sdk.createIngestPayload(for: beacons)
// Use o payload como necessário
```

### Technical Details

#### DeviceInfoService - Novas funcionalidades:
```swift
// Singleton para acesso global
let service = DeviceInfoService.shared

// Obter informações do SDK (usa BeAroundSDKConfig.version automaticamente)
let sdkInfo = service.getSDKInfo()

// Ou especificar versão customizada se necessário
let customSdkInfo = service.getSDKInfo(version: "1.2.0")

// Obter informações do dispositivo (async)
let deviceInfo = await service.getUserDeviceInfo()

// Criar contexto de scan
let scanContext = service.createScanContext(
    rssi: -63,
    txPower: -59,
    approxDistanceMeters: 1.8
)

// Gerar novo ID de sessão de scan
service.generateNewScanSession()

// Marcar que o cold start terminou
service.markWarmStart()
```

#### BeAroundSDKConfig - Versão centralizada:
```swift
// ✅ FORMA CORRETA: Usar BeAroundSDKConfig
let version = BeAroundSDKConfig.version // "1.2.0"
let sdkName = BeAroundSDKConfig.name    // "BeAroundSDK"
let logTag = BeAroundSDKConfig.logTag   // "[BeAroundSDK]"

// ❌ DEPRECATED: Não usar mais
let oldVersion1 = SDK.version              // Deprecated
let oldVersion2 = DesignSystemVersion.current // Deprecated
```

#### Formato do Payload JSON:
O novo formato enviado ao endpoint `/ingest`:

```json
{
  "beacons": [
    {
      "uuid": "E25B8D3C-947A-452F-A13F-589CB706D2E5",
      "name": "B:1.0_1000.2000_100_0_20"
    }
  ],
  "sdk": {
    "version": "1.2.0",
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
    "bluetoothState": "on",
    "locationPermission": "authorized_when_in_use",
    "locationAccuracy": "full",
    "notificationsPermission": "authorized",
    "networkType": "wifi",
    "cellularGeneration": "4g",
    "ramTotalMb": 4096,
    "ramAvailableMb": 1280,
    "screenWidth": 1170,
    "screenHeight": 2532,
    "advertisingId": "...",
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

### Breaking Changes
⚠️ **ATENÇÃO**: Esta versão contém breaking changes!

1. O struct `PostData` foi removido
2. O método `APIService.sendBeacons(_:completion:)` foi removido
3. Não há mais compatibilidade com o formato legado de payload

Se você precisa migrar de versões anteriores, você **DEVE** atualizar seu código para usar o novo formato `IngestPayload`.

### Improvements
✅ **Melhorias de arquitetura**:

1. **Versão centralizada**: A versão do SDK agora está definida em um único local (`BeAroundSDKConfig.version`)
2. **Código mais limpo**: Eliminação de duplicação de strings de versão
3. **Melhor manutenibilidade**: Para atualizar a versão, basta modificar um único valor em `Constants.swift`
4. **APIs deprecadas marcadas**: Structs antigos (`SDK`, `DesignSystemVersion`) agora mostram avisos de compilação

### How to Update SDK Version
Para atualizar a versão do SDK no futuro:

1. Abra `Constants.swift`
2. Localize `BeAroundSDKConfig.version`
3. Altere o valor: `public static let version: String = "X.Y.Z"`
4. Atualize este CHANGELOG.md
5. Commit e crie uma tag: `git tag vX.Y.Z`

**Importante**: Nunca altere a versão em outros arquivos. Todos devem usar `BeAroundSDKConfig.version`.

### Requirements
- iOS 13.0+
- Swift 5.0+
- Xcode 11.0+

### Dependencies
- CoreLocation
- CoreBluetooth
- AdSupport
- AppTrackingTransparency
- Network
- CoreTelephony
- UserNotifications


## [1.1.1] - 2025-11-26

### Added
- Enhanced permission management with async/await support for iOS 13+
- New `requestPermissions()` async method for modern Swift concurrency
- Completion-based `requestPermissions(completion:)` for backward compatibility
- Public `currentIDFA()` method to safely retrieve IDFA with proper authorization checks
- Three listener protocols for better event handling:
  - `BeaconListener` - Beacon detection events
  - `SyncListener` - API synchronization status
  - `RegionListener` - Region entry/exit events
- Public methods to get beacon data:
  - `getActiveBeacons()` - Returns beacons seen within last 5 seconds
  - `getAllBeacons()` - Returns all detected beacons
- Region tracking with automatic state change detection

### Changed
- Improved IDFA handling with proper ATT authorization checks
- Better privacy compliance with iOS 14+ tracking authorization
- Refactored listener architecture with add/remove methods
- Enhanced background beacon monitoring
- Improved error handling and retry logic for API calls

### Fixed
- IDFA now returns empty string when tracking is not authorized
- Proper handling of App Tracking Transparency on iOS 14.5+
- Memory leaks with listener cleanup in deinit
- Region state change notifications

## [1.1.0]

### Added
- Initial stable release
- Basic beacon detection functionality
- API synchronization
- Background monitoring support

## [1.0.0]

### Added
- Initial release of BearoundSDK
- Core beacon scanning capabilities
- Basic API integration
