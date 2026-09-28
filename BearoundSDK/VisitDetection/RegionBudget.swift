//
//  RegionBudget.swift
//  BearoundSDK
//
//  Created by Bearound on 28/09/26.
//

import Foundation

/// Pure planner for the iOS region-monitoring budget (REQ-015, D-09).
///
/// iOS caps monitored regions at 20 per app, and that cap is shared by
/// everything running inside the host process: the host app's own regions,
/// the SDK beacon region (`BeaconManager`, identifier `BeAroundRegion`), the
/// visit refresh fence (REQ-021) and the circular regions of the nearest
/// target environments (D-23: the unit is the environment).
///
/// Priority when the budget is short, highest first:
/// 1. host regions: never touched, never removed, always counted;
/// 2. SDK beacon regions: always reserved, even when not armed yet, because
///    `BeaconManager` may arm them at any moment;
/// 3. the refresh fence: kept ahead of every environment region;
/// 4. environment regions, nearest first; the farthest are dropped.
///
/// The planner performs no CoreLocation call: the caller injects a snapshot of
/// `CLLocationManager.monitoredRegions` and applies the returned plan. When the
/// cap is still hit at apply time (a host region armed in between), iOS reports
/// it through `monitoringDidFailFor`, which the SDK already logs silently.
struct RegionBudget {

    /// iOS limit of monitored regions per app.
    static let iosRegionCap = 20

    /// Identifiers the SDK uses for beacon region monitoring. `BeaconManager`
    /// arms a single `CLBeaconRegion` under this identifier (the cold-start
    /// "boot region" reuses it, so iOS keeps one entry). The mesh virtual
    /// beacon region is only an advertising payload and is never monitored.
    static let sdkBeaconRegionIdentifiers: Set<String> = ["BeAroundRegion"]

    /// Namespace of every region this planner owns. Anything outside it (and
    /// outside the beacon identifiers) belongs to the host app.
    static let visitIdentifierPrefix = "bearound.visit."
    static let refreshFenceIdentifier = "bearound.visit.refresh"

    static func environmentIdentifier(_ environmentId: String) -> String {
        visitIdentifierPrefix + environmentId
    }

    static func isSDKVisitIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(visitIdentifierPrefix)
    }

    // MARK: - Inputs

    struct Coordinate: Equatable {
        let latitude: Double
        let longitude: Double
    }

    /// One entry of `CLLocationManager.monitoredRegions`, reduced to plain values.
    /// `center`/`radiusMeters` are set only for circular regions.
    struct MonitoredRegion: Equatable {
        let identifier: String
        let center: Coordinate?
        let radiusMeters: Double?

        init(identifier: String, center: Coordinate? = nil, radiusMeters: Double? = nil) {
            self.identifier = identifier
            self.center = center
            self.radiusMeters = radiusMeters
        }
    }

    /// A candidate environment from `GET /sdk/places/nearby`, circle only
    /// (polygon geometry arrives with `center` + `radiusMeters`).
    struct Target: Equatable {
        let environmentId: String
        let center: Coordinate
        let radiusMeters: Double
        let distanceMeters: Double
    }

    /// The fence centered at the fetch `origin` with radius `refreshAfterMeters`.
    struct RefreshFence: Equatable {
        let origin: Coordinate
        let radiusMeters: Double
    }

    // MARK: - Output

    struct PlannedRegion: Equatable {
        let identifier: String
        let center: Coordinate
        let radiusMeters: Double
        /// nil for the refresh fence.
        let environmentId: String?
    }

    struct Plan: Equatable {
        /// Every SDK circular region that should be monitored after applying the
        /// plan: the refresh fence first (when it fits), then environments
        /// nearest first.
        let regions: [PlannedRegion]
        /// Subset of `regions` that is not monitored yet, or is monitored with a
        /// different geometry: call `startMonitoring(for:)` on these only.
        let regionsToStart: [PlannedRegion]
        /// SDK visit identifiers currently monitored that are no longer wanted.
        /// Never contains a host or beacon identifier.
        let identifiersToStop: [String]
        /// Target environments left out because the budget did not cover them,
        /// nearest first.
        let droppedEnvironmentIds: [String]
        /// Monitored regions that belong to the host app (counted, untouched).
        let hostRegionCount: Int
        /// Slots reserved for SDK beacon regions.
        let beaconRegionCount: Int

        /// Total regions monitored once the plan is applied.
        var totalRegionCount: Int { hostRegionCount + beaconRegionCount + regions.count }
        var refreshFenceKept: Bool { regions.first?.identifier == RegionBudget.refreshFenceIdentifier }
    }

    // MARK: - Planning

    let cap: Int
    let beaconIdentifiers: Set<String>

    init(cap: Int = RegionBudget.iosRegionCap,
         beaconIdentifiers: Set<String> = RegionBudget.sdkBeaconRegionIdentifiers) {
        self.cap = cap
        self.beaconIdentifiers = beaconIdentifiers
    }

    func plan(monitored: [MonitoredRegion], refreshFence: RefreshFence?, targets: [Target]) -> Plan {
        let hostCount = Set(monitored.map(\.identifier)).filter {
            !Self.isSDKVisitIdentifier($0) && !beaconIdentifiers.contains($0)
        }.count
        let beaconCount = beaconIdentifiers.count
        var free = max(0, cap - hostCount - beaconCount)

        var regions: [PlannedRegion] = []
        if let fence = refreshFence, free > 0 {
            regions.append(PlannedRegion(
                identifier: Self.refreshFenceIdentifier,
                center: fence.origin,
                radiusMeters: fence.radiusMeters,
                environmentId: nil
            ))
            free -= 1
        }

        // Nearest first; the stable sort keeps the server order on ties.
        // Duplicated environments keep their nearest occurrence.
        var seen = Set<String>()
        let candidates = targets.enumerated()
            .sorted { ($0.element.distanceMeters, $0.offset) < ($1.element.distanceMeters, $1.offset) }
            .map(\.element)
            .filter { seen.insert($0.environmentId).inserted }

        var dropped: [String] = []
        for target in candidates {
            if free > 0 {
                regions.append(PlannedRegion(
                    identifier: Self.environmentIdentifier(target.environmentId),
                    center: target.center,
                    radiusMeters: target.radiusMeters,
                    environmentId: target.environmentId
                ))
                free -= 1
            } else {
                dropped.append(target.environmentId)
            }
        }

        let monitoredById = Dictionary(monitored.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let regionsToStart = regions.filter { planned in
            guard let current = monitoredById[planned.identifier] else { return true }
            return !Self.sameGeometry(current, planned)
        }

        let wanted = Set(regions.map(\.identifier))
        var stopSeen = Set<String>()
        let identifiersToStop = monitored.map(\.identifier).filter {
            Self.isSDKVisitIdentifier($0) && !wanted.contains($0) && stopSeen.insert($0).inserted
        }

        return Plan(
            regions: regions,
            regionsToStart: regionsToStart,
            identifiersToStop: identifiersToStop,
            droppedEnvironmentIds: dropped,
            hostRegionCount: hostCount,
            beaconRegionCount: beaconCount
        )
    }

    /// CoreLocation round-trips coordinates as doubles; allow sub-meter noise.
    private static func sameGeometry(_ current: MonitoredRegion, _ planned: PlannedRegion) -> Bool {
        guard let center = current.center, let radius = current.radiusMeters else { return false }
        return abs(center.latitude - planned.center.latitude) < 1e-6
            && abs(center.longitude - planned.center.longitude) < 1e-6
            && abs(radius - planned.radiusMeters) < 0.5
    }
}
