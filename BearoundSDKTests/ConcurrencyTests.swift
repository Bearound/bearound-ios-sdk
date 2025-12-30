////
////  ConcurrencyTests.swift
////  BearoundSDKTests
////
////  Thread safety and concurrency tests
////
//
//import Testing
//import Foundation
//@testable import BearoundSDK
//internal import CoreLocation
//
//@Suite("Concurrency and Thread Safety")
//struct ConcurrencyTests {
//    
//    @Test("Concurrent beacon creation")
//    func concurrentBeaconCreation() async {
//        await withTaskGroup(of: Beacon.self) { group in
//            for i in 1...100 {
//                group.addTask {
//                    return Beacon(
//                        uuid: UUID(),
//                        major: i,
//                        minor: i,
//                        rssi: -60,
//                        proximity: .near,
//                        accuracy: 1.0,
//                        timestamp: Date()
//                    )
//                }
//            }
//            
//            var beacons: [Beacon] = []
//            for await beacon in group {
//                beacons.append(beacon)
//            }
//            
//            #expect(beacons.count == 100)
//        }
//    }
//    
//    @Test("Concurrent user properties updates")
//    func concurrentUserPropertiesUpdates() async {
//        let sdk = BeAroundSDK.shared
//        
//        await withTaskGroup(of: Void.self) { group in
//            for i in 1...50 {
//                group.addTask {
//                    let props = UserProperties(
//                        internalId: "user-\(i)",
//                        email: "user\(i)@test.com"
//                    )
//                    sdk.setUserProperties(props)
//                }
//            }
//        }
//        
//        // Should complete without crashes
//    }
//    
//    @Test("Concurrent configuration changes")
//    func concurrentConfigurationChanges() async {
//        let sdk = BeAroundSDK.shared
//        
//        await withTaskGroup(of: Void.self) { group in
//            for i in 1...20 {
//                group.addTask {
//                    sdk.configure(
//                        appId: "concurrent-app-\(i)",
//                        syncInterval: 10 + TimeInterval(i),
//                        enableBluetoothScanning: i % 2 == 0
//                    )
//                }
//            }
//        }
//        
//        // Should complete without crashes
//        #expect(sdk.currentSyncInterval != nil)
//    }
//}
//
