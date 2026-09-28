//
//  VisitMonitorTests.swift
//  BearoundSDKTests
//
//  VisitMonitor against fakes: no CLLocationManager, no network, isolated UserDefaults.
//

import CoreLocation
import Foundation
import Testing

@testable import BearoundSDK

// MARK: - Fakes

private final class FakeLocationManager: VisitLocationManaging {
    weak var delegate: VisitLocationManagerDelegate?
    var authorizationStatus: CLAuthorizationStatus = .authorizedAlways
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

// MARK: - Fixtures

private let origin = PlacesConfig.Coordinate(lat: -23.561, lng: -46.656)
private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func place(_ id: String, lat: Double, lng: Double, distance: Double) -> PlacesConfig.Place {
    PlacesConfig.Place(
        environmentId: id, businessId: "biz", name: id, gpsVisitClass: "street_isolated",
        geometry: PlacesConfig.Geometry(type: "point", lat: lat, lng: lng, center: nil,
                                        radiusMeters: 80, rings: nil),
        distanceMeters: distance, minDwellMinutes: 5)
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
    let defaults: UserDefaults
    let store: VisitStateStore
    let monitor: VisitMonitor

    init(fetchResult: PlacesConfigFetchResult, cached: PlacesConfig? = nil) {
        let suite = "VisitMonitorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        store = VisitStateStore(defaults: defaults)
        if let cached { store.saveConfig(cached, etag: "\"v1\"", fetchedAt: t0) }
        fetcher = FakeFetcher(result: fetchResult)
        monitor = VisitMonitor(
            locationManager: manager, fetcher: fetcher, sender: sender, store: store,
            clock: clock, policy: { .allEnabled })
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
            RegionBudget.MonitoredRegion(identifier: "bearound.visit.env-old"),
            RegionBudget.MonitoredRegion(identifier: RegionBudget.refreshFenceIdentifier),
        ]
        h.manager.lastKnownFix = h.fix(-23.561, -46.656, at: t0)

        h.monitor.start()

        #expect(h.fetcher.calls.count == 1)
        #expect(h.manager.startVisitsCalls == 0)
        #expect(h.manager.started.isEmpty)
        #expect(Set(h.manager.stopped) == ["bearound.visit.env-old", RegionBudget.refreshFenceIdentifier])
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
        #expect(h.manager.started.contains("bearound.visit.env-1"))

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
        #expect(h.sender.events.map { $0.deviceLocation.timestamp } == [ms(arrival), ms(departure)])
        #expect(h.sender.events.allSatisfy { $0.deviceLocation.source == "gnss" })
    }

    @Test("Geofence entry sends the arrival at the fresh fix time; CLVisit then adds only the departure")
    func arrivalFromGeofenceThenCLVisitDeparture() {
        let h = Harness(fetchResult: .notModified, cached: config(enabled: true))
        h.monitor.start()

        h.monitor.visitLocationManager(didEnterRegion: "bearound.visit.env-1")
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
        #expect(registered == [RegionBudget.refreshFenceIdentifier, "bearound.visit.env-1", "bearound.visit.env-2"])

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
