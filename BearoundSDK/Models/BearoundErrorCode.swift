//
//  BearoundErrorCode.swift
//  BearoundSDK
//
//  Created by Bearound on 02/07/26.
//

import Foundation

/// Stable, public error codes for every `NSError` the SDK surfaces through
/// `BeAroundSDKDelegate.didFailWithError(_:)`.
///
/// All errors raised by the SDK use the domain `"BeAroundSDK"` and one of the
/// raw values below as their `code`. Host apps can switch on
/// `BearoundErrorCode(rawValue: nsError.code)` instead of matching magic
/// integers or fragile localized strings.
///
/// The raw values are frozen — they match the historical integer codes the SDK
/// has emitted since the first release, so adding this enum is source- and
/// wire-compatible. New cases must be appended with new integers; existing
/// integers must never be reused for a different meaning.
public enum BearoundErrorCode: Int {

    /// Location authorization is required to start CoreLocation beacon ranging,
    /// but the current status is not `authorizedWhenInUse`/`authorizedAlways`.
    /// Raised by `BeaconManager.startScanning()`.
    case locationPermissionRequired = 1

    /// Location access was denied or restricted after scanning had started, so
    /// the Location eye had to stop. Raised on a CoreLocation authorization
    /// change to `.denied`/`.restricted`.
    case locationPermissionDenied = 2

    /// `startScanning()` was called before `configure(businessToken:)`.
    case notConfigured = 3

    /// Background location updates were requested but `location` is missing from
    /// `UIBackgroundModes` in the host app's Info.plist.
    case backgroundModesMissing = 4

    /// CoreLocation ranging is flapping — it was restarted more times than the
    /// per-minute safety threshold, indicating an unstable ranging session.
    case rangingUnstable = 5

    /// The ingest API has been unreachable for too many consecutive sync
    /// attempts (circuit breaker). Beacons remain queued on disk for retry.
    case syncCircuitOpen = 6

    /// Beacon scanning cannot run: Bluetooth is denied AND Precise Location is
    /// off, so neither the Bluetooth eye nor the Location eye can operate.
    case noScanAuthorization = 7

    /// A device register / beacon sync upload to the ingest API failed. The
    /// underlying `NSError` from the network layer is propagated as-is; this
    /// code is used only when re-wrapping is needed.
    case registerFailed = 8
}
