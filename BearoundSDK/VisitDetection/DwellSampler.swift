//
//  DwellSampler.swift
//  BearoundSDK
//
//  Dwell sampling: while the device stays at a monitored place, a short series of fresh
//  location fixes, one `/ingest` batch per fix, paced by the place's policy.
//

import CoreLocation
import Foundation
import UIKit

// MARK: - Policy

/// How a stay at a place is sampled: one fix every `intervalSeconds` during the first
/// `durationSeconds`, then one every `followUpIntervalSeconds` (0 ends there) until
/// `maxDurationSeconds`. Served per place by `/sdk/places/nearby` and in the `/ingest` answer.
struct DwellSamplingPolicy: Codable, Equatable {
    let level: String
    let intervalSeconds: Double
    let durationSeconds: Double
    let followUpIntervalSeconds: Double
    let maxDurationSeconds: Double

    /// Shortest interval the SDK honours, whatever the policy asks.
    static let minimumIntervalSeconds: Double = 30
    /// Longest sampling the SDK runs for one stay.
    static let maximumDurationSeconds: Double = 60 * 60

    /// The policy within the SDK bounds, or nil when it asks for no fix at all.
    var bounded: DwellSamplingPolicy? {
        guard intervalSeconds > 0, durationSeconds > 0, maxDurationSeconds > 0 else { return nil }
        let maxDuration = min(maxDurationSeconds, Self.maximumDurationSeconds)
        let interval = max(intervalSeconds, Self.minimumIntervalSeconds)
        guard interval <= maxDuration else { return nil }
        return DwellSamplingPolicy(
            level: level,
            intervalSeconds: interval,
            durationSeconds: min(durationSeconds, maxDuration),
            followUpIntervalSeconds: followUpIntervalSeconds > 0
                ? max(followUpIntervalSeconds, Self.minimumIntervalSeconds) : 0,
            maxDurationSeconds: maxDuration)
    }
}

/// The `dwellSampling` block of an `/ingest` answer: the batch just sent was inside a place
/// that asks for dwell sampling. It names the place and its circle, so it works for a place
/// that is not in the device's list.
struct DwellDirective: Equatable {
    let environmentId: String
    let policy: DwellSamplingPolicy
    let center: PlacesConfig.Coordinate?
    let radiusMeters: Double?

    private struct Body: Decodable {
        struct Block: Decodable {
            let environmentId: String
            let level: String
            let intervalSeconds: Double
            let durationSeconds: Double
            let followUpIntervalSeconds: Double
            let maxDurationSeconds: Double
            let center: PlacesConfig.Coordinate?
            let radiusMeters: Double?
        }
        let dwellSampling: Block?
    }

    private static let marker = Data("\"dwellSampling\"".utf8)

    /// nil for any answer without a well-formed block (the common case, checked cheaply).
    static func decode(_ data: Data) -> DwellDirective? {
        guard data.range(of: marker) != nil,
              let block = (try? JSONDecoder().decode(Body.self, from: data))?.dwellSampling,
              !block.environmentId.isEmpty
        else { return nil }
        return DwellDirective(
            environmentId: block.environmentId,
            policy: DwellSamplingPolicy(level: block.level, intervalSeconds: block.intervalSeconds,
                                        durationSeconds: block.durationSeconds,
                                        followUpIntervalSeconds: block.followUpIntervalSeconds,
                                        maxDurationSeconds: block.maxDurationSeconds),
            center: block.center,
            radiusMeters: block.radiusMeters)
    }
}

// MARK: - Seams

/// The location source of a burst: continuous updates that keep the app running in the
/// background, at full or reduced accuracy.
protocol DwellLocationManaging: AnyObject {
    var onFix: ((VisitFix) -> Void)? { get set }
    /// The host declares the `location` background mode: updates may continue in background.
    var canRunInBackground: Bool { get }
    func start(precise: Bool)
    func setPrecise(_ precise: Bool)
    /// Restarts the updates, so a stationary device delivers a fix with a new timestamp.
    func refresh()
    func stop()
}

protocol DwellPowerReading {
    var isLowPowerMode: Bool { get }
    /// 0...1, or nil when unknown.
    var batteryLevel: Float? { get }
    var isCharging: Bool { get }
}

struct SystemDwellPower: DwellPowerReading {
    var isLowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    var batteryLevel: Float? {
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? level : nil
    }
    var isCharging: Bool {
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
    }
}

protocol DwellCancellable {
    func cancel()
}

protocol DwellScheduling {
    /// Runs `work` on the main queue after `delay` seconds of wall-clock time.
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> DwellCancellable
}

struct MainQueueDwellScheduler: DwellScheduling {
    private final class Token: DwellCancellable {
        let timer: DispatchSourceTimer
        init(_ timer: DispatchSourceTimer) { self.timer = timer }
        func cancel() { timer.cancel() }
    }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> DwellCancellable {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Wall clock: the deadline keeps counting while the device sleeps between fixes.
        timer.schedule(wallDeadline: .now() + max(delay, 0), leeway: .seconds(1))
        timer.setEventHandler { [weak timer] in
            timer?.cancel()
            work()
        }
        timer.resume()
        return Token(timer)
    }
}

// MARK: - State

/// Counters that outlive the process: the daily cap, the stays already sampled and the end
/// of the last burst per place.
final class DwellSamplingStore {
    private static let keyDay = "dwell_day"
    private static let keyDayCount = "dwell_day_count"
    private static let keyStays = "dwell_sampled_stays"
    private static let keyEndedAt = "dwell_ended_at"

    private let defaults: UserDefaults
    private let calendar: Calendar

    init(defaults: UserDefaults? = UserDefaults(suiteName: VisitStateStore.defaultSuiteName),
         calendar: Calendar = .current) {
        self.defaults = defaults ?? .standard
        self.calendar = calendar
    }

    private func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    func burstsStarted(on date: Date) -> Int {
        defaults.string(forKey: Self.keyDay) == dayKey(date) ? defaults.integer(forKey: Self.keyDayCount) : 0
    }

    func recordBurstStart(at date: Date) {
        let count = burstsStarted(on: date) + 1
        defaults.set(dayKey(date), forKey: Self.keyDay)
        defaults.set(count, forKey: Self.keyDayCount)
    }

    /// Places sampled during the current stay: a stay is sampled once, until its fence exit.
    var sampledStays: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.keyStays) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.keyStays) }
    }

    func endedAt(_ environmentId: String) -> Date? {
        (defaults.dictionary(forKey: Self.keyEndedAt)?[environmentId] as? Double)
            .map(Date.init(timeIntervalSince1970:))
    }

    func recordEnd(_ environmentId: String, at date: Date) {
        var ended = defaults.dictionary(forKey: Self.keyEndedAt) as? [String: Double] ?? [:]
        // Old entries carry no information past the cooldown.
        ended = ended.filter { date.timeIntervalSince1970 - $0.value < DwellSampler.cooldownSeconds }
        ended[environmentId] = date.timeIntervalSince1970
        defaults.set(ended, forKey: Self.keyEndedAt)
    }

    func clearEnd(_ environmentId: String) {
        guard var ended = defaults.dictionary(forKey: Self.keyEndedAt) as? [String: Double],
              ended.removeValue(forKey: environmentId) != nil else { return }
        defaults.set(ended, forKey: Self.keyEndedAt)
    }
}

// MARK: - DwellSampler

/// Runs one dwell burst at a time. Main-thread only.
final class DwellSampler {

    /// Most bursts started per local calendar day.
    static let maxBurstsPerDay = 8
    /// After a burst ends, no new one at the same place for this long, unless its fence was
    /// exited in between.
    static let cooldownSeconds: TimeInterval = 30 * 60
    /// No burst at or below this battery level unless charging.
    static let minimumBatteryLevel: Float = 0.20
    /// A fix this fresh and this precise is taken as soon as a sample is due. Longer than the
    /// warmup, so the fixes the warmup brings count.
    static let freshFixMaxAge: TimeInterval = 30
    static let preciseFixMaxAccuracy: Double = 65
    /// With no such fix when a sample is due, the updates are restarted (a stationary device may
    /// deliver nothing new otherwise); after this long the best fix of the window up to
    /// `acceptableFixMaxAccuracy` is taken, or the sample is skipped.
    static let dueGrace: TimeInterval = 20
    static let acceptableFixMaxAccuracy: Double = 100
    /// Intervals from this long on drop to reduced accuracy between samples and go back to
    /// full accuracy `warmup` seconds before the next one.
    static let reducedAccuracyFromInterval: TimeInterval = 90
    static let warmup: TimeInterval = 15
    /// Farther than the place radius plus this (with a fix of acceptable accuracy) ends the burst.
    static let leaveMarginMeters: Double = 200

    enum EndReason: String {
        case completed
        case fenceExit = "fence_exit"
        case leftArea = "left_area"
        case power
        case stopped
    }

    private struct Burst {
        let environmentId: String
        let center: PlacesConfig.Coordinate
        let radiusMeters: Double
        let policy: DwellSamplingPolicy
        let startedAt: Date
        var nextDueAt: Date
        var dueSince: Date?
        var bestFix: VisitFix?
        var samples = 0
        /// A fix older than this is not a new sample: half an interval after the last one sent.
        var minFixAt = Date.distantPast
    }

    private let locationManager: DwellLocationManaging
    private let sender: (VisitFix, String) -> Void
    private let store: DwellSamplingStore
    private let clock: VisitClock
    private let power: DwellPowerReading
    private let scheduler: DwellScheduling

    private var burst: Burst?
    /// Whether the location source is at full accuracy.
    private var precise = false
    private var dueTimer: DwellCancellable?
    private var warmupTimer: DwellCancellable?
    private var graceTimer: DwellCancellable?

    init(locationManager: DwellLocationManaging,
         sender: @escaping (VisitFix, String) -> Void,
         store: DwellSamplingStore = DwellSamplingStore(),
         clock: VisitClock = SystemVisitClock(),
         power: DwellPowerReading = SystemDwellPower(),
         scheduler: DwellScheduling = MainQueueDwellScheduler()) {
        self.locationManager = locationManager
        self.sender = sender
        self.store = store
        self.clock = clock
        self.power = power
        self.scheduler = scheduler
        locationManager.onFix = { [weak self] fix in self?.handle(fix) }
    }

    var activeEnvironmentId: String? { burst?.environmentId }

    private var powerAllows: Bool {
        if power.isLowPowerMode { return false }
        if power.isCharging { return true }
        guard let level = power.batteryLevel else { return true }
        return level > Self.minimumBatteryLevel
    }

    /// Starts a burst at the place when every limit allows it. `trigger` is only logged.
    /// Returns whether a burst started.
    @discardableResult
    func start(environmentId: String, center: PlacesConfig.Coordinate, radiusMeters: Double,
               policy: DwellSamplingPolicy, trigger: String) -> Bool {
        guard burst == nil else { return false }
        guard let policy = policy.bounded else { return false }
        let now = clock.now
        guard locationManager.canRunInBackground else {
            NSLog("[BeAroundSDK] Dwell sampling skipped: 'location' is not in UIBackgroundModes")
            return false
        }
        guard powerAllows else {
            NSLog("[BeAroundSDK] Dwell sampling skipped at %@: low power", environmentId)
            return false
        }
        guard !store.sampledStays.contains(environmentId) else { return false }
        if let ended = store.endedAt(environmentId), now.timeIntervalSince(ended) < Self.cooldownSeconds {
            return false
        }
        guard store.burstsStarted(on: now) < Self.maxBurstsPerDay else {
            NSLog("[BeAroundSDK] Dwell sampling skipped at %@: daily limit reached", environmentId)
            return false
        }

        store.recordBurstStart(at: now)
        store.sampledStays.insert(environmentId)
        burst = Burst(environmentId: environmentId, center: center, radiusMeters: radiusMeters,
                      policy: policy, startedAt: now,
                      nextDueAt: now.addingTimeInterval(policy.intervalSeconds))
        precise = policy.intervalSeconds < Self.reducedAccuracyFromInterval
        locationManager.start(precise: precise)
        scheduleNext()
        NSLog("[BeAroundSDK] Dwell sampling started at %@ (%@, %@, every %.0fs)",
              environmentId, policy.level, trigger, policy.intervalSeconds)
        DetectionLogStore.append(type: "Dwell", detail: "started \(policy.level) (\(trigger))")
        return true
    }

    /// The fence of the place was exited: ends its burst and closes the stay, so the next
    /// entry is a new stay.
    func endStay(environmentId: String) {
        if burst?.environmentId == environmentId { finish(.fenceExit) }
        store.sampledStays.remove(environmentId)
        // The cooldown only holds back a repeat within the same stay: after an exit, the next
        // entry is a new stay (often seconds later, when the fence edge is crossed on arrival).
        store.clearEnd(environmentId)
    }

    /// Ends any burst (detection switched off, permission changed, SDK stopped) and forgets
    /// the open stays: the fences are disarmed, so no exit will close them.
    func stopAll() {
        if burst != nil { finish(.stopped) }
        store.sampledStays = []
    }

    // MARK: Sampling

    private func scheduleNext() {
        guard let burst else { return }
        dueTimer?.cancel()
        warmupTimer?.cancel()
        let delay = burst.nextDueAt.timeIntervalSince(clock.now)
        if !precise {
            if delay > Self.warmup {
                warmupTimer = scheduler.schedule(after: delay - Self.warmup) { [weak self] in self?.setPrecise(true) }
            } else {
                setPrecise(true)
            }
        }
        dueTimer = scheduler.schedule(after: delay) { [weak self] in self?.due() }
    }

    /// The interval in force for a sample due at `date`.
    private func currentInterval(at date: Date) -> TimeInterval {
        guard let burst else { return 0 }
        return date.timeIntervalSince(burst.startedAt) <= burst.policy.durationSeconds
            ? burst.policy.intervalSeconds : burst.policy.followUpIntervalSeconds
    }

    private func due() {
        guard var current = burst else { return }
        guard powerAllows else {
            finish(.power)
            return
        }
        let now = clock.now
        if let fix = current.bestFix, Self.isFresh(fix, at: now),
           (fix.accuracy ?? .infinity) <= Self.preciseFixMaxAccuracy {
            take(fix)
            return
        }
        current.dueSince = now
        burst = current
        setPrecise(true)
        locationManager.refresh()
        graceTimer?.cancel()
        graceTimer = scheduler.schedule(after: Self.dueGrace) { [weak self] in self?.graceExpired() }
    }

    private func graceExpired() {
        guard let current = burst, let dueSince = current.dueSince else { return }
        if let fix = current.bestFix,
           fix.timestamp >= dueSince.addingTimeInterval(-Self.freshFixMaxAge),
           (fix.accuracy ?? .infinity) <= Self.acceptableFixMaxAccuracy {
            take(fix)
        } else {
            NSLog("[BeAroundSDK] Dwell sample at %@ skipped: no fix of acceptable accuracy", current.environmentId)
            advance()
        }
    }

    private func handle(_ fix: VisitFix) {
        guard var current = burst else { return }
        let accuracy = fix.accuracy ?? .infinity
        if accuracy <= Self.acceptableFixMaxAccuracy,
           VisitMonitor.distanceMeters(fix.latitude, fix.longitude, current.center.lat, current.center.lng)
            > current.radiusMeters + Self.leaveMarginMeters {
            finish(.leftArea)
            return
        }
        // A fix too close to the last sample adds nothing (a stationary device may redeliver it).
        if fix.timestamp < current.minFixAt { return }
        // Keep the best fix of the moment: a newer one, unless it is much worse.
        if let best = current.bestFix, fix.timestamp < best.timestamp { return }
        if let best = current.bestFix, Self.isFresh(best, at: fix.timestamp),
           accuracy > (best.accuracy ?? .infinity) { return }
        current.bestFix = fix
        burst = current
        if let dueSince = current.dueSince, accuracy <= Self.preciseFixMaxAccuracy,
           fix.timestamp >= dueSince.addingTimeInterval(-Self.freshFixMaxAge) {
            take(fix)
        }
    }

    private func setPrecise(_ value: Bool) {
        guard value != precise else { return }
        precise = value
        locationManager.setPrecise(value)
    }

    private static func isFresh(_ fix: VisitFix, at date: Date) -> Bool {
        date.timeIntervalSince(fix.timestamp) <= freshFixMaxAge
    }

    private func take(_ fix: VisitFix) {
        guard var current = burst else { return }
        graceTimer?.cancel()
        current.samples += 1
        current.dueSince = nil
        current.bestFix = nil
        current.minFixAt = fix.timestamp.addingTimeInterval(currentInterval(at: clock.now) / 2)
        burst = current
        sender(fix, current.environmentId)
        advance()
    }

    private func advance() {
        guard var current = burst else { return }
        current.dueSince = nil
        let now = clock.now
        let interval = currentInterval(at: now)
        guard interval > 0 else {
            burst = current
            finish(.completed)
            return
        }
        var next = current.nextDueAt.addingTimeInterval(interval)
        if next <= now { next = now.addingTimeInterval(interval) }
        guard next.timeIntervalSince(current.startedAt) <= current.policy.maxDurationSeconds else {
            burst = current
            finish(.completed)
            return
        }
        current.nextDueAt = next
        burst = current
        if interval >= Self.reducedAccuracyFromInterval { setPrecise(false) }
        scheduleNext()
    }

    private func finish(_ reason: EndReason) {
        guard let ended = burst else { return }
        burst = nil
        dueTimer?.cancel()
        warmupTimer?.cancel()
        graceTimer?.cancel()
        dueTimer = nil
        warmupTimer = nil
        graceTimer = nil
        locationManager.stop()
        store.recordEnd(ended.environmentId, at: clock.now)
        NSLog("[BeAroundSDK] Dwell sampling at %@ ended (%@) after %d sample(s)",
              ended.environmentId, reason.rawValue, ended.samples)
        DetectionLogStore.append(type: "Dwell", detail: "ended \(reason.rawValue), \(ended.samples) sample(s)")
    }
}

// MARK: - CoreLocation adapter

/// A dedicated `CLLocationManager` for bursts, so the visit manager's one-shot requests and
/// the beacon manager's settings are untouched.
final class CoreLocationDwellManager: NSObject, DwellLocationManaging, CLLocationManagerDelegate {

    var onFix: ((VisitFix) -> Void)?
    private let manager = CLLocationManager()
    private var running = false

    override init() {
        super.init()
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
        manager.distanceFilter = kCLDistanceFilterNone
        if #available(iOS 14.0, *) {
            manager.showsBackgroundLocationIndicator = false
        }
    }

    var canRunInBackground: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") == true
    }

    func start(precise: Bool) {
        // Setting this without the background mode raises an exception.
        guard canRunInBackground else { return }
        manager.allowsBackgroundLocationUpdates = true
        setPrecise(precise)
        running = true
        manager.startUpdatingLocation()
    }

    func setPrecise(_ precise: Bool) {
        // Reduced accuracy keeps the app running between samples at a fraction of the power.
        manager.desiredAccuracy = precise ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyThreeKilometers
    }

    func refresh() {
        guard running else { return }
        manager.stopUpdatingLocation()
        manager.startUpdatingLocation()
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, CLLocationCoordinate2DIsValid(location.coordinate) else { return }
        onFix?(VisitFix(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                        accuracy: location.horizontalAccuracy > 0 ? location.horizontalAccuracy : nil,
                        timestamp: location.timestamp))
    }

    func locationManager(_: CLLocationManager, didFailWithError error: Error) {
        NSLog("[BeAroundSDK] Dwell location update failed: %@", error.localizedDescription)
    }
}
