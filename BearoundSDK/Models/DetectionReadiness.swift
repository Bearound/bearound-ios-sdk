//
//  DetectionReadiness.swift
//  BearoundSDK
//
//  Created by Bearound on 11/09/26.
//

import CoreBluetooth
import CoreLocation
import Foundation

/// What this install can actually detect, in one value.
///
/// Beacon detection on iOS is not a boolean. It depends on two things the SDK does not
/// own: the authorization the user granted (runtime) and the background modes the host
/// app declared (build time). The SDK can ask for the first and read the second; it can
/// grant neither. So instead of leaving the host to infer the regime from an error string,
/// it names the regime.
///
/// Read it through ``BeAroundSDK/detectionReadiness``. It describes durable capability, not
/// the radio: a powered-off Bluetooth adapter stops detection in every regime and is
/// reported separately (`BeAroundDiagnostics.bluetoothState`), because the user flips it
/// back in seconds.
public enum BeAroundDetectionReadiness: String {

    /// Location `Always` + full accuracy. Region monitoring arms, so iOS relaunches the app
    /// on a beacon region enter **even after the user force-quits it**. The only regime with
    /// a deterministic waker.
    case full

    /// No CoreLocation waker (at most `whenInUse`, or Precise Location off), but the host
    /// declares `bluetooth-central`: the BLE eye keeps scanning in the background and
    /// CoreBluetooth state restoration relaunches the app after a **system** termination.
    /// A force-quit stays dead until the user opens the app again; that gap is Apple's,
    /// and only `Always` closes it.
    case backgroundBle

    /// No CoreLocation waker and no `bluetooth-central` background mode: detection happens
    /// only while the app is in the foreground.
    case foregroundOnly

    /// Nothing can scan: Bluetooth is denied/restricted AND Location cannot range beacons.
    case blind

    /// One sentence for a log line, a support screen, or a diagnostics dump.
    public var explanation: String {
        switch self {
        case .full:
            return "Region monitoring armed: the app is woken on beacon entry, even after a force-quit."
        case .backgroundBle:
            return "No Location waker (Always is missing or Precise Location is off). Bluetooth scans in "
                + "the background and state restoration relaunches the app after a system termination, "
                + "but not after a force-quit."
        case .foregroundOnly:
            return "No Location waker and no 'bluetooth-central' background mode: detection runs only "
                + "with the app in the foreground."
        case .blind:
            return "Neither eye can run: Bluetooth is denied/restricted and Location cannot range beacons."
        }
    }

    /// Pure decision, separated from every live query so it can be unit-tested over the
    /// whole matrix instead of whatever the simulator happens to be granting today.
    ///
    /// - Parameters:
    ///   - locationStatus: current `CLAuthorizationStatus`.
    ///   - fullAccuracy: `false` when the user turned Precise Location off (iOS 14+), which
    ///     disables **every** beacon API, ranging and monitoring alike.
    ///   - locationServicesEnabled: the device-wide switch. Off means no CoreLocation for anyone.
    ///   - bluetoothAuthorized: `CBCentralManager.authorization` is neither denied nor restricted.
    ///   - declaresBluetoothCentral: host's `UIBackgroundModes` contains `bluetooth-central`.
    static func evaluate(
        locationStatus: CLAuthorizationStatus,
        fullAccuracy: Bool,
        locationServicesEnabled: Bool,
        bluetoothAuthorized: Bool,
        declaresBluetoothCentral: Bool
    ) -> BeAroundDetectionReadiness {
        let locationUsable = locationServicesEnabled && fullAccuracy
        let canRangeInForeground = locationUsable
            && (locationStatus == .authorizedAlways || locationStatus == .authorizedWhenInUse)

        // A deterministic waker requires Always. `whenInUse` buys foreground ranging and
        // iOS answers startMonitoring() with kCLErrorDomain 4.
        if locationUsable, locationStatus == .authorizedAlways { return .full }

        guard bluetoothAuthorized || canRangeInForeground else { return .blind }
        if bluetoothAuthorized, declaresBluetoothCentral { return .backgroundBle }
        return .foregroundOnly
    }
}
