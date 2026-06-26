//
//  RegisterStoreTests.swift
//  BearoundSDKTests
//
//  Tests for RegisterStore TTL and fingerprint logic.
//
//  NOTE: These tests exercise pure UserDefaults logic (no UIKit, no CoreBluetooth,
//  no URLSession). They were written to run in the BearoundSDKTests target and should
//  compile and pass with the standard `xcodebuild test` invocation.
//

import Foundation
import Testing

@testable import BearoundSDK

@Suite("RegisterStore Tests")
struct RegisterStoreTests {

    // MARK: - Helpers

    private let fp = "deviceId|com.test|token|3.3.1|17.0|42"

    // Every test gets a clean slate so tests are independent.
    init() {
        RegisterStore._clearForTesting()
    }

    // MARK: - First-launch

    @Test("shouldRegister is true when never registered before")
    func neverRegistered() {
        #expect(RegisterStore.shouldRegister(currentFingerprint: fp) == true)
    }

    // MARK: - Fingerprint change

    @Test("shouldRegister is false right after markRegistered with same fingerprint")
    func noRetriggerWhenFingerprintUnchanged() {
        RegisterStore.markRegistered(fingerprint: fp)
        #expect(RegisterStore.shouldRegister(currentFingerprint: fp) == false)
    }

    @Test("shouldRegister is true when fingerprint changes after register")
    func retriggerOnFingerprintChange() {
        RegisterStore.markRegistered(fingerprint: fp)
        let newFp = "deviceId|com.test|NEW_TOKEN|3.3.1|17.0|42"
        #expect(RegisterStore.shouldRegister(currentFingerprint: newFp) == true)
    }

    @Test("fingerprint changes when businessToken changes")
    func fingerprintBusinessToken() {
        let a = RegisterStore.fingerprint(
            deviceId: "d", appId: "app", businessToken: "token-A",
            sdkVersion: "3.0", osVersion: "17.0", appBuild: "1"
        )
        let b = RegisterStore.fingerprint(
            deviceId: "d", appId: "app", businessToken: "token-B",
            sdkVersion: "3.0", osVersion: "17.0", appBuild: "1"
        )
        #expect(a != b)
    }

    @Test("fingerprint changes when sdkVersion changes")
    func fingerprintSdkVersion() {
        let a = RegisterStore.fingerprint(
            deviceId: "d", appId: "app", businessToken: "tok",
            sdkVersion: "3.3.0", osVersion: "17.0", appBuild: "1"
        )
        let b = RegisterStore.fingerprint(
            deviceId: "d", appId: "app", businessToken: "tok",
            sdkVersion: "3.3.1", osVersion: "17.0", appBuild: "1"
        )
        #expect(a != b)
    }

    @Test("fingerprint changes when osVersion changes")
    func fingerprintOsVersion() {
        let a = RegisterStore.fingerprint(
            deviceId: "d", appId: "app", businessToken: "tok",
            sdkVersion: "3.0", osVersion: "17.0", appBuild: "1"
        )
        let b = RegisterStore.fingerprint(
            deviceId: "d", appId: "app", businessToken: "tok",
            sdkVersion: "3.0", osVersion: "18.0", appBuild: "1"
        )
        #expect(a != b)
    }

    @Test("fingerprint changes when appBuild changes")
    func fingerprintAppBuild() {
        let a = RegisterStore.fingerprint(
            deviceId: "d", appId: "app", businessToken: "tok",
            sdkVersion: "3.0", osVersion: "17.0", appBuild: "10"
        )
        let b = RegisterStore.fingerprint(
            deviceId: "d", appId: "app", businessToken: "tok",
            sdkVersion: "3.0", osVersion: "17.0", appBuild: "11"
        )
        #expect(a != b)
    }

    @Test("fingerprint is stable when no inputs change")
    func fingerprintStable() {
        let a = RegisterStore.fingerprint(
            deviceId: "abc", appId: "com.test", businessToken: "tok",
            sdkVersion: "3.3.1", osVersion: "17.0", appBuild: "42"
        )
        let b = RegisterStore.fingerprint(
            deviceId: "abc", appId: "com.test", businessToken: "tok",
            sdkVersion: "3.3.1", osVersion: "17.0", appBuild: "42"
        )
        #expect(a == b)
    }

    // MARK: - TTL

    @Test("shouldRegister is false within 24 h of a register")
    func withinTTL() {
        RegisterStore.markRegistered(fingerprint: fp)
        // lastSentAt is just now; TTL not elapsed
        #expect(RegisterStore.shouldRegister(currentFingerprint: fp) == false)
    }

    @Test("markRegistered persists lastSentAt")
    func persistsLastSentAt() {
        #expect(RegisterStore.lastSentAt == nil)
        RegisterStore.markRegistered(fingerprint: fp)
        #expect(RegisterStore.lastSentAt != nil)
    }

    @Test("markRegistered persists lastFingerprint")
    func persistsLastFingerprint() {
        #expect(RegisterStore.lastFingerprint == nil)
        RegisterStore.markRegistered(fingerprint: fp)
        #expect(RegisterStore.lastFingerprint == fp)
    }

    @Test("_clearForTesting wipes all persisted state")
    func clearForTesting() {
        RegisterStore.markRegistered(fingerprint: fp)
        RegisterStore._clearForTesting()
        #expect(RegisterStore.lastSentAt == nil)
        #expect(RegisterStore.lastFingerprint == nil)
        #expect(RegisterStore.shouldRegister(currentFingerprint: fp) == true)
    }
}
