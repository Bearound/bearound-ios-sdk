//
//  BeaconParser.swift
//  beaconDetector
//
//  Created by Arthur Sousa on 16/06/25.
//

import Foundation

class BeaconParser {
    
    func getMajor(_ name: String) -> String? {
        let pattern = #"bearound_m(\d+)\.(\d+)_\d+\.\d+"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsrange = NSRange(name.startIndex..<name.endIndex, in: name)
            
            if let match = regex.firstMatch(in: name, options: [], range: nsrange) {
                if let majorRange = Range(match.range(at: 1), in: name),
                   let minorRange = Range(match.range(at: 2), in: name) {
                    
                    return String(name[majorRange])
                }
            }
        }
        return nil
    }
    
    func getMinor(_ name: String) -> String? {
        let pattern = #"bearound_m(\d+)\.(\d+)_\d+\.\d+"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsrange = NSRange(name.startIndex..<name.endIndex, in: name)
            
            if let match = regex.firstMatch(in: name, options: [], range: nsrange) {
                if let majorRange = Range(match.range(at: 1), in: name),
                   let minorRange = Range(match.range(at: 2), in: name) {
                    
                    
                    return String(name[minorRange])
                }
            }
        }
        return nil
    }
    
    func getBluetoothAdress() -> String? {
        return ""
    }
    
    func getDistanceInMeters() -> Float? {
        return 0.5
    }
}
