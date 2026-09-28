//
//  DetectionReadinessTests.swift
//  BearoundSDKTests
//
//  The four regimes of beacon detection on iOS, over the whole permission matrix.
//  The decision is a pure function precisely so it can be tested here instead of
//  against whatever the simulator happens to be granting.
//

import CoreLocation
import Foundation
import Testing

@testable import BearoundSDK

@Suite("DetectionReadiness Tests")
struct DetectionReadinessTests {

    private func evaluate(
        _ status: CLAuthorizationStatus,
        fullAccuracy: Bool = true,
        locationServicesEnabled: Bool = true,
        bluetoothAuthorized: Bool = true,
        declaresBluetoothCentral: Bool = true
    ) -> BeAroundDetectionReadiness {
        BeAroundDetectionReadiness.evaluate(
            locationStatus: status,
            fullAccuracy: fullAccuracy,
            locationServicesEnabled: locationServicesEnabled,
            bluetoothAuthorized: bluetoothAuthorized,
            declaresBluetoothCentral: declaresBluetoothCentral
        )
    }

    @Test("Always + full accuracy is the only regime with a waker")
    func alwaysIsFull() {
        #expect(evaluate(.authorizedAlways) == .full)
        // The BLE eye is irrelevant here: region monitoring is a CoreLocation path and
        // arms without the app holding any Bluetooth authorization.
        #expect(evaluate(.authorizedAlways, bluetoothAuthorized: false) == .full)
        #expect(evaluate(.authorizedAlways, declaresBluetoothCentral: false) == .full)
    }

    @Test("whenInUse is NOT a waker: this is the kCLErrorDomain#4 install")
    func whenInUseIsNotAWaker() {
        // The field case: cutpro on iOS 18.7.2. iOS refuses to arm the region, so the
        // best available regime is whatever Bluetooth can do.
        #expect(evaluate(.authorizedWhenInUse) == .backgroundBle)
        #expect(evaluate(.authorizedWhenInUse, declaresBluetoothCentral: false) == .foregroundOnly)
    }

    @Test("Precise Location off drops Always out of full: every beacon API is disabled")
    func reducedAccuracyLosesTheWaker() {
        #expect(evaluate(.authorizedAlways, fullAccuracy: false) == .backgroundBle)
        #expect(
            evaluate(.authorizedAlways, fullAccuracy: false, declaresBluetoothCentral: false)
                == .foregroundOnly
        )
        // Nothing left: no beacon API, and the BLE eye is denied.
        #expect(
            evaluate(.authorizedAlways, fullAccuracy: false, bluetoothAuthorized: false) == .blind
        )
    }

    @Test("Location Services off device-wide is the same loss as losing the authorization")
    func locationServicesOff() {
        #expect(evaluate(.authorizedAlways, locationServicesEnabled: false) == .backgroundBle)
        #expect(
            evaluate(.authorizedAlways, locationServicesEnabled: false, bluetoothAuthorized: false)
                == .blind
        )
    }

    @Test("Without Location the BLE eye carries it, and the background mode decides how far")
    func bluetoothOnlyRegimes() {
        for status in [CLAuthorizationStatus.denied, .restricted, .notDetermined] {
            #expect(evaluate(status) == .backgroundBle)
            #expect(evaluate(status, declaresBluetoothCentral: false) == .foregroundOnly)
            #expect(evaluate(status, bluetoothAuthorized: false) == .blind)
        }
    }

    @Test("Foreground ranging alone still beats blind")
    func foregroundRangingWithoutBluetooth() {
        // Bluetooth denied but Location can range: the app detects while it is open.
        #expect(evaluate(.authorizedWhenInUse, bluetoothAuthorized: false) == .foregroundOnly)
    }

    @Test("Every regime explains itself")
    func explanationsAreNotEmpty() {
        for regime in [
            BeAroundDetectionReadiness.full, .backgroundBle, .foregroundOnly, .blind,
        ] {
            #expect(!regime.explanation.isEmpty)
            #expect(!regime.rawValue.isEmpty)
        }
    }
}
