//
//  VisitMonitor.swift
//  BearoundSDK
//
//  GPS visit detection on iOS: CLVisit plus CLCircularRegion geofences around the nearest
//  target environments (REQ-014, REQ-016, REQ-021, REQ-023, D-09).
//

import CoreLocation
import Foundation

// MARK: - Plain values crossing the CoreLocation boundary

/// A location fix reduced to what the visit logic needs.
struct VisitFix: Equatable {
    let latitude: Double
    let longitude: Double
    let accuracy: Double?
    let timestamp: Date
}

/// A `CLVisit` reduced to plain values. CoreLocation's `distantPast`/`distantFuture`
/// sentinels for an unknown arrival/departure become nil.
struct VisitObservation: Equatable {
    let latitude: Double
    let longitude: Double
    let accuracy: Double?
    let arrivalDate: Date?
    let departureDate: Date?
}

enum VisitEventKind: String {
    case arrival
    case departure
}

/// One `/ingest` visit event. Carries the REAL time of the fix (CLVisit arrival/departure
/// or the fix timestamp), never the send time (REQ-023, D-26).
struct VisitEvent: Equatable {
    let kind: VisitEventKind
    let syncTrigger: String
    let latitude: Double
    let longitude: Double
    let accuracy: Double?
    let timestamp: Date
    /// The environment whose geofence woke the SDK, when known. Diagnostic only: the
    /// ingest resolves the environment from the coordinates (section 2.4a).
    let environmentId: String?

    var deviceLocation: DeviceLocation {
        DeviceLocation(latitude: latitude, longitude: longitude, accuracy: accuracy,
                       timestamp: timestamp, source: VisitMonitor.locationSource)
    }
}

// MARK: - Seams

protocol VisitEventSending: AnyObject {
    func send(_ event: VisitEvent)
}

protocol VisitClock {
    var now: Date { get }
}

struct SystemVisitClock: VisitClock {
    var now: Date { Date() }
}

protocol VisitLocationManagerDelegate: AnyObject {
    func visitLocationManager(didEnterRegion identifier: String)
    func visitLocationManager(didExitRegion identifier: String)
    func visitLocationManager(didVisit visit: VisitObservation)
    func visitLocationManager(didUpdateFix fix: VisitFix)
    func visitLocationManagerDidFailToLocate()
    func visitLocationManagerDidChangeAuthorization()
}

/// The slice of `CLLocationManager` the visit logic uses.
protocol VisitLocationManaging: AnyObject {
    var delegate: VisitLocationManagerDelegate? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    /// The fix CoreLocation already holds, if any. Never starts a request.
    var lastKnownFix: VisitFix? { get }
    /// Snapshot of every region monitored by the app (host, beacon and visit).
    var monitoredRegions: [RegionBudget.MonitoredRegion] { get }
    func startMonitoringVisits()
    func stopMonitoringVisits()
    func startMonitoring(_ region: RegionBudget.PlannedRegion)
    func stopMonitoring(identifier: String)
    /// One-shot fresh fix, delivered through `didUpdateFix` or `DidFailToLocate`.
    func requestLocation()
}

// MARK: - VisitMonitor

/// Decides when to watch for visits, which geofences to register and which events to send.
///
/// Main-thread only: CoreLocation delivers callbacks on the thread that created the manager
/// (main) and `PlacesConfigClient` completes on main.
final class VisitMonitor {

    static let syncTrigger = "visit"
    static let locationSource = "gnss"

    /// CoreLocation does not honour circular regions much smaller than this.
    static let minimumEnvironmentRadiusMeters: Double = 100
    /// Floor between two failed config fetches that were not forced by a fence exit.
    static let failedFetchRetryInterval: TimeInterval = 15 * 60
    /// An arrival older than this is not paired with a departure anymore: the ingest only
    /// honours capture times within the last 24 h.
    static let openStopMaxAge: TimeInterval = 24 * 60 * 60
    /// A visit this close to the open stop (plus its accuracy) is the same stop.
    static let sameStopRadiusMeters: Double = 500

    private let locationManager: VisitLocationManaging
    var fetcher: PlacesConfigFetching
    private let sender: VisitEventSending
    private let store: VisitStateStore
    private let clock: VisitClock
    private let policy: () -> DataCollectionPolicy
    private let budget: RegionBudget

    private(set) var isStarted = false
    private var pendingArrivalEnvironmentId: String?
    private var pendingRefresh = false
    private var pendingRefreshForced = false
    private var fetchInFlight = false

    init(
        locationManager: VisitLocationManaging,
        fetcher: PlacesConfigFetching,
        sender: VisitEventSending,
        store: VisitStateStore = VisitStateStore(),
        clock: VisitClock = SystemVisitClock(),
        policy: @escaping () -> DataCollectionPolicy = { DataCollectionPolicyStore.current },
        budget: RegionBudget = RegionBudget()
    ) {
        self.locationManager = locationManager
        self.fetcher = fetcher
        self.sender = sender
        self.store = store
        self.clock = clock
        self.policy = policy
        self.budget = budget
        locationManager.delegate = self
    }

    // MARK: Lifecycle

    func start() {
        isStarted = true
        applyCachedConfig()
        refreshIfNeeded(fix: locationManager.lastKnownFix, forced: false)
    }

    /// Stops visits and removes only the SDK visit regions (host and beacon regions stay).
    func stop() {
        isStarted = false
        tearDown()
    }

    // MARK: Eligibility

    /// Visit detection runs only with Always authorization and the host allowing location.
    /// The fetch itself sends coordinates, so it is gated the same way.
    private var isEligible: Bool {
        policy().location && locationManager.authorizationStatus == .authorizedAlways
    }

    private var cachedConfigEnabled: Bool {
        store.loadConfig()?.config.visitDetectionEnabled == true
    }

    // MARK: Config and regions

    private func applyCachedConfig() {
        guard isStarted else { return }
        guard isEligible else {
            tearDown()
            return
        }
        // No list yet (first run without a successful fetch): no native geofence (D-22).
        guard let cached = store.loadConfig() else { return }
        apply(cached.config)
    }

    private func apply(_ config: PlacesConfig) {
        guard config.visitDetectionEnabled else {
            // Kill switch (REQ-014, D-14): only the visit part goes down.
            tearDown()
            return
        }

        locationManager.startMonitoringVisits()

        let targets = config.places.compactMap { place -> RegionBudget.Target? in
            guard let center = place.geometry.circleCenter else { return nil }
            return RegionBudget.Target(
                environmentId: place.environmentId,
                center: RegionBudget.Coordinate(latitude: center.lat, longitude: center.lng),
                radiusMeters: max(place.geometry.radiusMeters, Self.minimumEnvironmentRadiusMeters),
                distanceMeters: place.distanceMeters
            )
        }
        let fence = config.refreshAfterMeters > 0
            ? RegionBudget.RefreshFence(
                origin: RegionBudget.Coordinate(latitude: config.origin.lat, longitude: config.origin.lng),
                radiusMeters: config.refreshAfterMeters)
            : nil

        let plan = budget.plan(monitored: locationManager.monitoredRegions, refreshFence: fence, targets: targets)
        plan.identifiersToStop.forEach { locationManager.stopMonitoring(identifier: $0) }
        plan.regionsToStart.forEach { locationManager.startMonitoring($0) }
        if !plan.droppedEnvironmentIds.isEmpty {
            NSLog("[BeAroundSDK] Visit geofences: %d environment(s) left out by the region budget",
                  plan.droppedEnvironmentIds.count)
        }
    }

    private func tearDown() {
        pendingArrivalEnvironmentId = nil
        pendingRefresh = false
        pendingRefreshForced = false
        locationManager.stopMonitoringVisits()
        locationManager.monitoredRegions
            .map(\.identifier)
            .filter(RegionBudget.isSDKVisitIdentifier)
            .forEach { locationManager.stopMonitoring(identifier: $0) }
    }

    // MARK: Refresh (REQ-021)

    private func refreshIfNeeded(fix: VisitFix?, forced: Bool) {
        guard isStarted, isEligible, !fetchInFlight else { return }
        let now = clock.now
        let cached = store.loadConfig()

        var due = forced || cached == nil
        if let cached {
            if now.timeIntervalSince(cached.fetchedAt) >= cached.config.maxAgeSeconds {
                due = true
            } else if let fix,
                      Self.distanceMeters(fix.latitude, fix.longitude,
                                          cached.config.origin.lat, cached.config.origin.lng)
                        > cached.config.refreshAfterMeters {
                due = true
            }
        }
        guard due else { return }

        if !forced, let lastFailure = store.lastFailedFetchAt,
           now.timeIntervalSince(lastFailure) < Self.failedFetchRetryInterval {
            return
        }

        guard let fix else {
            pendingRefresh = true
            pendingRefreshForced = pendingRefreshForced || forced
            locationManager.requestLocation()
            return
        }
        fetch(at: fix, etag: cached?.etag)
    }

    private func fetch(at fix: VisitFix, etag: String?) {
        fetchInFlight = true
        fetcher.fetch(latitude: fix.latitude, longitude: fix.longitude, etag: etag) { [weak self] result in
            guard let self else { return }
            self.fetchInFlight = false
            let now = self.clock.now
            switch result {
            case .updated(let config, let newEtag):
                self.store.saveConfig(config, etag: newEtag, fetchedAt: now)
                self.store.lastFailedFetchAt = nil
                self.applyCachedConfig()
            case .notModified:
                self.store.touchConfig(fetchedAt: now)
                self.store.lastFailedFetchAt = nil
                self.applyCachedConfig()
            case .failed(let error):
                // D-22: the last list and the last kill-switch value stay in force.
                self.store.lastFailedFetchAt = now
                NSLog("[BeAroundSDK] Places config fetch failed, keeping the last list: %@",
                      error.localizedDescription)
            }
        }
    }

    // MARK: Stops (REQ-023)

    private func currentOpenStop() -> VisitStateStore.OpenStop? {
        guard let open = store.openStop else { return nil }
        if clock.now.timeIntervalSince(open.arrivalAt) > Self.openStopMaxAge {
            store.openStop = nil
            return nil
        }
        return open
    }

    private func belongs(_ visit: VisitObservation, to open: VisitStateStore.OpenStop) -> Bool {
        Self.distanceMeters(visit.latitude, visit.longitude, open.latitude, open.longitude)
            <= Self.sameStopRadiusMeters + (visit.accuracy ?? 0)
    }

    private func sendArrival(latitude: Double, longitude: Double, accuracy: Double?,
                             at timestamp: Date, environmentId: String?) {
        store.openStop = VisitStateStore.OpenStop(latitude: latitude, longitude: longitude,
                                                  arrivalAt: timestamp, environmentId: environmentId)
        send(.arrival, latitude: latitude, longitude: longitude, accuracy: accuracy,
             at: timestamp, environmentId: environmentId)
    }

    private func send(_ kind: VisitEventKind, latitude: Double, longitude: Double, accuracy: Double?,
                      at timestamp: Date, environmentId: String?) {
        sender.send(VisitEvent(kind: kind, syncTrigger: Self.syncTrigger, latitude: latitude,
                               longitude: longitude, accuracy: accuracy, timestamp: timestamp,
                               environmentId: environmentId))
    }

    private var canReportVisits: Bool {
        isStarted && isEligible && cachedConfigEnabled
    }

    static func distanceMeters(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double) -> Double {
        let radius = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLng = (lng2 - lng1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * radius * atan2(sqrt(a), sqrt(1 - a))
    }
}

// MARK: - CoreLocation events

extension VisitMonitor: VisitLocationManagerDelegate {

    func visitLocationManager(didEnterRegion identifier: String) {
        guard RegionBudget.isSDKVisitIdentifier(identifier),
              identifier != RegionBudget.refreshFenceIdentifier,
              canReportVisits
        else { return }
        // Arrival already sent for this stop (CLVisit or an earlier fence).
        guard currentOpenStop() == nil else { return }
        pendingArrivalEnvironmentId = String(identifier.dropFirst(RegionBudget.visitIdentifierPrefix.count))
        locationManager.requestLocation()
    }

    func visitLocationManager(didExitRegion identifier: String) {
        guard identifier == RegionBudget.refreshFenceIdentifier, isStarted else { return }
        pendingRefresh = true
        pendingRefreshForced = true
        locationManager.requestLocation()
    }

    func visitLocationManager(didVisit visit: VisitObservation) {
        guard canReportVisits else { return }
        let lastDeparture = store.lastDepartureAt

        if let departure = visit.departureDate {
            // CLVisit redelivered after a relaunch: this stop is already closed.
            if let lastDeparture, departure <= lastDeparture { return }
            let isSameStop = currentOpenStop().map { belongs(visit, to: $0) } ?? false
            if !isSameStop {
                guard let arrival = visit.arrivalDate else { return }
                sendArrival(latitude: visit.latitude, longitude: visit.longitude,
                            accuracy: visit.accuracy, at: arrival, environmentId: nil)
            }
            let environmentId = store.openStop?.environmentId
            send(.departure, latitude: visit.latitude, longitude: visit.longitude,
                 accuracy: visit.accuracy, at: departure, environmentId: environmentId)
            store.openStop = nil
            store.lastDepartureAt = departure
            return
        }

        guard let arrival = visit.arrivalDate else { return }
        if let lastDeparture, arrival <= lastDeparture { return }
        if let open = currentOpenStop(), belongs(visit, to: open) { return }
        pendingArrivalEnvironmentId = nil
        sendArrival(latitude: visit.latitude, longitude: visit.longitude,
                    accuracy: visit.accuracy, at: arrival, environmentId: nil)
    }

    func visitLocationManager(didUpdateFix fix: VisitFix) {
        if let environmentId = pendingArrivalEnvironmentId {
            pendingArrivalEnvironmentId = nil
            if canReportVisits, currentOpenStop() == nil {
                sendArrival(latitude: fix.latitude, longitude: fix.longitude, accuracy: fix.accuracy,
                            at: fix.timestamp, environmentId: environmentId)
            }
        }
        let forced = pendingRefresh && pendingRefreshForced
        pendingRefresh = false
        pendingRefreshForced = false
        refreshIfNeeded(fix: fix, forced: forced)
    }

    func visitLocationManagerDidFailToLocate() {
        // A CLVisit arrival still covers the stop; the fence exit is retried on the next fix.
        pendingArrivalEnvironmentId = nil
    }

    func visitLocationManagerDidChangeAuthorization() {
        guard isStarted else { return }
        applyCachedConfig()
        refreshIfNeeded(fix: locationManager.lastKnownFix, forced: false)
    }
}

// MARK: - CoreLocation adapter

/// Owns a dedicated `CLLocationManager` for visits. Region events are process-wide, so this
/// delegate also sees the beacon region: everything outside the visit namespace is ignored
/// (and `BeaconManager` ignores the circular visit regions).
final class CoreLocationVisitManager: NSObject, VisitLocationManaging, CLLocationManagerDelegate {

    weak var delegate: VisitLocationManagerDelegate?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    var authorizationStatus: CLAuthorizationStatus {
        if #available(iOS 14.0, *) {
            return manager.authorizationStatus
        }
        return CLLocationManager.authorizationStatus()
    }

    var lastKnownFix: VisitFix? {
        guard let location = manager.location, CLLocationCoordinate2DIsValid(location.coordinate) else { return nil }
        return Self.fix(location)
    }

    var monitoredRegions: [RegionBudget.MonitoredRegion] {
        manager.monitoredRegions.map { region in
            if let circle = region as? CLCircularRegion {
                return RegionBudget.MonitoredRegion(
                    identifier: circle.identifier,
                    center: RegionBudget.Coordinate(latitude: circle.center.latitude, longitude: circle.center.longitude),
                    radiusMeters: circle.radius
                )
            }
            return RegionBudget.MonitoredRegion(identifier: region.identifier)
        }
    }

    func startMonitoringVisits() {
        manager.startMonitoringVisits()
    }

    func stopMonitoringVisits() {
        manager.stopMonitoringVisits()
    }

    func startMonitoring(_ region: RegionBudget.PlannedRegion) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let circle = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: region.center.latitude, longitude: region.center.longitude),
            radius: min(region.radiusMeters, manager.maximumRegionMonitoringDistance),
            identifier: region.identifier
        )
        let isFence = region.identifier == RegionBudget.refreshFenceIdentifier
        circle.notifyOnEntry = !isFence
        circle.notifyOnExit = isFence
        manager.startMonitoring(for: circle)
    }

    func stopMonitoring(identifier: String) {
        for region in manager.monitoredRegions where region.identifier == identifier {
            manager.stopMonitoring(for: region)
        }
    }

    func requestLocation() {
        manager.requestLocation()
    }

    private static func fix(_ location: CLLocation) -> VisitFix {
        VisitFix(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy > 0 ? location.horizontalAccuracy : nil,
            timestamp: location.timestamp
        )
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_: CLLocationManager, didEnterRegion region: CLRegion) {
        guard RegionBudget.isSDKVisitIdentifier(region.identifier) else { return }
        delegate?.visitLocationManager(didEnterRegion: region.identifier)
    }

    func locationManager(_: CLLocationManager, didExitRegion region: CLRegion) {
        guard RegionBudget.isSDKVisitIdentifier(region.identifier) else { return }
        delegate?.visitLocationManager(didExitRegion: region.identifier)
    }

    func locationManager(_: CLLocationManager, didVisit visit: CLVisit) {
        let arrival = visit.arrivalDate == .distantPast ? nil : visit.arrivalDate
        let departure = visit.departureDate == .distantFuture ? nil : visit.departureDate
        delegate?.visitLocationManager(didVisit: VisitObservation(
            latitude: visit.coordinate.latitude,
            longitude: visit.coordinate.longitude,
            accuracy: visit.horizontalAccuracy > 0 ? visit.horizontalAccuracy : nil,
            arrivalDate: arrival,
            departureDate: departure
        ))
    }

    func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, CLLocationCoordinate2DIsValid(location.coordinate) else { return }
        delegate?.visitLocationManager(didUpdateFix: Self.fix(location))
    }

    func locationManager(_: CLLocationManager, didFailWithError error: Error) {
        NSLog("[BeAroundSDK] Visit location request failed: %@", error.localizedDescription)
        delegate?.visitLocationManagerDidFailToLocate()
    }

    func locationManager(_: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        guard let identifier = region?.identifier, RegionBudget.isSDKVisitIdentifier(identifier) else { return }
        NSLog("[BeAroundSDK] Visit region %@ failed to arm: %@", identifier, error.localizedDescription)
    }

    func locationManagerDidChangeAuthorization(_: CLLocationManager) {
        delegate?.visitLocationManagerDidChangeAuthorization()
    }

    func locationManager(_: CLLocationManager, didChangeAuthorization _: CLAuthorizationStatus) {
        // iOS 13 path; iOS 14+ calls locationManagerDidChangeAuthorization instead.
        if #available(iOS 14.0, *) { return }
        delegate?.visitLocationManagerDidChangeAuthorization()
    }
}

/// Bridges `VisitEventSending` to a closure, so `BeAroundSDK` keeps its send path private.
final class VisitEventForwarder: VisitEventSending {
    private let handler: (VisitEvent) -> Void

    init(_ handler: @escaping (VisitEvent) -> Void) {
        self.handler = handler
    }

    func send(_ event: VisitEvent) {
        handler(event)
    }
}
