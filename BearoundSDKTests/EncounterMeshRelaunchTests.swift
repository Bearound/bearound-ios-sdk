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

    /// `setEncounterMesh` hops to the BLE queue; poll instead of guessing a delay.
    private func waitForMesh(_ manager: BluetoothManager, expected: Bool) async -> Bool {
        for _ in 0..<100 {
            if (manager.encounterMesh != nil) == expected { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return (manager.encounterMesh != nil) == expected
    }

    @Test("Bringing the scan surfaces up joins the encounter mesh")
    func scanSurfacesJoinMesh() async {
        let manager = BluetoothManager()
        manager.startScanSurfaces(bluetoothAuthorized: true)
        #expect(await waitForMesh(manager, expected: true))
    }

    @Test("Bluetooth not authorized: no mesh")
    func deniedBluetoothKeepsMeshOff() async {
        let manager = BluetoothManager()
        manager.startScanSurfaces(bluetoothAuthorized: false)
        // Give the queue the same window the positive case gets before concluding.
        _ = await waitForMesh(manager, expected: true)
        #expect(manager.encounterMesh == nil)
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
