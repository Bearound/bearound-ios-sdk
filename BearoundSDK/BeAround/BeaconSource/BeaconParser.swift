//
//  BeaconParser.swift
//  beaconDetector
//
//  Created by Arthur Sousa on 16/06/25.
//

import Foundation

class BeaconParser {
    
    /// Extrai o valor de major do nome do beacon
    /// Formato esperado: "B:FIRMWARE_MAJOR.MINOR_BATTERY_MOVEMENTS_TEMPERATURE"
    /// Exemplo: "B:1.0_0.14_100_0_20" → major = "0"
    func getMajor(_ name: String) -> String? {
        if let regex = try? NSRegularExpression(pattern: #"B:(\d+\.\d+)_(\d+)\.(\d+)"#) {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            if let match = regex.firstMatch(in: name, range: range),
               let majorRange = Range(match.range(at: 2), in: name) {
                return String(name[majorRange])
            }
        }
        return nil
    }
    
    /// Extrai o valor de minor do nome do beacon
    /// Formato esperado: "B:FIRMWARE_MAJOR.MINOR_BATTERY_MOVEMENTS_TEMPERATURE"
    /// Exemplo: "B:1.0_0.14_100_0_20" → minor = "14"
    func getMinor(_ name: String) -> String? {
        if let regex = try? NSRegularExpression(pattern: #"B:(\d+\.\d+)_(\d+)\.(\d+)"#) {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            if let match = regex.firstMatch(in: name, range: range),
               let minorRange = Range(match.range(at: 3), in: name) {
                return String(name[minorRange])
            }
        }
        return nil
    }
    
    func getDistanceInMeters(rssi: Float, txPower: Float = -59) -> Float? {
        if rssi == 0 { return -1 } // RSSI inválido
        
        let ratio = rssi / txPower
        if ratio < 1 {
            return pow(ratio, 10)
        } else {
            return 0.89976 * pow(ratio, 7.7095) + 0.111
        }
    }
}
