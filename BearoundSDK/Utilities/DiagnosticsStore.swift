//
//  DiagnosticsStore.swift
//  BearoundSDK
//
//  Created by Bearound on 04/06/26.
//

import Foundation

/// In-memory record of recent SDK activity, surfaced via `BeAroundSDK.diagnostics()`.
final class DiagnosticsStore {
    static let shared = DiagnosticsStore()
    private init() {}

    private let lock = NSLock()

    private(set) var lastScanAt: Date?
    private(set) var lastScanBeaconCount: Int?
    private(set) var lastSyncAt: Date?
    private(set) var lastSyncSuccess: Bool?
    private(set) var lastSyncBeaconCount: Int?
    private(set) var lastPushReceivedAt: Date?
    private var errors: [String] = [] // ring buffer, last 10

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); return f
    }()

    func recordScan(beaconCount: Int) {
        lock.lock(); defer { lock.unlock() }
        lastScanAt = Date(); lastScanBeaconCount = beaconCount
    }

    func recordSync(success: Bool, beaconCount: Int) {
        lock.lock(); defer { lock.unlock() }
        lastSyncAt = Date(); lastSyncSuccess = success; lastSyncBeaconCount = beaconCount
    }

    func recordPushReceived() {
        lock.lock(); defer { lock.unlock() }
        lastPushReceivedAt = Date()
    }

    func recordError(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        errors.append("\(iso.string(from: Date())) | \(message)")
        if errors.count > 10 { errors.removeFirst(errors.count - 10) }
    }

    var recentErrors: [String] {
        lock.lock(); defer { lock.unlock() }
        return errors
    }
}
