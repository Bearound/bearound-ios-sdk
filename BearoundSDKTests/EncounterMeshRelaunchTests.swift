//
//  EncounterMeshRelaunchTests.swift
//  BearoundSDKTests
//
//  The BLE surfaces a scan session brings up, and the background scan filter that
//  follows from them. `startScanSurfaces` is the single entry point shared by the
//  public `startScanning()` and the background-relaunch path.
//

import CoreBluetooth
import Foundation
import Testing

@testable import BearoundSDK

@Suite("Encounter mesh on relaunch")
struct EncounterMeshRelaunchTests {

    /// Whether the mesh exists once the BLE queue has run what `startScanSurfaces` queued.
    /// `setEncounterMesh` hops to that serial queue, so the answer comes from the work itself
    /// and not from a time window: a fixed 2 s poll failed on slow CI runners.
    private func meshAfterQueuedWork(_ manager: BluetoothManager) async -> Bool {
        await withCheckedContinuation { continuation in
            manager.afterQueuedBLEWorkFixture { continuation.resume(returning: manager.encounterMesh != nil) }
        }
    }

    @Test("Bringing the scan surfaces up joins the encounter mesh")
    func scanSurfacesJoinMesh() async {
        let manager = BluetoothManager()
        manager.startScanSurfaces(bluetoothAuthorized: true)
        #expect(await meshAfterQueuedWork(manager))
    }

    @Test("Bluetooth not authorized: no mesh")
    func deniedBluetoothKeepsMeshOff() async {
        let manager = BluetoothManager()
        manager.startScanSurfaces(bluetoothAuthorized: false)
        #expect(await !meshAfterQueuedWork(manager))
    }

    @Test("Background filter carries the mesh UUID only while the mesh is on")
    func backgroundFilterFollowsTheMesh() {
        let bead = CBUUID(string: "BEAD")

        let withMesh = BluetoothManager.backgroundScanServices(beadServiceUUID: bead, meshEnabled: true)
        #expect(withMesh.contains(bead))
        #expect(withMesh.contains(EncounterMeshManager.serviceUUID))
        #expect(withMesh.count == 2)

        let withoutMesh = BluetoothManager.backgroundScanServices(beadServiceUUID: bead, meshEnabled: false)
        #expect(withoutMesh == [bead])
    }
}
