# 🐻 ``BearoundSDK``

Swift SDK for iOS — secure BLE beacon detection and indoor positioning by Bearound.

## Overview

BearoundSDK provides BLE beacon detection and indoor location technology for iOS applications, built on a hybrid **two-eye** model: a Bluetooth eye (CoreBluetooth scan + state restoration, no Location permission required) and an optional Location eye (CLBeaconRegion monitoring, survives user force-quit, requires Location "Always").

> Important: The **README at the repository root is the single source of truth** for
> integration documentation — installation, `Info.plist` keys, background execution,
> terminated-app detection, the `/ingest` payload format, and testing. This catalog
> only maps the public API surface. When this page and the README disagree, the
> README wins.

### Quick orientation

- Configure and start the SDK inside `application(_:didFinishLaunchingWithOptions:)` — never in `viewDidLoad` (state restoration relaunches the app and the SDK must rebuild its managers before launch returns).
- `BeAroundSDK.shared.registerBackgroundTasks()` is the single entry point that registers both BGTasks (`io.bearound.sdk.sync` and `io.bearound.sdk.processing`) and installs the APNs token capture.
- Sync lifecycle callbacks are ``BeAroundSDKDelegate/willStartSync(beaconCount:)`` and ``BeAroundSDKDelegate/didCompleteSync(beaconCount:success:error:)``. (`didUpdateSyncStatus` was removed in v2.2.)
- Data is sent to `https://ingest.bearound.io` (hardcoded). The SDK does **not** collect GPS coordinates or the IDFA.

## Topics

### Essentials

- ``BeAroundSDK``
- ``BeAroundSDKDelegate``
- ``SDKConfiguration``
- ``ScanPrecision``
- ``MaxQueuedPayloads``

### Beacon model

- ``Beacon``
- ``BeaconProximity``
- ``BeaconDiscoverySource``
- ``BeaconMetadata``

### Permissions & background

- ``BeAroundLocationAuthorization``
- ``BluetoothScanMode``
- ``BackgroundTaskManager``

### User data & diagnostics

- ``UserProperties``
- ``BeAroundDiagnostics``
