//
//  VisitMonitorTests.swift
//  BearoundSDKTests
//
//  VisitMonitor against fakes: no CLLocationManager, no network, isolated UserDefaults.
//

import CoreLocation
import Foundation
import Testing
import UIKit

@testable import BearoundSDK

// MARK: - Fakes

private final class FakeLocationManager: VisitLocationManaging {
    weak var delegate: VisitLocationManagerDelegate?
    var authorizationStatus: CLAuthorizationStatus = .authorizedAlways
    var hasFullAccuracy = true
    var lastKnownFix: VisitFix?
    var monitoredRegions: [RegionBudget.MonitoredRegion] = []

    var startVisitsCalls = 0
    var stopVisitsCalls = 0
    var started: [String] = []
    var stopped: [String] = []
    var locationRequests = 0

    func startMonitoringVisits() { startVisitsCalls += 1 }
    func stopMonitoringVisits() { stopVisitsCalls += 1 }

    func startMonitoring(_ region: RegionBudget.PlannedRegion) {
        started.append(region.identifier)
        monitoredRegions.removeAll { $0.identifier == region.identifier }
        monitoredRegions.append(RegionBudget.MonitoredRegion(
            identifier: region.identifier, center: region.center, radiusMeters: region.radiusMeters))
    }

    func stopMonitoring(identifier: String) {
        stopped.append(identifier)
        monitoredRegions.removeAll { $0.identifier == identifier }
    }

    func requestLocation() { locationRequests += 1 }
}

private final class FakeFetcher: PlacesConfigFetching {
    var result: PlacesConfigFetchResult
    var calls: [(lat: Double, lng: Double, etag: String?)] = []

    init(result: PlacesConfigFetchResult) { self.result = result }

    func fetch(latitude: Double, longitude: Double, etag: String?,
               completion: @escaping (PlacesConfigFetchResult) -> Void) {
        calls.append((latitude, longitude, etag))
        completion(result)
    }
}

private final class FakeSender: VisitEventSending {
    var events: [VisitEvent] = []
    func send(_ event: VisitEvent) { events.append(event) }
}

private final class FakeClock: VisitClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private final class FakeBackgroundTasks: VisitBackgroundTasking {
    var begun = 0
    var ended: [UIBackgroundTaskIdentifier] = []
    var expirations: [() -> Void] = []

    func begin(name: String, expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        begun += 1
        expirations.append(expiration)
        return UIBackgroundTaskIdentifier(rawValue: begun)
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) { ended.append(identifier) }

    var outstanding: Int { begun - ended.count }
}

private final class FakeWifi: WifiRoundProviding {
    var next = WifiRound(status: .notConnected, observation: nil)
    var fetches = 0

    func fetchRound(completion: @escaping (WifiRound) -> Void) {
        fetches += 1
        completion(next)
    }
}

private final class PolicyBox {
    var value: DataCollectionPolicy = .allEnabled
}

// MARK: - Fixtures

private let origin = PlacesConfig.Coordinate(lat: -23.561, lng: -46.656)
private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func place(_ id: String, lat: Double, lng: Double, distance: Double,
                   minDwell: Int? = 5, apIds: [String] = []) -> PlacesConfig.Place {
    PlacesConfig.Place(
        environmentId: id, businessId: "biz", name: id, gpsVisitClass: "street_isolated",
        geometry: PlacesConfig.Geometry(type: "point", lat: lat, lng: lng, center: nil,
                                        radiusMeters: 80, rings: nil),
        distanceMeters: distance, minDwellMinutes: minDwell, knownApIds: apIds)
}

private func config(enabled: Bool, places: [PlacesConfig.Place]? = nil) -> PlacesConfig {
    PlacesConfig(
        origin: origin, refreshAfterMeters: 2500, maxAgeSeconds: 21600,
        visitDetectionEnabled: enabled,
        places: places ?? [place("env-1", lat: -23.562, lng: -46.657, distance: 150)])
}

private struct Harness {
    let manager = FakeLocationManager()
    let fetcher: FakeFetcher
    let sender = FakeSender()
    let clock = FakeClock(t0)
    let policy = PolicyBox()
    let defaults: UserDefaults
    let store: VisitStateStore
    let monitor: VisitMonitor
    let wifi = FakeWifi()

    init(fetchResult: PlacesConfigFetchResult, cached: PlacesConfig? = nil) {
        let suite = "VisitMonitorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        store = VisitStateStore(defaults: defaults)
        if let cached { store.saveConfig(cached, etag: "\"v1\"", fetchedAt: t0) }
        fetcher = FakeFetcher(result: fetchResult)
        let policy = self.policy
        monitor = VisitMonitor(
            locationManager: manager, fetcher: fetcher, sender: sender, store: store,
            clock: clock, policy: { policy.value }, wifi: wifi)
    }

    /// One Wi-Fi wakeup at `date`: the collector answers `apId` (nil: not connected).
    func wifiRound(_ apId: String?, at date: Date) {
        clock.now = date
        wifi.next = apId.map {
            WifiRound(status: .ready, observation: WifiObservation(
                apId: $0, ssid: "guest", rssi: nil, connected: true, frequencyMhz: nil, timestamp: ms(date)))
        } ?? WifiRound(status: .notConnected, observation: nil)
        monitor.visitLocationManagerDidChangeAuthorization()
    }

    /// Geofence entry for an environment, answered by a fix at `fixTime`.
    func fenceArrival(_ environmentId: String, lat: Double, lng: Double, at fixTime: Date) {
        monitor.visitLocationManager(didEnterRegion: RegionBudget.environmentIdentifier(environmentId))
        monitor.visitLocationManager(didUpdateFix: fix(lat, lng, at: fixTime))
    }

    func fix(_ lat: Double, _ lng: Double, at date: Date) -> VisitFix {
        VisitFix(latitude: lat, longitude: lng, accuracy: 12, timestamp: date)
    }
}

private func ms(_ date: Date) -> Int { Int(date.timeIntervalSince1970 * 1000) }

// MARK: - Tests

@Suite("VisitMonitor Tests")
struct VisitMonitorTests {

    @Test("visit_detection_enabled=false never starts visits and removes only visit regions")
    func killSwitchRemovesOnlyVisitRegions() {
        let h = Harness(fetchResult: .updated(config(enabled: false), etag: "\"v2\""))
        h.manager.monitoredRegions = [
            RegionBudget.MonitoredRegion(identifier: "host.store.geofence"),
            RegionBudget.MonitoredRegion(identifier: BeaconConstants.regionIdentifier),
            RegionBudget.MonitoredRegion(identifier: "bearound.visit.env.env-old"),
            RegionBudget.MonitoredRegion(identifier: RegionBudget.refreshFenceIdentifier),
        ]
        h.manager.lastKnownFix = h.fix(-23.561, -46.656, at: t0)

        h.monitor.start()

        #expect(h.fetcher.calls.count == 1)
        #expect(h.manager.startVisitsCalls == 0)
        #expect(h.manager.started.isEmpty)
        #expect(Set(h.manager.stopped) == ["bearound.visit.env.env-old", RegionBudget.refreshFenceIdentifier])
        #expect(h.manager.monitoredRegions.map(\.identifier)
                == ["host.store.geofence", BeaconConstants.regionIdentifier])

        // A visit delivered while the switch is off produces nothing.
        h.monitor.visitLocationManager(didVisit: VisitObservation(
            latitude: -23.562, longitude: -46.657, accuracy: 20,
            arrivalDate: t0, departureDate: t0.addingTimeInterval(600)))
        #expect(h.sender.events.isEmpty)
    }

    @Test("CLVisit arrival then departure sends exactly two visit events with the real fix times")
    func arrivalAndDepartureFromCLVisit() {
        let h = Harness(fetchResult: .notModified, cached: config(enabled: true))
        h.monitor.start()
        #expect(h.manager.startVisitsCalls == 1)
        #expect(h.manager.started.contains("bearound.visit.env.env-1"))

        let arrival = t0.addingTimeInterval(-900)
        let departure = t0.addingTimeInterval(1200)
        h.clock.now = t0.addingTimeInterval(60)
        h.monitor.visitLocationManager(didVisit: VisitObservation(
            latitude: -23.562, longitude: -46.657, accuracy: 25, arrivalDate: arrival, departureDate: nil))
        // iOS redelivers the arrival: still one arrival.
        h.monitor.visitLocationManager(didVisit: VisitObservation(
            latitude: -23.562, longitude: -46.657, accuracy: 25, arrivalDate: arrival, departureDate: nil))

        h.clock.now = t0.addingTimeInterval(3600)
        let closed = VisitObservation(
            latitude: -23.562, longitude: -46.657, accuracy: 25, arrivalDate: arrival, departureDate: departure)
        h.monitor.visitLocationManager(didVisit: closed)
        // Redelivered after a relaunch: no second departure, no second arrival.
        h.monitor.visitLocationManager(didVisit: closed)

        #expect(h.sender.events.map(\.kind) == [.arrival, .departure])
        #expect(h.sender.events.allSatisfy { $0.syncTrigger == "visit" })
        #expect(h.sender.events.map { ms($0.timestamp) } == [ms(arrival), ms(departure)])
        #expect(h.sender.events.map { $0.deviceLocation?.timestamp } == [ms(arrival), ms(departure)])
        #expect(h.sender.events.allSatisfy { $0.deviceLocation?.source == "gnss" })
    }

    @Test("Geofence entry sends the arrival at the fresh fix time; CLVisit then adds only the departure")
    func arrivalFromGeofenceThenCLVisitDeparture() {
        let h = Harness(fetchResult: .notModified, cached: config(enabled: true))
        h.monitor.start()

        h.monitor.visitLocationManager(didEnterRegion: "bearound.visit.env.env-1")
        #expect(h.manager.locationRequests == 1)
        let fixTime = t0.addingTimeInterval(30)
        h.clock.now = t0.addingTimeInterval(45)
        h.monitor.visitLocationManager(didUpdateFix: h.fix(-23.5621, -46.6571, at: fixTime))

        let departure = t0.addingTimeInterval(1500)
        h.clock.now = t0.addingTimeInterval(1600)
        h.monitor.visitLocationManager(didVisit: VisitObservation(
            latitude: -23.562, longitude: -46.657, accuracy: 30,
            arrivalDate: t0.addingTimeInterval(-60), departureDate: departure))

        #expect(h.sender.events.map(\.kind) == [.arrival, .departure])
        #expect(h.sender.events.map { ms($0.timestamp) } == [ms(fixTime), ms(departure)])
        #expect(h.sender.events.first?.environmentId == "env-1")
        #expect(h.sender.events.allSatisfy { $0.syncTrigger == "visit" })
    }

    @Test("Refresh fence exit or an expired maxAge triggers a fetch; staying inside within maxAge does not")
    func refreshFenceAndMaxAge() {
        let h = Harness(fetchResult: .updated(config(enabled: true), etag: "\"v2\""), cached: config(enabled: true))
        h.monitor.start()
        #expect(h.fetcher.calls.isEmpty)
        #expect(h.manager.started.first == RegionBudget.refreshFenceIdentifier)

        // ~1 km from origin, well inside 2500 m, one hour later: no fetch.
        h.clock.now = t0.addingTimeInterval(3600)
        h.monitor.visitLocationManager(didUpdateFix: h.fix(-23.570, -46.656, at: h.clock.now))
        #expect(h.fetcher.calls.isEmpty)

        // Leaving the fence asks for a fix, and the fix triggers the fetch at that position.
        h.monitor.visitLocationManager(didExitRegion: RegionBudget.refreshFenceIdentifier)
        #expect(h.manager.locationRequests == 1)
        h.monitor.visitLocationManager(didUpdateFix: h.fix(-23.600, -46.656, at: h.clock.now))
        #expect(h.fetcher.calls.count == 1)
        #expect(h.fetcher.calls.first?.lat == -23.600)
        #expect(h.fetcher.calls.first?.etag == "\"v1\"")

        // Inside the new fence but past maxAge: fetch again.
        h.clock.now = h.clock.now.addingTimeInterval(21600 + 1)
        h.monitor.visitLocationManager(didUpdateFix: h.fix(-23.561, -46.656, at: h.clock.now))
        #expect(h.fetcher.calls.count == 2)
    }

    @Test("A failed config fetch keeps the last list, the regions and the kill-switch value")
    func failedFetchKeepsLastList() {
        let cached = config(enabled: true, places: [
            place("env-1", lat: -23.562, lng: -46.657, distance: 150),
            place("env-2", lat: -23.565, lng: -46.650, distance: 700),
        ])
        let h = Harness(fetchResult: .failed(URLError(.notConnectedToInternet)), cached: cached)
        h.monitor.start()
        let registered = Set(h.manager.monitoredRegions.map(\.identifier))
        #expect(registered == [RegionBudget.refreshFenceIdentifier, "bearound.visit.env.env-1", "bearound.visit.env.env-2"])

        h.clock.now = t0.addingTimeInterval(21600 + 60)
        h.monitor.visitLocationManager(didUpdateFix: h.fix(-23.561, -46.656, at: h.clock.now))

        #expect(h.fetcher.calls.count == 1)
        #expect(h.store.loadConfig()?.config == cached)
        #expect(h.manager.stopped.isEmpty)
        #expect(h.manager.stopVisitsCalls == 0)
        #expect(Set(h.manager.monitoredRegions.map(\.identifier)) == registered)

        // Failure backoff: the next fix does not hammer the API.
        h.monitor.visitLocationManager(didUpdateFix: h.fix(-23.561, -46.656, at: h.clock.now))
        #expect(h.fetcher.calls.count == 1)

        // Detection still runs on the last list.
        h.monitor.visitLocationManager(didVisit: VisitObservation(
            latitude: -23.562, longitude: -46.657, accuracy: 20,
            arrivalDate: h.clock.now.addingTimeInterval(-600), departureDate: nil))
        #expect(h.sender.events.map(\.kind) == [.arrival])
    }
}

// MARK: - Review fixes (PR #82)

/// ~2 km south of env-1: a different place.
private let farLat = -23.580
/// ~300 m from env-1: the same stop.
private let nearLat = -23.5647

@Suite("VisitMonitor teardown and eligibility")
struct VisitMonitorTeardownTests {

    @Test("Teardown without a monitor stops CLVisit and every bearound.visit. region, nothing else")
    func teardownWithoutMonitor() {
        let manager = FakeLocationManager()
        manager.monitoredRegions = [
            RegionBudget.MonitoredRegion(identifier: "host.store.geofence"),
            RegionBudget.MonitoredRegion(identifier: BeaconConstants.regionIdentifier),
            RegionBudget.MonitoredRegion(identifier: "bearound.visit.env.env-1"),
            RegionBudget.MonitoredRegion(identifier: "bearound.visit.env-legacy"),
            RegionBudget.MonitoredRegion(identifier: RegionBudget.refreshFenceIdentifier),
        ]

        VisitMonitor.tearDownVisitMonitoring(on: manager)

        #expect(manager.stopVisitsCalls == 1)
        #expect(Set(manager.stopped) == [
            "bearound.visit.env.env-1", "bearound.visit.env-legacy", RegionBudget.refreshFenceIdentifier,
        ])
        #expect(manager.monitoredRegions.map(\.identifier)
                == ["host.store.geofence", BeaconConstants.regionIdentifier])
    }

    @Test("Eligibility needs the location policy, Always and Precise Location")
    func eligibilityRule() {
        #expect(VisitMonitor.isEligible(policyAllowsLocation: true, authorization: .authorizedAlways,
                                        hasFullAccuracy: true))
        #expect(!VisitMonitor.isEligible(policyAllowsLocation: true, authorization: .authorizedAlways,
                                         hasFullAccuracy: false))
        #expect(!VisitMonitor.isEligible(policyAllowsLocation: true, authorization: .authorizedWhenInUse,
                                         hasFullAccuracy: true))
        #expect(!VisitMonitor.isEligible(policyAllowsLocation: false, authorization: .authorizedAlways,
                                         hasFullAccuracy: true))
    }

    @Test("Precise Location turned off tears visit detection down")
    func reducedAccuracyTearsDown() {
        let h = Harness(fetchResult: .notModified, cached: config(enabled: true))
        h.monitor.start()
        #expect(h.manager.monitoredRegions.contains { $0.identifier == "bearound.visit.env.env-1" })

        h.manager.hasFullAccuracy = false
        h.monitor.visitLocationManagerDidChangeAuthorization()

        #expect(h.manager.stopVisitsCalls == 1)
        #expect(!h.manager.monitoredRegions.contains { RegionBudget.isSDKVisitIdentifier($0.identifier) })
        // Nothing is reported while ineligible.
        h.monitor.visitLocationManager(didVisit: VisitObservation(
            latitude: -23.562, longitude: -46.657, accuracy: 20, arrivalDate: t0, departureDate: nil))
        #expect(h.sender.events.isEmpty)
    }

    @Test("Re-applying after collectLocation turned off tears down; turning it back on re-arms")
    func collectLocationOffReapplies() {
        let h = Harness(fetchResult: .notModified, cached: config(enabled: true))
        h.monitor.start()
        #expect(h.manager.startVisitsCalls == 1)

        h.policy.value = DataCollectionPolicy(advertisingId: true, location: false, wifi: true)
        h.monitor.start()
        #expect(h.manager.stopVisitsCalls == 1)
        #expect(!h.manager.monitoredRegions.contains { RegionBudget.isSDKVisitIdentifier($0.identifier) })
        #expect(h.fetcher.calls.isEmpty)

        h.policy.value = .allEnabled
        h.monitor.start()
        #expect(h.manager.startVisitsCalls == 2)
        #expect(h.manager.monitoredRegions.contains { $0.identifier == "bearound.visit.env.env-1" })
    }

    @Test("A refresh fence exit while ineligible asks for no fix")
    func fenceExitNeedsEligibility() {
        let h = Harness(fetchResult: .notModified, cached: config(enabled: true))
        h.monitor.start()

        h.manager.authorizationStatus = .authorizedWhenInUse
        h.monitor.visitLocationManager(didExitRegion: RegionBudget.refreshFenceIdentifier)
        #expect(h.manager.locationRequests == 0)

        h.manager.authorizationStatus = .authorizedAlways
        h.policy.value = DataCollectionPolicy(advertisingId: true, location: false, wifi: true)
        h.monitor.visitLocationManager(didExitRegion: RegionBudget.refreshFenceIdentifier)
        #expect(h.manager.locationRequests == 0)
    }

    @Test("An environment id equal to 'refresh' is an environment, never the refresh fence")
    func environmentNamedRefresh() {
        let h = Harness(fetchResult: .notModified, cached: config(enabled: true, places: [
            place("refresh", lat: -23.562, lng: -46.657, distance: 150),
        ]))
        h.monitor.start()
        #expect(Set(h.manager.monitoredRegions.map(\.identifier))
                == [RegionBudget.refreshFenceIdentifier, "bearound.visit.env.refresh"])

        h.fenceArrival("refresh", lat: -23.562, lng: -46.657, at: t0)
        #expect(h.sender.events.map(\.kind) == [.arrival])
        #expect(h.sender.events.first?.environmentId == "refresh")
        #expect(h.fetcher.calls.isEmpty)
    }
}

@Suite("VisitMonitor drive-by stops")
struct VisitMonitorDriveByTests {

    private func twoPlaces(secondLat: Double, minDwell: Int? = 5) -> PlacesConfig {
        config(enabled: true, places: [
            place("env-1", lat: -23.562, lng: -46.657, distance: 150, minDwell: minDwell),
            place("env-2", lat: secondLat, lng: -46.657, distance: 900, minDwell: minDwell),
        ])
    }

    @Test("A fence arrival at another environment is not blocked by an open stop elsewhere")
    func fenceAtOtherPlaceIsNotBlocked() {
        let h = Harness(fetchResult: .notModified, cached: twoPlaces(secondLat: farLat))
        h.monitor.start()

        h.fenceArrival("env-1", lat: -23.562, lng: -46.657, at: t0)
        h.clock.now = t0.addingTimeInterval(120)
        h.fenceArrival("env-2", lat: farLat, lng: -46.657, at: h.clock.now)

        #expect(h.sender.events.map(\.kind) == [.arrival, .arrival])
        #expect(h.sender.events.map(\.environmentId) == ["env-1", "env-2"])
        #expect(h.store.openStop?.environmentId == "env-2")
    }

    @Test("A fence arrival is suppressed by an open stop of the same environment or within 500 m of its center")
    func fenceArrivalSuppressedForSameStop() {
        let h = Harness(fetchResult: .notModified, cached: twoPlaces(secondLat: nearLat))
        h.monitor.start()

        h.fenceArrival("env-1", lat: -23.562, lng: -46.657, at: t0)
        h.clock.now = t0.addingTimeInterval(60)
        // Same environment again: no fix requested, nothing sent.
        h.monitor.visitLocationManager(didEnterRegion: RegionBudget.environmentIdentifier("env-1"))
        #expect(h.manager.locationRequests == 1)
        // A neighbour whose center is ~300 m away: the same stop.
        h.fenceArrival("env-2", lat: nearLat, lng: -46.657, at: h.clock.now)

        #expect(h.sender.events.map(\.kind) == [.arrival])
        #expect(h.store.openStop?.environmentId == "env-1")
    }

    @Test("A stop opened by a fence expires after minDwellMinutes (default 5) + 30 min with no event")
    func fenceStopExpiresWithoutDeparture() {
        let h = Harness(fetchResult: .notModified, cached: twoPlaces(secondLat: farLat, minDwell: nil))
        h.monitor.start()

        h.fenceArrival("env-1", lat: -23.562, lng: -46.657, at: t0)
        #expect(h.store.openStop?.fenceExpiresAt == t0.addingTimeInterval(35 * 60))

        // Still inside the window: a new entry is the same stop.
        h.clock.now = t0.addingTimeInterval(34 * 60)
        h.monitor.visitLocationManager(didEnterRegion: RegionBudget.environmentIdentifier("env-1"))
        #expect(h.manager.locationRequests == 1)

        // Past the window: the stop is dropped, no departure is invented, a new entry opens a new stop.
        h.clock.now = t0.addingTimeInterval(36 * 60)
        h.fenceArrival("env-1", lat: -23.562, lng: -46.657, at: h.clock.now)
        #expect(h.sender.events.map(\.kind) == [.arrival, .arrival])
        #expect(h.store.openStop?.arrivalAt == h.clock.now)
    }

    @Test("minDwellMinutes from the config sets the fence stop expiry")
    func fenceStopExpiryUsesMinDwell() {
        let h = Harness(fetchResult: .notModified, cached: twoPlaces(secondLat: farLat, minDwell: 20))
        h.monitor.start()
        h.fenceArrival("env-1", lat: -23.562, lng: -46.657, at: t0)
        #expect(h.store.openStop?.fenceExpiresAt == t0.addingTimeInterval(50 * 60))
    }

    @Test("A CLVisit arrival confirming a fence stop keeps it open until the CLVisit departure")
    func clVisitArrivalConfirmsFenceStop() {
        let h = Harness(fetchResult: .notModified, cached: twoPlaces(secondLat: farLat))
        h.monitor.start()

        h.fenceArrival("env-1", lat: -23.562, lng: -46.657, at: t0)
        h.clock.now = t0.addingTimeInterval(10 * 60)
        h.monitor.visitLocationManager(didVisit: VisitObservation(
            latitude: -23.562, longitude: -46.657, accuracy: 30,
            arrivalDate: t0.addingTimeInterval(-60), departureDate: nil))
        #expect(h.store.openStop?.fenceExpiresAt == nil)

        let departure = t0.addingTimeInterval(2 * 3600)
        h.clock.now = departure.addingTimeInterval(60)
        h.monitor.visitLocationManager(didVisit: VisitObservation(
            latitude: -23.562, longitude: -46.657, accuracy: 30,
            arrivalDate: t0.addingTimeInterval(-60), departureDate: departure))

        #expect(h.sender.events.map(\.kind) == [.arrival, .departure])
        #expect(h.sender.events.last?.environmentId == "env-1")
    }

    @Test("A CLVisit at another place replaces the open stop without any event for the old one")
    func clVisitElsewhereOrphansOldArrival() {
        let h = Harness(fetchResult: .notModified, cached: twoPlaces(secondLat: farLat))
        h.monitor.start()

        h.monitor.visitLocationManager(didVisit: VisitObservation(
            latitude: -23.562, longitude: -46.657, accuracy: 20, arrivalDate: t0, departureDate: nil))
        let secondArrival = t0.addingTimeInterval(3600)
        h.clock.now = secondArrival
        h.monitor.visitLocationManager(didVisit: VisitObservation(
            latitude: farLat, longitude: -46.657, accuracy: 20, arrivalDate: secondArrival, departureDate: nil))

        #expect(h.sender.events.map(\.kind) == [.arrival, .arrival])
        #expect(h.store.openStop?.latitude == farLat)

        let departure = secondArrival.addingTimeInterval(1800)
        h.clock.now = departure
        h.monitor.visitLocationManager(didVisit: VisitObservation(
            latitude: farLat, longitude: -46.657, accuracy: 20, arrivalDate: secondArrival, departureDate: departure))
        #expect(h.sender.events.map(\.kind) == [.arrival, .arrival, .departure])
        #expect(h.sender.events.last?.latitude == farLat)
    }
}

@Suite("Visit background assertions")
struct VisitBackgroundAssertionTests {

    @Test("requestLocation holds one assertion, released by the fix, the failure or the expiration")
    func requestLocationAssertionIsBalanced() {
        let tasks = FakeBackgroundTasks()
        let adapter = CoreLocationVisitManager(backgroundTasks: tasks)
        let clManager = CLLocationManager()

        adapter.requestLocation()
        #expect(tasks.begun == 1)
        adapter.locationManager(clManager, didFailWithError: CLError(.locationUnknown))
        #expect(tasks.outstanding == 0)

        adapter.requestLocation()
        adapter.requestLocation()
        #expect(tasks.begun == 2)
        adapter.locationManager(clManager, didUpdateLocations: [CLLocation(latitude: -23.56, longitude: -46.65)])
        #expect(tasks.outstanding == 0)

        // Even an answer the delegate ignores (invalid coordinate) releases it.
        adapter.requestLocation()
        adapter.locationManager(clManager, didUpdateLocations: [])
        #expect(tasks.outstanding == 0)

        adapter.requestLocation()
        #expect(tasks.begun == 4)
        tasks.expirations.last?()
        #expect(tasks.outstanding == 0)
        // A late answer after the expiration does not end it twice.
        adapter.locationManager(clManager, didFailWithError: CLError(.locationUnknown))
        #expect(tasks.ended.count == 4)
        #expect(!adapter.locationRequestAssertion.isHeld)
    }
}

// MARK: - Places config client

private final class CapturingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(request)
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("PlacesConfigClient")
struct PlacesConfigClientTests {

    @Test("One client reads the current configuration at each fetch and balances its assertion")
    func oneClientFollowsReconfigure() async {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [CapturingURLProtocol.self]
        // Unique per run: the captured request list is process-wide.
        let run = UUID().uuidString
        var current: SDKConfiguration? = SDKConfiguration(businessToken: "token-a-\(run)")
        let tasks = FakeBackgroundTasks()
        let client = PlacesConfigClient(configuration: { current }, session: URLSession(configuration: sessionConfig),
                                        backgroundTasks: tasks)

        let first = await withCheckedContinuation { continuation in
            client.fetch(latitude: -23.5611, longitude: -46.6561, etag: nil) { continuation.resume(returning: $0) }
        }
        current = SDKConfiguration(businessToken: "token-b-\(run)")
        let second = await withCheckedContinuation { continuation in
            client.fetch(latitude: -23.5611, longitude: -46.6561, etag: nil) { continuation.resume(returning: $0) }
        }

        if case .notModified = first {} else { Issue.record("first fetch: \(first)") }
        if case .notModified = second {} else { Issue.record("second fetch: \(second)") }
        let tokens = CapturingURLProtocol.requests
            .filter { $0.url?.path == "/sdk/places/nearby" }
            .compactMap { $0.value(forHTTPHeaderField: "Authorization") }
            .filter { $0.hasSuffix(run) }
        #expect(tokens == ["token-a-\(run)", "token-b-\(run)"])
        #expect(tasks.begun == 2)
        #expect(tasks.outstanding == 0)

        current = nil
        let unconfigured = await withCheckedContinuation { continuation in
            client.fetch(latitude: 0, longitude: 0, etag: nil) { continuation.resume(returning: $0) }
        }
        if case .failed(PlacesConfigClient.ClientError.notConfigured) = unconfigured {} else {
            Issue.record("unconfigured fetch: \(unconfigured)")
        }
        #expect(tasks.begun == 2)
    }
}

@Suite("PlacesConfig knownApIds decoding")
struct PlacesConfigKnownApIdsTests {

    private let json = """
    {"origin":{"lat":-23.561,"lng":-46.656},"refreshAfterMeters":2500,"maxAgeSeconds":21600,
     "visit_detection_enabled":true,
     "places":[
      {"environmentId":"env-1","businessId":"biz","name":"env-1","gpsVisitClass":"street_isolated",
       "geometry":{"type":"point","lat":-23.562,"lng":-46.657,"radiusMeters":80},
       "distanceMeters":150,"minDwellMinutes":5},
      {"environmentId":"env-wifi","businessId":"biz","name":"env-wifi","gpsVisitClass":"mall_gallery",
       "geometry":{"type":"point","lat":-23.5625,"lng":-46.6575,"radiusMeters":80},
       "distanceMeters":200,"minDwellMinutes":5,
       "knownApIds":["9f3a1c02b7d4e688","0a1b2c3d4e5f6071"]}
     ]}
    """

    @Test("A place without the field decodes as an empty list; one with it keeps the ids")
    func decodesWithAndWithoutField() throws {
        let config = try JSONDecoder().decode(PlacesConfig.self, from: Data(json.utf8))
        #expect(config.places.count == 2)
        #expect(config.places[0].knownApIds.isEmpty)
        #expect(config.places[1].knownApIds == ["9f3a1c02b7d4e688", "0a1b2c3d4e5f6071"])
    }

    @Test("The ids survive the persisted round trip")
    func survivesPersistence() throws {
        let config = try JSONDecoder().decode(PlacesConfig.self, from: Data(json.utf8))
        let decoded = try JSONDecoder().decode(PlacesConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
    }
}

// MARK: - Wi-Fi matching

@Suite("VisitMonitor Wi-Fi matching")
struct VisitMonitorWifiTests {

    private let known = "9f3a1c02b7d4e688"
    private let other = "ffffffffffffffff"

    private var wifiConfig: PlacesConfig {
        config(enabled: true, places: [
            place("env-wifi", lat: -23.562, lng: -46.657, distance: 150, apIds: [known])])
    }

    private func minute(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }

    @Test("Wi-Fi with an open GPS stop only adds the apId: no event, one stop")
    func wifiOnOpenGpsStopOnlyAddsApId() {
        let h = Harness(fetchResult: .notModified, cached: wifiConfig)
        h.monitor.start()
        h.fenceArrival("env-wifi", lat: -23.562, lng: -46.657, at: t0)
        #expect(h.sender.events.map(\.kind) == [.arrival])

        h.wifiRound(known, at: minute(1))
        h.wifiRound(known, at: minute(7))

        #expect(h.sender.events.map(\.kind) == [.arrival])
        #expect(h.store.openStop?.sources == [.gps, .wifi])
        #expect(h.store.openStop?.apIds == [known])
        #expect(h.store.openStop?.latitude == -23.562)
    }

    @Test("A Wi-Fi-only stop sends its events without location and with the matched AP first")
    func wifiEventsHaveNoLocationAndMatchedFirst() {
        let h = Harness(fetchResult: .notModified, cached: wifiConfig)
        h.monitor.start()

        h.wifiRound(known, at: minute(0))
        h.wifiRound(known, at: minute(6))
        #expect(h.sender.events.count == 1)
        let arrival = h.sender.events[0]
        #expect(arrival.kind == .arrival)
        #expect(arrival.syncTrigger == "visit")
        #expect(arrival.latitude == nil && arrival.longitude == nil)
        #expect(arrival.deviceLocation == nil)
        #expect(arrival.environmentId == "env-wifi")
        #expect(arrival.timestamp == minute(0))
        #expect(arrival.wifis.map(\.apId) == [known])
        #expect(arrival.wifis[0].timestamp == ms(minute(0)))
        #expect(h.store.openStop?.sources == [.wifi])
        #expect(h.store.openStop?.latitude == nil)

        // Joined to another AP 10 min after the last sighting: the known one still leads.
        h.wifiRound(other, at: minute(16))
        #expect(h.sender.events.map(\.kind) == [.arrival, .departure])
        let departure = h.sender.events[1]
        #expect(departure.latitude == nil && departure.deviceLocation == nil)
        #expect(departure.timestamp == minute(6))
        #expect(departure.wifis.map(\.apId) == [known, other])
        #expect(departure.wifis[0].timestamp == ms(minute(6)))
        #expect(h.store.openStop == nil)
        #expect(h.store.lastDepartureAt == minute(6))
    }

    @Test("A CLVisit departure closes a stop Wi-Fi also reported, carrying the fix and the apIds")
    func gpsDepartureCarriesFixAndApIds() {
        let h = Harness(fetchResult: .notModified, cached: wifiConfig)
        h.monitor.start()
        h.wifiRound(known, at: minute(0))
        h.wifiRound(known, at: minute(6))

        // GPS confirms the same place: refused as a new arrival, recorded as a source.
        h.clock.now = minute(8)
        h.monitor.visitLocationManager(didVisit: VisitObservation(
            latitude: -23.562, longitude: -46.657, accuracy: 20, arrivalDate: minute(1), departureDate: nil))
        #expect(h.sender.events.map(\.kind) == [.arrival])
        #expect(h.store.openStop?.sources == [.gps, .wifi])

        // The Wi-Fi leaves, but only GPS may close a stop it also owns.
        h.wifiRound(nil, at: minute(20))
        #expect(h.sender.events.map(\.kind) == [.arrival])

        h.clock.now = minute(25)
        h.monitor.visitLocationManager(didVisit: VisitObservation(
            latitude: -23.562, longitude: -46.657, accuracy: 20, arrivalDate: minute(1), departureDate: minute(18)))
        #expect(h.sender.events.map(\.kind) == [.arrival, .departure])
        let departure = h.sender.events[1]
        #expect(departure.latitude == -23.562)
        #expect(departure.wifis.map(\.apId) == [known])
        #expect(h.store.openStop == nil)
    }

    @Test("Turning visit detection off discards the candidate and the Wi-Fi stop with no event")
    func killSwitchDiscardsWifiState() {
        let h = Harness(fetchResult: .notModified, cached: wifiConfig)
        h.monitor.start()
        h.wifiRound(known, at: minute(0))
        h.wifiRound(known, at: minute(6))
        #expect(h.sender.events.count == 1)
        #expect(h.store.openStop?.sources == [.wifi])

        h.store.saveConfig(config(enabled: false, places: wifiConfig.places), etag: nil, fetchedAt: minute(7))
        h.wifiRound(nil, at: minute(30))

        #expect(h.sender.events.count == 1)
        #expect(h.store.openStop == nil)
    }

    @Test("collectWifi off stops the matcher: no round is read and the Wi-Fi stop is discarded")
    func hostWifiOffDiscardsState() {
        let h = Harness(fetchResult: .notModified, cached: wifiConfig)
        h.monitor.start()
        h.wifiRound(known, at: minute(0))
        h.wifiRound(known, at: minute(6))
        #expect(h.store.openStop?.sources == [.wifi])
        let fetches = h.wifi.fetches

        h.policy.value = DataCollectionPolicy(wifi: false)
        h.wifiRound(nil, at: minute(30))

        #expect(h.wifi.fetches == fetches)
        #expect(h.sender.events.count == 1)
        #expect(h.store.openStop == nil)
    }

    @Test("An open stop persisted by the previous version decodes as a GPS stop without access points")
    func legacyOpenStopDecodes() throws {
        let legacy = Data("""
        {"latitude":-23.5,"longitude":-46.6,"arrivalAt":1790000000,"environmentId":"env-1"}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let stop = try decoder.decode(VisitStateStore.OpenStop.self, from: legacy)
        #expect(stop.sources == [.gps])
        #expect(stop.apIds.isEmpty)
        #expect(stop.latitude == -23.5)
    }
}
