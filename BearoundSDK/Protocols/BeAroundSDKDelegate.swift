//
//  BeAroundSDKDelegate.swift
//  BearoundSDK
//
//  Created by Bearound on 29/12/25.
//

import Foundation

public protocol BeAroundSDKDelegate: AnyObject {
	func didUpdateBeacons(_ beacons: [Beacon])

	func didFailWithError(_ error: Error)

	func didChangeScanning(isScanning: Bool)

	func didUpdateSyncStatus(secondsUntilNextSync: Int, isRanging: Bool)
}

extension BeAroundSDKDelegate {
	public func didFailWithError(_: Error) {}
	public func didChangeScanning(isScanning _: Bool) {}
	public func didUpdateSyncStatus(secondsUntilNextSync _: Int, isRanging _: Bool) {}
}
