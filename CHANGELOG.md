# Changelog

All notable changes to BearoundSDK for iOS will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.4.5] - 2026-07-04

### Added

- **First-party error telemetry (`ErrorReporter`).** New isolated module `BearoundSDK/Telemetry/ErrorReporter.swift` that ships SDK-internal errors and uncaught `NSException`s (raised inside our library) to `POST https://ingest.bearound.io/sdk-errors`, at parity with the Android `io.bearound.sdk.telemetry.ErrorReporter`. Installed idempotently from `configure(...)` and from `autoConfigureFromStorage()` (covers background relaunch). Behavior mirrors Android's "golden rules": (1) never throws / never breaks the host / never hijacks the app's crash handler; (2) only reports errors that ORIGINATE in our library, never the host app's — the uncaught path attributes ownership by the **first application image** in `callStackSymbols` (skipping Apple runtime/framework images), so a host crash that merely passes *through* an SDK callback (the app's own image on top, ours below) is never captured; (3) the `NSSetUncaughtExceptionHandler` is **always chained** — the previously installed handler (Crashlytics/Sentry/host) is captured before installing and always delegated to; (4) fire-and-forget with a 20/hour rate limit + 5-minute dedupe (SHA-256 of `platform|context|firstStackLine|type`) and an 8000-char stack cap; (5) an own ephemeral `URLSession` with a 5s timeout, never the beacon-upload background session; (6) public opt-out `BeAroundSDK.shared.setErrorReportingEnabled(_:)`, default ON. Internal error sites (`beaconManager.onError`, device `register` failure, `syncBeacons` / `drainRetryQueue` failures, and `startScanning` guard errors) now also call `ErrorReporter.shared.report(_:context:)` alongside the existing `DiagnosticsStore.recordError`. Normal operational `APIClient` network errors are intentionally **not** reported. The device snapshot reuses `DeviceInfoCollector.collectDeviceInfo(...)` and adds per-platform `permissions` (bluetooth / locationWhenInUse / fineLocation / locationAlways / notifications) and `systemState` (bluetoothPoweredOn / locationServicesEnabled / notificationsEnabled), each probe guarded so a failing probe is simply omitted. **Not** installed: POSIX signal handlers (SIGABRT/SIGSEGV/…) — see README "Error telemetry" for the trade-off. 100% additive; no existing behavior changed.
- **`BearoundErrorCode` — public error codes.** The 7 raw `NSError` codes the SDK emits via `didFailWithError` are now exposed as a public `BearoundErrorCode` enum (raw values unchanged), so integrators can branch on `notConfigured` / `noScanAuthorization` / … instead of magic numbers.
- **Richer `diagnostics()`.** Adds runtime state — `authorizationStatus`, `bluetoothState`, `backgroundRefreshStatus`, `backgroundTasksRegistered` — so support can triage "not detecting" remotely (parity with the Android `diagnostics()`).

### Fixed

- **Uncatchable crash when the host lacks `bluetooth-central` in `UIBackgroundModes`.** `CBCentralManager` was always created with `CBCentralManagerOptionRestoreIdentifierKey`; without the background mode CoreBluetooth raises `NSInvalidArgumentException` (uncatchable from Swift) on the first `startScanning()`. The restore identifier is now gated on the host's Info.plist — no background mode → no state restoration, foreground scanning unaffected, no crash. Doctrine: the SDK may fail silently, never crash the host.
- **APNs token lost on cold launch under Flutter / React Native.** The push-token swizzle was only installed inside `configure(...)`, which the bridges call late — a cold-launch token registered before that was dropped. The swizzle is now installed early in `registerBackgroundTasks()` (called from `didFinishLaunching`), so the token is captured regardless of when `configure` runs.
- **Register / sync failures now surface to the host.** Device `register` and `syncBeacons` failures were only `NSLog`'d — an integrator with a bad token or an offline device saw scanning "succeed" while the device never appeared in the Control Hub, with no programmatic signal. They now reach `didFailWithError` (with the HTTP status + body).

### Changed

- **Delegate callbacks are guaranteed on the main thread.** `didFailWithError` and the other delegate callbacks always hop to the main queue before invoking the host, so host UI code never touches UIKit off-thread. Documented on the delegate protocol.
- **CI runs the test suite and fails on real build errors** (removed the `xcpretty || true` that masked failures).

### Documentation

- **README regenerated from the code.** Removed the stale "Technical Pending Issues" section (it denied app-closed detection, which the code does), fixed the Quick Start to `didFinishLaunching`, corrected the sync callbacks (`willStartSync` / `didCompleteSync`), documented the real `/ingest` payload and the two BGTask identifiers, and removed the ATT/IDFA block that implied a false privacy label. DocC trimmed to point at the README as the single source.

## [3.4.2] - 2026-06-27

### Changed

- **Alinhamento de versão com a suíte (3.4.2).** Sem mudança de comportamento no iOS — o ajuste desta versão (remoção de `USE_EXACT_ALARM`/`SCHEDULE_EXACT_ALARM`, watchdog com alarme inexato) é **Android-only**. O iOS agenda trabalho em background via `BGTaskScheduler`/region monitoring, não usa `AlarmManager`.

## [3.4.1] - 2026-06-27

### Fixed

- **Push token à prova de ordem (register-on-set).** `setPushToken`, quando o scan já está ativo e o token ainda não foi enviado (`PushTokenStore.tokenForPayload != nil`), força um register imediato (`registerDeviceIfNeeded(force:)` — o método passou a aceitar `force` para ignorar o TTL do `RegisterStore`) em vez de esperar o próximo sync; o register passou a chamar `PushTokenStore.markSent()` no sucesso. Assim o token chega ao backend independentemente de o app chamar `setPushToken` antes ou depois de `startScanning()` — antes, se o register-on-init já tivesse ocorrido, o device ficava sem push até o próximo register (TTL) ou até detectar um beacon.

## [3.4.0] - 2026-06-26

### Added

- **Device register on `startScanning()`.** The SDK now reports the device to the backend on init even before any beacon is detected, so it shows up in the Control Hub on first launch. Sends `POST /ingest` with `beacons: []` + `syncTrigger: "register"`, throttled by a 24h TTL + fingerprint (deviceId, appId, businessToken, sdkVersion, osVersion, appBuild) via a new `RegisterStore`. Reuses the existing device-payload builder; the normal beacon sync still skips empty payloads, so there are no spurious requests.

## [3.3.1] - 2026-06-11

### Fixed

- **BLE zone flap (phantom `bluetoothZoneExit`→`bluetoothZoneEnter`).** Cycles fired ~1ms apart, every 5-10 min, with the device stationary inside a beacon zone (13 occurrences confirmed in iPhone 16 Pro Max device logs over 2h). Root cause: `evaluateZonePresence` read `lastSeen` from `trackedBeacons`, but `cleanupExpiredBeacons` evicted entries after `beaconGracePeriod` (10s) — making the effective zone-exit grace 10s instead of the documented 60s. When the dict emptied, `evaluateZonePresence` hit `guard let last = lastBeaconSeen else { exit }` and fired exit immediately; the next BLE advert fired enter milliseconds later.
- Added cleanup-immune `lastBeaconSeenAt` as the source of truth for both `evaluateZonePresence` and `evaluateActiveGrace` (same trap, different consequence: spurious active→idle demotion). `trackedBeacons` cleanup no longer affects zone or active-mode lifecycles.
- **CoreLocation daemon churn → BLE delivery stalls.** Five call sites instantiated `CLLocationManager()` as a throwaway just to read `.accuracyAuthorization` / `.authorizationStatus`. Each transient instance triggered a TCC IPC (`tcc_send_request_authorization`), spun up a daemon-side client (`_CLClientCreateConnection`), and was dealloc'd ~2ms later. In device logs this manifested as init→dealloc cycles every ~1.5s with periodic `CLConnection::handleInterruption` events, correlating with ~11s gaps in background BLE ad delivery and the "entered zone but UI shows 0 beacons" symptom (zone entry driven by a single weak/far ad while close-by beacons hadn't been delivered yet). Replaced all five throwaways with a single, lifetime-scoped `static let authQueryManager = CLLocationManager()` (read-only — `startMonitoring` / `startUpdatingLocation` are NOT called on it). Added internal helper `sharedAccuracyAuthorization()` for `DeviceInfoCollector` telemetry.
- **Phantom ENTER after iOS termination + state restoration.** When iOS killed the app under memory/policy pressure while the device was inside a beacon zone, the subsequent CoreBluetooth State Restoration cold start would default `isInBluetoothZone = false`. The very first BLE advert delivered after the wake-up triggered the rising-edge branch in `trackBeacon` and fired `onBluetoothZoneEnter` + a "Entrou na zona" notification — even though the device never physically left. Confirmed in device logs: PID 395 (last activity 14:56) terminated by iOS, PID 400 cold-started 14:59:09.812 with `[BluetoothManager] State restoration triggered`, ENTER ZONE fired 15ms later at 14:59:09.827. Fix: persist `(isInBluetoothZone, lastBeaconSeenAt)` to UserDefaults on every state transition (rising/falling edges + `stopScanning`); restore at `BluetoothManager.init()` BEFORE any advert can be processed. Snapshots older than 1 hour are treated as stale and ignored — a genuinely new ENTER still fires.

### Changed

- `zoneExitGracePeriod` increased from **60s → 300s (5 min)** to absorb iOS background BLE delivery stalls observed after silent-push wake on iOS 26 (memory: `project_ios-wake-vector-forensics`). Trade-off: a real physical zone exit takes up to 5 min to fire on the BLE eye; the Location eye (region monitoring) still emits exit on its own channel sooner via GPS confirmation.

## [3.3.0] - 2026-06-10

### Added

- **`sdk.technology` in the `/ingest` payload.** New trailing `technology` parameter on `configure(businessToken:scanPrecision:maxQueuedPayloads:technology:)` (default `ios-native`). The value is persisted and restored on background relaunch, then shipped in the `sdk` block so the backend can attribute traffic per integration. The React Native / Flutter bridges pass `react-native` / `flutter`.
- **`EVENT-PARITY.md`.** Cross-SDK event & field parity matrix (iOS / Android / RN / Flutter) documenting common events and per-platform divergences.

### Changed

- **Wire version derives from the framework bundle — no version literal in Swift.** `BeAroundSDK.version` now reads `CFBundleShortVersionString` from the framework bundle (driven by the Xcode `MARKETING_VERSION`, kept in lockstep with the podspec and git tag by the release workflow) instead of returning a hardcoded string. The reported technology is now a single named constant (`BeAroundSDK.technology = "ios-native"`) referenced by `SDKInfo`, removing the duplicated `"ios-native"` literal.

### Fixed

- **Wire SDK version no longer stale.** The `/ingest` payload previously shipped a hardcoded `2.2.1` (the unused default in `SDKInfo`) regardless of the real SDK version. It now reports `BeAroundSDK.version` (3.3.0).

## [3.2.0] - 2026-06-07

### Changed

- **`setUserProperties` now merges** instead of replacing — a later partial update (adding `email`/`name`) no longer wipes a previously-set `internalId`. Call it right after `configure()` to attach the user's identity at startup.

### Added

- User identity (`internalId` and other user properties) is now **persisted** and restored when iOS relaunches the app in the background, so background events stay attributed to the user.

## [3.1.0] - 2026-06-07

### Added

- **Automatic push-token capture.** The SDK now swizzles `UIApplicationDelegate` push-token callbacks to capture APNs tokens without host integration.
- **APNs environment auto-detection.** Ingest payload now reports whether the build is `development` or `production` based on the embedded mobileprovision / entitlements.
- **Silent push auto-handling.** When silent pushes arrive, the SDK reacts without host glue and performs a deep-background sync.
- **SDK diagnostics snapshot.** `BeAroundSDK.shared.diagnostics()` returns a structured `BeAroundDiagnostics` snapshot (push token state, APNs env, last sync, eye status) for host-app observability.
- **Push-token TTL heartbeat.** The SDK periodically re-sends the push token to keep the server-side mapping fresh.
- **Apple Privacy Manifest (`PrivacyInfo.xcprivacy`).** Declares the SDK's data collection categories and required-reason APIs per Apple's 2024 requirement.
- **App state monitor.** New `AppStateMonitor` reports foreground/background transitions for more accurate session signals.
- **Offline batch storage.** Detections captured while offline are queued and flushed on the next successful connection.

### Changed

- **Background sync is now driven by BLE detection.** Deep-background uploads happen on beacon detection instead of relying solely on timers, improving freshness when the app is suspended.
- **Stable `deviceId` via Keychain.** `deviceId` is now stored in the Keychain (surviving reinstalls on the same device).
- **Single source of truth for the beacon UUID.** Internal callsites share `BeaconConstants.uuid` instead of duplicating the literal.

### Fixed

- Stale privacy note in the README (the SDK does not collect IDFA; it uses a Keychain-stored UUID).

### Docs

- DocC + README now document `diagnostics()`, `apnsEnvironment`, the TTL heartbeat, silent-push handling, and the Privacy Manifest.

---

## [3.0.0] - 2026-05-24

### Breaking changes

- **Removed GPS coordinate capture.** The SDK no longer collects latitude/longitude. Beacon presence detection (region monitoring + ranging) and the BLE eye remain fully functional — only the beacon-gated location window was removed.
- **Removed `BeAroundLocationCapture` public struct.**
- **Removed delegate methods** `didStartLocationCapture(reason:)` and `didCompleteLocationCapture(_:)`. Host apps that observed these must drop the implementations.
- **Internal `DeviceLocation` struct and `UserDevice.deviceLocation` field removed.** Ingest payload no longer carries a `deviceLocation` field.

### Added

- **`BeAroundSDK.requestLocationAuthorization(_:)`** — ergonomic API for opting into the Location eye (CLBeaconRegion monitoring) without importing CoreLocation directly. Accepts `.always` (recommended for force-quit survival) or `.whenInUse`.
- **`BeAroundLocationAuthorization`** public enum — the authorization level passed to `requestLocationAuthorization`.
- **Hybrid two-eye documentation.** README + DocC now explicitly state which wake-up path survives which kind of termination, including a force-quit decision table.
### Fixed

- **BLE scan stays ACTIVE across the SDK lifetime.** Previously `startScanning()` entered an IDLE duty cycle in foreground with the scanner OFF, and only registered the kernel BLE filter 5 minutes later via the first idle peek. A user who tapped Start and immediately swiped the app away never registered the filter and never got BT wake-up. The IDLE branch in `startScanning()` is removed; `sleepToIdle()` and `pauseScanning()` no longer call `stopScan()` (they were silently unregistering the kernel filter mid-session). The scan is now registered for the entire SDK process lifetime — exactly what CoreBluetooth state preservation & restoration requires.

### Empirical evidence

A live capture from `bluetoothd` on a real iPhone confirmed that after the user force-quits the app via swipe-up, iOS removes the SDK's BLE scan filter from the kernel — `won't resurrect. Reason: killed by user`. The documentation now states this as fact (replacing the previous, incorrect note that Path A "historically survives force-quit better than Path B"). The Location eye is the only path that survives a user force-quit on iOS.

### Migration

- If you implemented `didStartLocationCapture` / `didCompleteLocationCapture`, delete those methods (or leave them — they are no-ops).
- If you read `UserDevice.deviceLocation` server-side, the field is gone from the ingest payload.
- If your app needs force-quit-survival: call `BeAroundSDK.shared.requestLocationAuthorization(.always)` during onboarding (or wherever you currently prompt for permissions), and ensure `NSLocationAlwaysAndWhenInUseUsageDescription` + `NSLocationWhenInUseUsageDescription` are present in Info.plist.

---

## [2.4.0] - 2026-05-21

### Changed

- **Location is now strictly beacon-gated.** GPS (`startUpdatingLocation`) and iBeacon ranging (`startRangingBeacons`) only run while iOS reports the device is inside the beacon region. Outside the region, only kernel-level region monitoring stays on — effectively zero battery cost.
- **BLE central scan is gated by region presence.** `CBCentralManager.scanForPeripherals` no longer runs continuously on SDK start; it activates on region entry and stops on region exit.
- **Removed continuous `significantLocationChanges` monitoring.** The SDK no longer tracks coarse cell-tower-based location movements in background. Wake-up for terminated apps now relies on BLE region monitoring + `BackgroundTaskManager` only.
- **Capture-window GPS model.** When a beacon is detected, the SDK opens a one-shot GPS capture window (30s in foreground, 15s in background). The window closes on first fix with `horizontalAccuracy ≤ 30m` or on timeout. While beacons remain in range and the cached fix is fresh (<10min), GPS stays off.

### Added

- `BeAroundSDKDelegate.didEnterBeaconRegion()` — fires when iOS reports BLE region entry.
- `BeAroundSDKDelegate.didExitBeaconRegion()` — fires on region exit.
- `BeAroundSDKDelegate.didStartLocationCapture(reason:)` — fires when a beacon-triggered GPS capture window opens.
- `BeAroundSDKDelegate.didCompleteLocationCapture(_ result: BeAroundLocationCapture)` — fires when the window closes, with the acquired coordinate (if any) and the closing outcome.
- `BeAroundSDKDelegate.didChangeActiveScanState(isActive:)` — fires when ranging+BLE active scanning toggles (true on region entry, false on exit).
- `BeAroundLocationCapture` public struct describing the outcome of a capture window (reason, location?, outcome, timestamp, hasFix).
- All new delegate methods ship with default no-op implementations — no breaking change for existing integrators.

### Fixed

- Duty-cycle timer no longer resumes ranging outside the beacon region. Previously, `BearoundSDK.startSyncTimer` would call `beaconManager.resumeRanging()` on every cycle without a region check, leaving CoreLocation active (and the iOS location indicator visible) even when no beacon was nearby.
- `BluetoothManager.stopScanning()` now also clears `pendingAutoStart`, preventing a deferred Bluetooth power-on from sneaking a scan back in after region exit.

### Battery impact

For an app that spends most of its time outside any beacon region, this release drops CoreLocation + BLE active duty cycle to ~0 outside the region. Expect noticeable battery savings on users who carry the app but rarely encounter beacons.

---

## [2.3.7] - 2026-02-26

### Added

- **Scan Precision Mode**: Replaced `ForegroundScanInterval` and `BackgroundScanInterval` with a single `ScanPrecision` enum (`.high`, `.medium`, `.low`) that controls duty cycle for both BLE and CoreLocation scanning.
  - **High**: Continuous BLE + CL scanning, sync every 15s
  - **Medium**: 3 cycles of 10s scan / 10s pause per 60s interval
  - **Low**: 1 cycle of 10s scan / 50s pause per 60s interval
- **Independent BLE + CL scanning**: BLE and CoreLocation now start independently based on their own authorization status, instead of mutually exclusive modes.
- **Precise Location detection**: SDK now detects when iOS "Precise Location" is disabled (reduced accuracy) and disables CoreLocation beacon ranging, falling back to BLE-only.
- **Chunked retry queue drain**: Offline retry batches are now sent in chunks of 5 batches per API call, chaining sequentially until the queue is fully drained. Previously sent one batch per sync cycle.
- **os_log diagnostics**: Added structured `os_log` logging for BLE/CL scanning state changes.
- **`bleDiagnosticInfo` property**: Public diagnostic string for debugging BLE/CL scanning issues.
- **Detection Log tab**: New tab in the demo app (BeAroundScan) for viewing beacon detection history.
- **Duty Cycle Control**: BLE `pauseScanning()`/`resumeScanning()` and CL ranging pause/resume synchronized per precision mode.
- **Immediate Ranging on Region Entry**: When entering a beacon region during a duty cycle pause in foreground, ranging starts immediately.
- **Android Migration Guide**: Added `ANDROID.md` with full implementation guide for Android SDK.

### Changed

- **`configure()` API simplified**: Replaced `foregroundScanInterval` + `backgroundScanInterval` parameters with single `scanPrecision` parameter.
- **Battery Optimization**: GPS (`startUpdatingLocation`) now only runs in foreground to reduce background battery consumption.
- **`isScanning`**: Now returns `true` if either BLE or CL is scanning (was exclusive).
- **`stopScanning()`**: Stops both BLE and CL independently.
- **BLE beacon cleanup**: Only removes BLE-only beacons that left range; CL-detected beacons are preserved.
- **BLE beacon merge**: When CL is already tracking a beacon, BLE updates no longer overwrite CL data (CL has better proximity/accuracy).
- **Removed `isBluetoothOnlyMode`**: No longer needed; BLE and CL operate independently.
- **Removed `ForegroundScanInterval` and `BackgroundScanInterval` enums**: Replaced by `ScanPrecision`.
- **Removed `currentSyncInterval` and `currentScanDuration` public properties**: Replaced by `currentScanPrecision`.

### Breaking Changes

- `configure(businessToken:foregroundScanInterval:backgroundScanInterval:maxQueuedPayloads:)` replaced by `configure(businessToken:scanPrecision:maxQueuedPayloads:)`.
- `ForegroundScanInterval` and `BackgroundScanInterval` enums removed. Use `ScanPrecision` instead.
- `currentSyncInterval` and `currentScanDuration` properties removed. Use `currentScanPrecision` instead.

---

## [2.3.6] - 2026-02-20

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
- **DeviceInfoService**: new singleton service for comprehensive device information collection
  - SDK information (version, platform, app ID, build)
  - Full user device information:
    - Manufacturer, model, OS, OS version
    - Timestamp, timezone
    - Battery level, charging status
    - Low Power Mode
    - Bluetooth state
    - Location permission and accuracy
    - Notification permission
    - Network type (Wi-Fi, cellular, Ethernet)
    - Cellular generation (2G, 3G, 4G, 5G)
    - Roaming status
    - RAM information
    - Screen resolution
    - Advertising ID (IDFA) and tracking status
    - App state (foreground/background)
    - App uptime
    - Cold-start detection
  - Scan context:
    - RSSI (signal strength)
    - TX Power
    - Approximate distance in meters
    - Scan-session ID
    - Detection timestamp

- **IngestPayload**: new structured data model for the ingest endpoint
  - `BeaconPayload`: represents a single beacon
  - `SDKInfo`: SDK information
  - `UserDeviceInfo`: full device information
  - `ScanContext`: beacon scan context

- **New public methods on BearoundSDK**:
  - `createIngestPayload(for:sdkVersion:)`: builds a complete ingest payload
  - `sendBeaconsWithFullInfo(_:completion:)`: sends beacons with full telemetry

- **BeAroundSDKConfig**: new centralized struct for SDK configuration
  - `version`: SDK version (single source of truth)
  - `name`: SDK name (`"BeAroundSDK"`)
  - `logTag`: tag used across all logs (`"[BeAroundSDK]"`)

### Changed
- **APIService**:
  - Removed the legacy `PostData` type (no longer compatible with older versions)
  - Removed the legacy `sendBeacons(_:completion:)` method
  - Only `sendIngestPayload(_:completion:)` remains, for the new format

- **BearoundSDK**:
  - Internal `sendBeacons(type:_:)` now uses the new `IngestPayload` format
  - Every API call now includes full device telemetry
  - `createIngestPayload()` now defaults to `BeAroundSDKConfig.version`
  - Initialization log in `startServices()` updated to use the centralized version

- **Constants.swift**:
  - Restructured to centralize SDK configuration
  - Introduced `BeAroundSDKConfig` as the public struct for global settings
  - `Constants` is now `internal` and reads from `BeAroundSDKConfig`

- **DeviceInfoService**:
  - `getSDKInfo()` now defaults to `BeAroundSDKConfig.version`

### Removed
- `PostData` struct (legacy format, discontinued)
- `APIService.sendBeacons(_:completion:)` method

### Deprecated
- `SDK.version` (use `BeAroundSDKConfig.version` instead)
- `DesignSystemVersion.current` (use `BeAroundSDKConfig.version` instead)

### Migration Guide

If you were using the legacy API, update your code as follows:

#### Before (legacy format — no longer supported):
```swift
// This code no longer works
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

#### After (new format):
```swift
// Option 1: use the convenience method (recommended)
await sdk.sendBeaconsWithFullInfo(beacons) { result in
    switch result {
    case .success(let data):
        print("Beacons sent successfully")
    case .failure(let error):
        print("Error: \(error)")
    }
}

// Option 2: build the payload manually
let payload = await sdk.createIngestPayload(for: beacons)
// Use the payload as needed
```

### Technical Details

#### DeviceInfoService — new capabilities:
```swift
// Singleton for global access
let service = DeviceInfoService.shared

// Get SDK info (defaults to BeAroundSDKConfig.version)
let sdkInfo = service.getSDKInfo()

// Or pass a custom version when needed
let customSdkInfo = service.getSDKInfo(version: "1.2.0")

// Get device info (async)
let deviceInfo = await service.getUserDeviceInfo()

// Build a scan context
let scanContext = service.createScanContext(
    rssi: -63,
    txPower: -59,
    approxDistanceMeters: 1.8
)

// Generate a new scan-session ID
service.generateNewScanSession()

// Mark the end of cold start
service.markWarmStart()
```

#### BeAroundSDKConfig — centralized version:
```swift
// ✅ CORRECT: use BeAroundSDKConfig
let version = BeAroundSDKConfig.version // "1.2.0"
let sdkName = BeAroundSDKConfig.name    // "BeAroundSDK"
let logTag = BeAroundSDKConfig.logTag   // "[BeAroundSDK]"

// ❌ DEPRECATED: do not use
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
**Heads-up**: this release contains breaking changes.

1. The `PostData` struct was removed
2. `APIService.sendBeacons(_:completion:)` was removed
3. The legacy payload format is no longer supported

If you are migrating from a prior version, you **must** update your code to use the new `IngestPayload` format.

### Improvements
Architecture improvements:

1. **Centralized version**: the SDK version now lives in a single location (`BeAroundSDKConfig.version`)
2. **Cleaner code**: eliminated duplicated version strings
3. **Better maintainability**: to bump the version, change a single value in `Constants.swift`
4. **Deprecated APIs flagged**: legacy structs (`SDK`, `DesignSystemVersion`) now emit compiler warnings

### How to Update SDK Version
To bump the SDK version in the future:

1. Open `Constants.swift`
2. Find `BeAroundSDKConfig.version`
3. Update the value: `public static let version: String = "X.Y.Z"`
4. Update this CHANGELOG.md
5. Commit and tag: `git tag vX.Y.Z`

**Important**: never change the version in any other file. Everything must read from `BeAroundSDKConfig.version`.

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
