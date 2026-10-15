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
    init() {}

    private let lock = NSLock()

    private(set) var lastScanAt: Date?
    private(set) var lastScanBeaconCount: Int?
    private(set) var lastSyncAt: Date?
    private(set) var lastSyncSuccess: Bool?
    private(set) var lastSyncBeaconCount: Int?
    private(set) var lastPushReceivedAt: Date?
    /// `WifiCollectorStatus` of the last Wi-Fi visit round; nil until one ran.
    private(set) var lastWifiStatus: String?
    private var errors: [String] = [] // ring buffer, last 10
    private var sampling = BeAroundSamplingDiagnostics()
    private var samplingOffsets = BeAroundSamplingDiagnostics()
    private var samplingGeneration: UInt64?
    private static let cumulativeSamplingCounters: [WritableKeyPath<BeAroundSamplingDiagnostics, Int64>] = [
        \.uniqueSamples, \.cachedCallbacks, \.liveAttempts, \.summaryAttempts, \.transitionAttempts,
        \.serializedBytes, \.failures, \.clockUncertainties, \.policyDenials, \.archiveOnlyAcknowledgements,
        \.pendingHistoryAcknowledgements, \.manifestGaps, \.capabilityInvalidations, \.complementaryCacheReads,
    ]

    func recordSampling(_ snapshot: BeAroundSamplingDiagnostics) {
        lock.lock(); defer { lock.unlock() }
        guard samplingGeneration.map({ snapshot.generation >= $0 }) ?? true else { return }
        if samplingGeneration != snapshot.generation {
            samplingOffsets = sampling
            samplingGeneration = snapshot.generation
        }
        let reads = sampling.complementaryReads
        sampling = snapshot
        sampling.complementaryReads = reads
        for field in Self.cumulativeSamplingCounters {
            sampling[keyPath: field] = samplingOffsets[keyPath: field] + snapshot[keyPath: field]
        }
        sampling.buckets = samplingOffsets.buckets + snapshot.buckets
        sampling.gaps = samplingOffsets.gaps + snapshot.gaps
    }

    func recordComplementaryRead(fresh: Bool) {
        lock.lock(); defer { lock.unlock() }
        if fresh { sampling.complementaryReads += 1 } else { sampling.complementaryCacheReads += 1 }
    }

    var samplingSnapshot: BeAroundSamplingDiagnostics {
        lock.lock(); defer { lock.unlock() }
        return sampling
    }

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

    func recordWifiStatus(_ status: String) {
        lock.lock(); defer { lock.unlock() }
        lastWifiStatus = status
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
