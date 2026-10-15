//
//  RegionBudgetTests.swift
//  BearoundSDKTests
//
//  Pure planner tests: no CLLocationManager, the monitored set is injected.
//

import Foundation
import Testing

@testable import BearoundSDK

@Suite("RegionBudget Tests")
struct RegionBudgetTests {

    private let origin = RegionBudget.Coordinate(latitude: -23.55, longitude: -46.63)

    private func targets(_ count: Int) -> [RegionBudget.Target] {
        (0..<count).map { index in
            RegionBudget.Target(
                environmentId: "env-\(index)",
                center: RegionBudget.Coordinate(latitude: -23.55 + Double(index) * 0.001, longitude: -46.63),
                radiusMeters: 100,
                distanceMeters: Double(index) * 100
            )
        }
    }

    private func hostRegions(_ count: Int) -> [RegionBudget.MonitoredRegion] {
        (0..<count).map { RegionBudget.MonitoredRegion(identifier: "host.region.\($0)") }
    }

    private var fence: RegionBudget.RefreshFence {
        RegionBudget.RefreshFence(origin: origin, radiusMeters: 2500)
    }

    @Test("SDK regions stop at 10 environments plus the fence and always leave 5 slots to the host")
    func neverExceedsCapAndKeepsHeadroom() {
        for hostCount in 0...22 {
            let monitored = hostRegions(hostCount) + [RegionBudget.MonitoredRegion(identifier: "BeAroundRegion")]
            let plan = RegionBudget().plan(monitored: monitored, refreshFence: fence, targets: targets(40))
            #expect(plan.hostRegionCount == hostCount)
            #expect(plan.beaconRegionCount == 1)
            let environments = plan.regions.filter { $0.environmentId != nil }.count
            #expect(environments == min(10, max(0, 20 - hostCount - 1 - 1 - 5)))
            #expect(plan.refreshFenceKept == (20 - hostCount - 1 - 5 > 0))
            if !plan.regions.isEmpty {
                // The SDK never takes the last 5 free slots.
                #expect(plan.totalRegionCount <= 20 - 5)
            }
            #expect(plan.totalRegionCount <= 20 || plan.regions.isEmpty)
        }
    }

    @Test("Beacon slot is reserved even before BeaconManager arms it")
    func beaconSlotReservedWhenNotArmed() {
        let plan = RegionBudget().plan(monitored: [], refreshFence: fence, targets: targets(40))
        #expect(plan.beaconRegionCount == 1)
        #expect(plan.hostRegionCount == 0)
        // Fixed ceiling: 10 environments plus the fence, even with 18 slots free.
        #expect(plan.regions.count == 11)
        #expect(plan.totalRegionCount == 12)
    }

    @Test("Without a refresh fence the environment count does not grow into the fence slot")
    func noFenceKeepsEnvironmentCount() {
        let plan = RegionBudget().plan(monitored: hostRegions(8), refreshFence: nil, targets: targets(40))
        // 20 - 8 host - 1 beacon - 1 fence slot - 5 headroom = 5 environments.
        #expect(plan.regions.map(\.environmentId) == (0..<5).map { "env-\($0)" })
        #expect(!plan.refreshFenceKept)
    }

    @Test("Excess targets drop the farthest environments, nearest are kept in order")
    func excessDropsFarthest() {
        let shuffled = targets(25).reversed()
        let plan = RegionBudget().plan(monitored: hostRegions(6), refreshFence: fence, targets: Array(shuffled))
        // 20 - 6 host - 1 beacon - 1 fence - 5 headroom = 7 environments.
        let kept = plan.regions.compactMap(\.environmentId)
        #expect(kept == (0..<7).map { "env-\($0)" })
        #expect(plan.droppedEnvironmentIds == (7..<25).map { "env-\($0)" })
        #expect(plan.regions.dropFirst().map(\.identifier) == kept.map { "bearound.visit.env.\($0)" })
    }

    @Test("Environment identifiers cannot collide with the refresh fence")
    func identifiersAreCollisionProof() {
        #expect(RegionBudget.environmentIdentifier("refresh") == "bearound.visit.env.refresh")
        #expect(RegionBudget.environmentIdentifier("refresh") != RegionBudget.refreshFenceIdentifier)
        #expect(RegionBudget.environmentId(fromIdentifier: "bearound.visit.env.refresh") == "refresh")
        #expect(RegionBudget.environmentId(fromIdentifier: RegionBudget.refreshFenceIdentifier) == nil)
        #expect(RegionBudget.environmentId(fromIdentifier: "bearound.visit.env-legacy") == nil)
        #expect(RegionBudget.environmentId(fromIdentifier: "host.region") == nil)
        // Legacy-format identifiers are still SDK-owned, so a re-plan or a teardown stops them.
        #expect(RegionBudget.isSDKVisitIdentifier("bearound.visit.env-legacy"))
    }

    @Test("Refresh fence is always kept ahead of every environment")
    func refreshFenceAlwaysKept() {
        for hostCount in 0...13 {
            let plan = RegionBudget().plan(monitored: hostRegions(hostCount), refreshFence: fence, targets: targets(40))
            #expect(plan.refreshFenceKept)
            #expect(plan.regions.first == RegionBudget.PlannedRegion(
                identifier: "bearound.visit.refresh",
                center: origin,
                radiusMeters: 2500,
                environmentId: nil
            ))
        }
        // One slot left above the headroom: it goes to the fence, not to the nearest environment.
        let tight = RegionBudget().plan(monitored: hostRegions(13), refreshFence: fence, targets: targets(5))
        #expect(tight.regions.map(\.identifier) == ["bearound.visit.refresh"])
        #expect(tight.droppedEnvironmentIds.count == 5)
        // No slot left above the headroom: nothing at all, not even the fence.
        let full = RegionBudget().plan(monitored: hostRegions(14), refreshFence: fence, targets: targets(5))
        #expect(full.regions.isEmpty)
    }

    @Test("Host regions are never stopped, only stale SDK visit regions are")
    func hostRegionsNeverTouched() {
        let monitored = hostRegions(3) + [
            RegionBudget.MonitoredRegion(identifier: "BeAroundRegion"),
            RegionBudget.MonitoredRegion(identifier: "bearound.visit.env.env-old"),
            RegionBudget.MonitoredRegion(identifier: "bearound.visit.env.env-0"),
        ]
        let plan = RegionBudget().plan(monitored: monitored, refreshFence: fence, targets: targets(3))
        #expect(plan.identifiersToStop == ["bearound.visit.env.env-old"])
        let touched = Set(plan.identifiersToStop + plan.regionsToStart.map(\.identifier))
        #expect(touched.allSatisfy { $0.hasPrefix("bearound.visit.") })
        #expect(plan.hostRegionCount == 3)
    }

    @Test("Regions already monitored with the same geometry are not restarted")
    func unchangedRegionsNotRestarted() {
        let first = targets(2)[0]
        let monitored = [
            RegionBudget.MonitoredRegion(identifier: "bearound.visit.env.env-0", center: first.center, radiusMeters: 100),
            RegionBudget.MonitoredRegion(identifier: "bearound.visit.refresh", center: origin, radiusMeters: 1000),
        ]
        let plan = RegionBudget().plan(monitored: monitored, refreshFence: fence, targets: targets(2))
        // The fence moved radius, env-1 is new, env-0 is unchanged.
        #expect(plan.regionsToStart.map(\.identifier) == ["bearound.visit.refresh", "bearound.visit.env.env-1"])
        #expect(plan.identifiersToStop.isEmpty)
    }
}
