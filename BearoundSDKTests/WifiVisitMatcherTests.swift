//
//  WifiVisitMatcherTests.swift
//  BearoundSDKTests
//
//  The pure Wi-Fi visit matcher: rounds in, arrive/depart actions out.
//

import Foundation
import Testing

@testable import BearoundSDK

@Suite("WifiVisitMatcher")
struct WifiVisitMatcherTests {

    private let base = Date(timeIntervalSince1970: 1_790_000_000)
    private let known = "9f3a1c02b7d4e688"
    private let other = "ffffffffffffffff"

    private var places: [PlacesConfig.Place] {
        [PlacesConfig.Place(
            environmentId: "env-wifi", businessId: "biz", name: "env-wifi", gpsVisitClass: "mall_gallery",
            geometry: PlacesConfig.Geometry(type: "point", lat: -23.5625, lng: -46.6575, center: nil,
                                            radiusMeters: 80, rings: nil),
            distanceMeters: 200, minDwellMinutes: 5, knownApIds: [known, "0a1b2c3d4e5f6071"])]
    }

    private func minute(_ m: Double) -> Date { base.addingTimeInterval(m * 60) }

    private func round(_ m: Double, seeing apId: String?, conclusive: Bool = true) -> WifiVisitMatcher.Round {
        let observations = apId.map { [WifiVisitMatcher.Observation(apId: $0, observedAt: minute(m))] } ?? []
        return WifiVisitMatcher.Round(at: minute(m), observations: observations, conclusive: conclusive)
    }

    @Test("Arrival fires once the known AP spans the dwell with no contradiction, stamped with the first sighting")
    func arrivalAfterDwell() {
        let matcher = WifiVisitMatcher()
        #expect(matcher.onRound(round(0, seeing: known), places: places).isEmpty)
        #expect(matcher.onRound(round(3, seeing: known), places: places).isEmpty)
        let actions = matcher.onRound(round(5, seeing: known), places: places)
        guard case .arrive(let id, let at, let observations)? = actions.first, actions.count == 1 else {
            Issue.record("expected one arrive, got \(actions)")
            return
        }
        #expect(id == "env-wifi")
        #expect(at == minute(0))
        #expect(observations.map(\.apId) == [known])
        // Already open: more sightings emit nothing.
        #expect(matcher.onRound(round(8, seeing: known), places: places).isEmpty)
    }

    @Test("A conclusive round without the AP resets the candidate")
    func contradictionResets() {
        let matcher = WifiVisitMatcher()
        _ = matcher.onRound(round(0, seeing: known), places: places)
        #expect(matcher.onRound(round(3, seeing: other), places: places).isEmpty)
        // The window restarts at the next sighting: 4 min after it is still short.
        _ = matcher.onRound(round(4, seeing: known), places: places)
        #expect(matcher.onRound(round(8, seeing: known), places: places).isEmpty)
        let actions = matcher.onRound(round(9, seeing: known), places: places)
        #expect(actions == [.arrive(environmentId: "env-wifi", at: minute(4),
                                    observations: [.init(apId: known, observedAt: minute(9))])])
    }

    @Test("Departure needs a conclusive miss at least the dwell after the last sighting, stamped with it")
    func departureOnlyAfterWindow() {
        let matcher = WifiVisitMatcher()
        _ = matcher.onRound(round(0, seeing: known), places: places)
        _ = matcher.onRound(round(6, seeing: known), places: places)
        // Miss 4 min after the last sighting: too early to close.
        #expect(matcher.onRound(round(10, seeing: nil), places: places).isEmpty)
        // Seen again: the window measures from the new last sighting.
        _ = matcher.onRound(round(11, seeing: known), places: places)
        #expect(matcher.onRound(round(15, seeing: other), places: places).isEmpty)
        let actions = matcher.onRound(round(16, seeing: nil), places: places)
        guard case .depart(let id, let at, _)? = actions.first, actions.count == 1 else {
            Issue.record("expected one depart, got \(actions)")
            return
        }
        #expect(id == "env-wifi")
        #expect(at == minute(11))
        // Closed: a later miss emits nothing.
        #expect(matcher.onRound(round(30, seeing: nil), places: places).isEmpty)
    }

    @Test("An inconclusive round changes nothing: no count, no contradiction, no close")
    func inconclusiveRoundIsNeutral() {
        let matcher = WifiVisitMatcher()
        _ = matcher.onRound(round(0, seeing: known), places: places)
        // Would contradict if conclusive; must not reset the candidate.
        #expect(matcher.onRound(round(3, seeing: nil, conclusive: false), places: places).isEmpty)
        // Would count as a sighting if conclusive; must not advance it.
        #expect(matcher.onRound(round(6, seeing: known, conclusive: false), places: places).isEmpty)
        let arrive = matcher.onRound(round(7, seeing: known), places: places)
        #expect(arrive == [.arrive(environmentId: "env-wifi", at: minute(0),
                                   observations: [.init(apId: known, observedAt: minute(7))])])
        // Would close if conclusive; must not.
        #expect(matcher.onRound(round(30, seeing: nil, conclusive: false), places: places).isEmpty)
        let depart = matcher.onRound(round(31, seeing: nil), places: places)
        #expect(depart.count == 1)
    }

    @Test("A place without known APs is never tracked")
    func placeWithoutKnownApIds() {
        let matcher = WifiVisitMatcher()
        let bare = PlacesConfig.Place(
            environmentId: "env-bare", businessId: nil, name: nil, gpsVisitClass: nil,
            geometry: PlacesConfig.Geometry(type: "point", lat: 0, lng: 0, center: nil,
                                            radiusMeters: 80, rings: nil),
            distanceMeters: 10, minDwellMinutes: 0)
        #expect(matcher.onRound(round(0, seeing: known), places: [bare]).isEmpty)
        #expect(matcher.onRound(round(10, seeing: known), places: [bare]).isEmpty)
    }
}
