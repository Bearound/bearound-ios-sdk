//
//  DebuggerHelper.swift
//  poc
//
//  Created by Arthur Sousa on 16/07/25.
//

import Foundation

class DebuggerHelper {
    var isDebuggerEnabled: Bool
    
    init(_ isDebuggerEnabled: Bool) {
        self.isDebuggerEnabled = isDebuggerEnabled
    }
    
    func printStatments(type: RequestType) {
        if isDebuggerEnabled {
            if type == .enter {
                print(Constants.API.beaconsSend)
            } else if type == .exit {
                print(Constants.API.beaconExit)
            } else if type == .lost {
                print(Constants.API.saveLostBeacon)
            }
        }
    }
}
