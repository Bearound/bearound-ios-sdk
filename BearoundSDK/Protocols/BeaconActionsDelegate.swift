//
//  BeaconActionsDelegate.swift
//  BearoundSDK
//
//  Created by Felipe Costa Araujo on 22/12/25.
//

import Foundation

// MARK: - Internal Delegate Protocol

/// Internal protocol for beacon scanners to communicate with the main SDK class
@MainActor
protocol BeaconActionsDelegate: AnyObject {
    /// Updates the internal beacon list with newly detected or updated beacon
    /// - Parameter beacon: The beacon to add or update
    func updateBeaconList(_ beacon: Beacon)
}
