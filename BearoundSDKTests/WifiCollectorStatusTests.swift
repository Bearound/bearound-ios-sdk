//
//  WifiCollectorStatusTests.swift
//  BearoundSDKTests
//
//  Why a Wi-Fi round saw nothing: the status the SDK diagnostics expose.
//

import Foundation
import Testing

@testable import BearoundSDK

@Suite("WifiCollector status")
struct WifiCollectorStatusTests {

    private let observation = WifiObservation(
        apId: "9f3a1c02b7d4e688", ssid: nil, rssi: nil, connected: true, frequencyMhz: nil, timestamp: 1)

    @Test("Each combination of what iOS answered maps to one status")
    func statusMapping() {
        #expect(WifiCollector.status(observation: observation, locationAuthorized: true, onWifi: true) == .ready)
        #expect(WifiCollector.status(observation: nil, locationAuthorized: false, onWifi: true)
                == .locationNotAuthorized)
        #expect(WifiCollector.status(observation: nil, locationAuthorized: true, onWifi: true)
                == .missingEntitlement)
        #expect(WifiCollector.status(observation: nil, locationAuthorized: true, onWifi: false) == .notConnected)
    }

    @Test("Only ready and notConnected are conclusive for the matcher")
    func conclusiveness() {
        #expect(WifiCollectorStatus.ready.isConclusive)
        #expect(WifiCollectorStatus.notConnected.isConclusive)
        #expect(!WifiCollectorStatus.missingEntitlement.isConclusive)
        #expect(!WifiCollectorStatus.locationNotAuthorized.isConclusive)
    }

    @Test("Without the entitlement a round reports missingEntitlement and records it for diagnostics")
    func missingEntitlementRound() async {
        // The test host has no `wifi-info` entitlement, so the system answers nil exactly as it
        // does for a host app that skipped the capability.
        let collector = WifiCollector(locationAuthorized: { true }, isOnWifi: { true })
        let round: WifiRound = await withCheckedContinuation { continuation in
            collector.fetchRound { continuation.resume(returning: $0) }
        }
        #expect(round.status == .missingEntitlement)
        #expect(round.observation == nil)
        #expect(DiagnosticsStore.shared.lastWifiStatus == "missingEntitlement")
    }
}
