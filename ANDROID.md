# Prompt: Implement Scan Precision Mode on Android BearoundSDK

> **Target model:** Claude Opus 4.6
> **Language:** Kotlin
> **UI:** Jetpack Compose
> **Min SDK:** 26 (Android 8.0)
> **Architecture:** MVVM + Singleton SDK

---

## Objective

Implement the **Scan Precision** system on the Android BearoundSDK, replacing the old `ForegroundScanInterval` / `BackgroundScanInterval` system. This new system controls the duty cycle of **both BLE and Beacon scanning** with a single parameter.

The Android implementation must match the iOS behavior exactly so both platforms produce consistent scanning patterns and API payloads.

---

## PART 1: What Changed (iOS Reference)

### Old System (REMOVED)

```kotlin
// DELETED — these no longer exist
enum class ForegroundScanInterval(val seconds: Int) { SECONDS_5, SECONDS_10, ..., SECONDS_60 }
enum class BackgroundScanInterval(val seconds: Int) { SECONDS_15, SECONDS_30, ..., SECONDS_120 }

fun configure(
    businessToken: String,
    foregroundScanInterval: ForegroundScanInterval = ForegroundScanInterval.SECONDS_15,
    backgroundScanInterval: BackgroundScanInterval = BackgroundScanInterval.SECONDS_60,
    maxQueuedPayloads: MaxQueuedPayloads = MaxQueuedPayloads.MEDIUM
)
```

### New System (SCAN PRECISION)

```kotlin
enum class ScanPrecision(val value: String) {
    HIGH("high"),
    MEDIUM("medium"),
    LOW("low")
}

fun configure(
    context: Context,
    businessToken: String,
    scanPrecision: ScanPrecision = ScanPrecision.HIGH,
    maxQueuedPayloads: MaxQueuedPayloads = MaxQueuedPayloads.MEDIUM
)
```

---

## PART 2: Precision Mode Specification

### Timing Table

| Mode | Label | Duty Cycle | Location Accuracy |
|------|-------|------------|-------------------|
| **HIGH** | Ininterrupto | BLE + Beacon contínuo. Sync a cada 15s | PRIORITY_BALANCED_POWER_ACCURACY (~10m) |
| **MEDIUM** | 3x10s/min | 3 ciclos de 10s scan + 10s pause por minuto. Sync a cada 60s | PRIORITY_BALANCED_POWER_ACCURACY (~10m) |
| **LOW** | 1x10s/min | 1 ciclo de 10s scan + 50s pause por minuto. Sync a cada 60s | PRIORITY_LOW_POWER (~100m) |

### Visual Timeline (60s window)

```
HIGH:   |████████████████████████████████████████████████████████████| BLE contínuo
        |████████████████████████████████████████████████████████████| Beacon contínuo
        0s                                                        60s
        sync↑              sync↑              sync↑              sync↑  (every 15s)

MEDIUM: |██████████░░░░░░░░░░██████████░░░░░░░░░░██████████░░░░░░░░| BLE 3x10s
        |██████████░░░░░░░░░░██████████░░░░░░░░░░██████████░░░░░░░░| Beacon 3x10s
        0    10   20    30   40    50   60s
                                              sync↑

LOW:    |██████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░| BLE 1x10s
        |██████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░| Beacon 1x10s
        0    10                                               60s
                                                          sync↑
```

---

## PART 3: SDKConfiguration — Computed Properties

The `SDKConfiguration` must have these computed properties based on `scanPrecision`:

```kotlin
data class SDKConfiguration(
    val appId: String,
    val businessToken: String,
    val scanPrecision: ScanPrecision,
    val maxQueuedPayloads: MaxQueuedPayloads,
    val apiBaseURL: String = "https://ingest.bearound.io"
) {
    /** Duration of each scan window (seconds) — always 10 */
    val precisionScanDuration: Long = 10_000L  // 10s in ms

    /** Pause duration between scan windows (ms) */
    val precisionPauseDuration: Long
        get() = when (scanPrecision) {
            ScanPrecision.HIGH -> 0L
            ScanPrecision.MEDIUM -> 10_000L   // 10s
            ScanPrecision.LOW -> 50_000L      // 50s
        }

    /** Number of scan cycles per interval (0 = continuous) */
    val precisionCycleCount: Int
        get() = when (scanPrecision) {
            ScanPrecision.HIGH -> 0
            ScanPrecision.MEDIUM -> 3
            ScanPrecision.LOW -> 1
        }

    /** Full cycle interval (ms) — always 60s */
    val precisionCycleInterval: Long = 60_000L

    /** Location accuracy priority */
    val precisionLocationPriority: Int
        get() = when (scanPrecision) {
            ScanPrecision.HIGH, ScanPrecision.MEDIUM ->
                Priority.PRIORITY_BALANCED_POWER_ACCURACY  // ~10m
            ScanPrecision.LOW ->
                Priority.PRIORITY_LOW_POWER                // ~100m
        }

    /** Sync interval (ms): high=15s, medium/low=60s */
    val syncInterval: Long
        get() = when (scanPrecision) {
            ScanPrecision.HIGH -> 15_000L
            ScanPrecision.MEDIUM, ScanPrecision.LOW -> 60_000L
        }
}
```

---

## PART 4: Duty Cycle Implementation (Core Logic)

This is the most important part. The main SDK class must implement the precision-based duty cycle.

### startSyncTimer() — Entry Point

```kotlin
private fun startSyncTimer() {
    val config = configuration ?: return
    stopSyncTimer()

    val precision = config.scanPrecision

    if (precision == ScanPrecision.HIGH) {
        // Continuous BLE + Beacon scanning, sync every 15s
        bluetoothManager.resumeScanning()
        beaconManager.resumeScanning()  // Android equivalent of resumeRanging

        syncTimer = Timer().apply {
            scheduleAtFixedRate(object : TimerTask() {
                override fun run() {
                    syncTrigger = "precision_high_timer"
                    syncBeacons()
                }
            }, config.syncInterval, config.syncInterval)
        }
        return
    }

    // MEDIUM / LOW: Duty cycle — N cycles of 10s scan + pause, then sync
    // Start first set of cycles immediately
    startDutyCycles(config.precisionScanDuration, config.precisionPauseDuration, config.precisionCycleCount)

    // Repeat every cycleInterval (60s)
    syncTimer = Timer().apply {
        scheduleAtFixedRate(object : TimerTask() {
            override fun run() {
                // Sync at the start of each new interval
                syncTrigger = "precision_${precision.value}_timer"
                syncBeacons()

                // Start new set of cycles
                startDutyCycles(config.precisionScanDuration, config.precisionPauseDuration, config.precisionCycleCount)
            }
        }, config.precisionCycleInterval, config.precisionCycleInterval)
    }
}
```

### startDutyCycles() — Runs N scan+pause cycles

```kotlin
private fun startDutyCycles(scanDuration: Long, pauseDuration: Long, cycleCount: Int) {
    stopDutyCycleTimer()

    var currentCycle = 0

    fun runCycle() {
        if (currentCycle >= cycleCount) return

        // START scanning
        bluetoothManager.resumeScanning()
        beaconManager.resumeScanning()
        Log.d(TAG, "Duty cycle ${currentCycle + 1}/$cycleCount START (scan ${scanDuration}ms)")

        // After scanDuration, PAUSE
        handler.postDelayed({
            bluetoothManager.pauseScanning()
            beaconManager.pauseScanning()
            Log.d(TAG, "Duty cycle ${currentCycle + 1}/$cycleCount PAUSE (${pauseDuration}ms)")

            currentCycle++

            // If more cycles remain, schedule next one after pause
            if (currentCycle < cycleCount) {
                handler.postDelayed({ runCycle() }, pauseDuration)
            }
        }, scanDuration)
    }

    runCycle()
}
```

---

## PART 5: BluetoothManager — Add pause/resume

The BLE scanner needs pause/resume methods for duty cycle control. These are **different** from start/stop — they temporarily halt scanning without changing the `isScanning` state.

```kotlin
class BluetoothManager {
    private var isScanning = false

    fun startScanning() { /* existing — sets isScanning=true, starts scan */ }
    fun stopScanning()  { /* existing — sets isScanning=false, clears state */ }

    /** Temporarily pause BLE scanning (duty cycle control) */
    fun pauseScanning() {
        if (!isScanning) return
        bluetoothLeScanner?.stopScan(scanCallback)
        stopCleanupTimer()
    }

    /** Resume BLE scanning after a pause */
    fun resumeScanning() {
        if (!isScanning) return
        beginScan()  // internal method that starts the actual BLE scan
        startCleanupTimer()
    }
}
```

**Key difference from stop/start:**
- `pauseScanning()` does NOT set `isScanning = false`
- `resumeScanning()` does NOT set `isScanning = true`
- They just stop/start the actual BLE hardware scan

---

## PART 6: BeaconManager (Location/Beacon) — Add pause/resume + updateAccuracy

### Android Beacon Detection

On Android, beacon detection uses either:
- **AltBeacon library** (`BeaconManager` from `org.altbeacon.beacon`)
- **Raw BLE scanning** (same as BluetoothManager but parsing iBeacon format)
- **Geofencing API** for region monitoring equivalent

The pause/resume pattern is the same:

```kotlin
class BeaconManager {
    private var isScanning = false

    /** Temporarily pause beacon scanning */
    fun pauseScanning() {
        if (!isScanning) return
        // Stop ranging but keep monitoring active
        altBeaconManager?.stopRangingBeacons(region)
        // Stop location updates to save battery
        fusedLocationClient.removeLocationUpdates(locationCallback)
    }

    /** Resume beacon scanning */
    fun resumeScanning() {
        if (!isScanning) return
        altBeaconManager?.startRangingBeacons(region)
        // Only start location updates in foreground
        if (isInForeground) {
            startLocationUpdates()
        }
    }

    /** Update location accuracy based on precision */
    fun updateLocationPriority(priority: Int) {
        locationRequest = LocationRequest.Builder(priority, intervalMs).build()
        // If currently tracking, restart with new priority
        if (isTrackingLocation) {
            fusedLocationClient.removeLocationUpdates(locationCallback)
            fusedLocationClient.requestLocationUpdates(locationRequest, locationCallback, Looper.getMainLooper())
        }
    }
}
```

---

## PART 7: GPS Battery Optimization (CRITICAL)

**On iOS we discovered that `startUpdatingLocation()` running continuously in background was the #1 battery drain** (2% → 25% daily usage). The fix:

### Rule: GPS only runs in foreground

| State | GPS (Location Updates) | Beacon Ranging | Region Monitoring | BLE Scan |
|-------|----------------------|----------------|-------------------|----------|
| **Foreground** | ON | ON | ON | ON |
| **Background** | **OFF** | ON | ON | ON |

### Android Implementation

```kotlin
// When app goes to background:
fun onAppBackground() {
    // STOP GPS — this is the biggest battery saver
    fusedLocationClient.removeLocationUpdates(locationCallback)

    // Beacon ranging + BLE continue (controlled by duty cycle)
    // Region monitoring (geofences) continue
}

// When app comes to foreground:
fun onAppForeground() {
    // RESUME GPS for coordinate data in API payload
    if (isScanning) {
        fusedLocationClient.requestLocationUpdates(locationRequest, locationCallback, Looper.getMainLooper())
    }
}
```

### In resumeRanging() / pauseRanging()

```kotlin
fun resumeRanging() {
    // Start beacon ranging
    altBeaconManager?.startRangingBeacons(region)

    // GPS only in foreground
    if (isInForeground) {
        fusedLocationClient.requestLocationUpdates(locationRequest, locationCallback, Looper.getMainLooper())
    }
}

fun pauseRanging() {
    altBeaconManager?.stopRangingBeacons(region)

    // Stop GPS if in foreground (in background it's already off)
    if (isInForeground) {
        fusedLocationClient.removeLocationUpdates(locationCallback)
    }
}
```

---

## PART 8: Region Entry — Immediate Scan

When the device enters a beacon region (geofence equivalent), the SDK must start an immediate scan regardless of duty cycle state:

### iOS Behavior (replicate on Android)

```
Region entry detected:
  ├── If already scanning (ranging active): do nothing (already detecting)
  ├── If in foreground but ranging paused (duty cycle pause):
  │     └── START ranging immediately (don't wait for next cycle)
  ├── If in background but ranging paused:
  │     └── START ranging immediately
  └── If app was killed and relaunched by region entry:
        └── Auto-configure from storage, start ranging for 25s, sync
```

### Android Implementation

```kotlin
// GeofenceBroadcastReceiver or similar
fun onRegionEntered() {
    if (!beaconManager.isRanging && beaconManager.isScanning) {
        // Duty cycle is in PAUSE phase — start immediate scan
        bluetoothManager.resumeScanning()
        beaconManager.resumeScanning()
        Log.d(TAG, "Region entered during pause — immediate ranging started")
    }
}
```

---

## PART 9: Configuration Persistence

Save `scanPrecision` to SharedPreferences (equivalent of iOS UserDefaults):

```kotlin
object SDKConfigStorage {
    private const val PREFS_NAME = "com.bearound.sdk.config"
    private const val KEY_BUSINESS_TOKEN = "business_token"
    private const val KEY_SCAN_PRECISION = "scan_precision"        // NEW (replaces intervals)
    private const val KEY_MAX_QUEUED_PAYLOADS = "max_queued_payloads"
    private const val KEY_IS_CONFIGURED = "is_configured"
    private const val KEY_IS_SCANNING = "is_scanning"

    fun save(context: Context, config: SDKConfiguration) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit().apply {
            putString(KEY_BUSINESS_TOKEN, config.businessToken)
            putString(KEY_SCAN_PRECISION, config.scanPrecision.value)   // "high", "medium", "low"
            putInt(KEY_MAX_QUEUED_PAYLOADS, config.maxQueuedPayloads.value)
            putBoolean(KEY_IS_CONFIGURED, true)
            apply()
        }
    }

    fun load(context: Context): SDKConfiguration? {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_IS_CONFIGURED, false)) return null

        val token = prefs.getString(KEY_BUSINESS_TOKEN, null) ?: return null
        val precisionRaw = prefs.getString(KEY_SCAN_PRECISION, "high") ?: "high"
        val maxQueued = prefs.getInt(KEY_MAX_QUEUED_PAYLOADS, 100)

        return SDKConfiguration(
            appId = context.packageName,
            businessToken = token,
            scanPrecision = ScanPrecision.entries.find { it.value == precisionRaw } ?: ScanPrecision.HIGH,
            maxQueuedPayloads = MaxQueuedPayloads.entries.find { it.value == maxQueued } ?: MaxQueuedPayloads.MEDIUM
        )
    }

    // REMOVE: old foreground_interval / background_interval keys
}
```

---

## PART 10: Demo App — Settings UI

Replace the old interval pickers with a single precision picker:

### OLD (remove):
```kotlin
// DELETE these
var foregroundInterval by mutableStateOf(ForegroundScanInterval.SECONDS_15)
var backgroundInterval by mutableStateOf(BackgroundScanInterval.SECONDS_60)
```

### NEW:
```kotlin
var scanPrecision by mutableStateOf(ScanPrecision.HIGH)
```

### Compose UI

```kotlin
@Composable
fun SettingsScreen(viewModel: BeaconViewModel) {
    // Replace "Intervalos de Sync" section with:
    Text("Precisão do Scan", style = MaterialTheme.typography.titleMedium)

    val options = listOf(
        ScanPrecision.HIGH to "Alta (Ininterrupto)",
        ScanPrecision.MEDIUM to "Média (3x10s/min)",
        ScanPrecision.LOW to "Baixa (1x10s/min)"
    )

    options.forEach { (precision, label) ->
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .selectable(
                    selected = viewModel.scanPrecision == precision,
                    onClick = { viewModel.scanPrecision = precision }
                )
                .padding(8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            RadioButton(
                selected = viewModel.scanPrecision == precision,
                onClick = { viewModel.scanPrecision = precision }
            )
            Text(label, modifier = Modifier.padding(start = 8.dp))
        }
    }
}
```

### Scan Info Display

Replace interval/duration display with precision label:

```kotlin
// OLD (remove):
Text("Intervalo de sync: ${viewModel.currentDisplayInterval}s")
Text("Duração do scan: ${viewModel.scanDuration}s")

// NEW:
Text("Precisão: ${viewModel.scanPrecisionLabel}")
// where scanPrecisionLabel returns "Alta (Ininterrupto)", "Média (3x10s/min)", etc.
```

---

## PART 11: Android-Specific Considerations

### Foreground Service

Android requires a **Foreground Service** for continuous BLE scanning in background. The duty cycle should run inside this service:

```kotlin
class BearoundScanService : Service() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Show persistent notification
        startForeground(NOTIFICATION_ID, createNotification())

        // Start duty cycle based on precision
        BearoundSDK.startSyncTimer()

        return START_STICKY
    }
}
```

### WorkManager for Periodic Sync

For `MEDIUM` and `LOW` precision, consider using `WorkManager` as a backup sync mechanism:

```kotlin
val syncWork = PeriodicWorkRequestBuilder<SyncWorker>(
    config.syncInterval, TimeUnit.MILLISECONDS
).build()
WorkManager.getInstance(context).enqueueUniquePeriodicWork(
    "bearound_sync",
    ExistingPeriodicWorkPolicy.UPDATE,
    syncWork
)
```

### Doze Mode

Android Doze mode can delay timers. For reliable duty cycling:
- Use `AlarmManager.setExactAndAllowWhileIdle()` for critical cycle transitions
- Or use the Foreground Service approach above

### BLE Scan Throttling (Android 8.0+)

Android limits background BLE scans to ~5 scans per 30 seconds. The duty cycle naturally respects this:
- HIGH: continuous (uses foreground service exemption)
- MEDIUM: 3 scans per 60s (well within limits)
- LOW: 1 scan per 60s (well within limits)

---

## PART 12: Migration Checklist

### Files to Modify

1. **ScanPrecision enum** — Create new, delete `ForegroundScanInterval` and `BackgroundScanInterval`
2. **SDKConfiguration** — Replace intervals with `scanPrecision`, add computed properties
3. **BearoundSDK (main class)** — New `configure()` signature, rewrite `startSyncTimer()`, add `startDutyCycles()`
4. **BluetoothManager** — Add `pauseScanning()` / `resumeScanning()`
5. **BeaconManager** — Add `pauseScanning()` / `resumeScanning()` / `updateLocationPriority()`
6. **SDKConfigStorage** — Replace interval keys with `scan_precision`
7. **ViewModel** — Replace `foregroundInterval` / `backgroundInterval` with `scanPrecision`
8. **Settings UI** — Replace interval pickers with precision picker
9. **Scan Info UI** — Show precision label instead of intervals

### Properties to Remove

```kotlin
// DELETE from SDK:
val currentSyncInterval: Long?
val currentScanDuration: Long?

// REPLACE with:
val currentScanPrecision: ScanPrecision?
```

### Public API Change

```kotlin
// OLD:
BearoundSDK.configure(
    context = this,
    businessToken = "TOKEN",
    foregroundScanInterval = ForegroundScanInterval.SECONDS_15,
    backgroundScanInterval = BackgroundScanInterval.SECONDS_60,
    maxQueuedPayloads = MaxQueuedPayloads.MEDIUM
)

// NEW:
BearoundSDK.configure(
    context = this,
    businessToken = "TOKEN",
    scanPrecision = ScanPrecision.HIGH,
    maxQueuedPayloads = MaxQueuedPayloads.MEDIUM
)
```

---

## PART 13: Summary of Key Behaviors

1. **Precision is the ONLY scanning parameter** — no more FG/BG interval distinction
2. **Same behavior in foreground and background** — precision controls duty cycle identically
3. **GPS only in foreground** — `FusedLocationProvider` stops in background to save battery
4. **Region entry triggers immediate scan** — even during duty cycle pause
5. **BLE and Beacon pause/resume together** — duty cycle controls both simultaneously
6. **Sync after cycles complete** — MEDIUM/LOW sync at end of 60s interval, HIGH syncs every 15s
7. **Configuration persisted** — `scanPrecision` saved to SharedPreferences for background relaunch
