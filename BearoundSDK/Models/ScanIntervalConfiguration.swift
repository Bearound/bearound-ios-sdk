//
//  ScanIntervalConfiguration.swift
//  BearoundSDK
//
//  Created by Bearound on 12/01/26.
//

import Foundation

/// Foreground scan interval configuration
/// Range: 5 seconds (minimum) to 600 seconds (10 minutes, maximum)
public struct ForegroundScanInterval: Equatable {
    public static let minimum: TimeInterval = 5
    public static let maximum: TimeInterval = 600
    public static let `default`: TimeInterval = 10

    public let timeInterval: TimeInterval

    public init(seconds: TimeInterval) {
        self.timeInterval = max(Self.minimum, min(seconds, Self.maximum))
    }
}

/// Background scan interval configuration
/// Range: 15 seconds (minimum) to 600 seconds (10 minutes, maximum)
public struct BackgroundScanInterval: Equatable {
    public static let minimum: TimeInterval = 15
    public static let maximum: TimeInterval = 600
    public static let `default`: TimeInterval = 30

    public let timeInterval: TimeInterval

    public init(seconds: TimeInterval) {
        self.timeInterval = max(Self.minimum, min(seconds, Self.maximum))
    }
}

/// Maximum queued payloads configuration
public enum MaxQueuedPayloads: Int, CaseIterable {
    case small = 50
    case medium = 100
    case large = 200
    case xlarge = 500

    public var value: Int {
        rawValue
    }
}
