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
            switch type {
            case .enter:
                defaultPrint(Constants.API.beaconsSend)
            case .exit:
                defaultPrint(Constants.API.beaconExit)
            case .lost:
                defaultPrint(Constants.API.saveLostBeacon)
            case .error:
                defaultPrint(Constants.API.errorOnRequest)
            }
        }
    }
    
    func defaultPrint(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        let prefix = "[BeAroundSDK]:"
        let message = items.map { "\($0)" }.joined(separator: separator)
        Swift.print("\(prefix) \(message)", terminator: terminator)
    }
}
