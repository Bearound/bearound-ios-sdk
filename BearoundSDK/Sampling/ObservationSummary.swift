import Foundation

final class ObservationSummary {
    struct Context {
        let tenantFingerprint: String
        let contextID: String
        let originalPayload: [String: ObservationJSONValue]
        let motion: MotionEvidence
        let policy: DataCollectionPolicy
    }

    struct Segment {
        let windowId: String
        let observedFrom: Int64
        let observedTo: Int64
        let beacons: [[String: ObservationJSONValue]]
        let context: Context
        let sampleCount: Int
        let gapCount: Int
    }

    struct CaptureResult {
        let liveBeacons: [[String: ObservationJSONValue]]
        let closedSegments: [Segment]
        let acceptedSamples: Int
        let duplicateSamples: Int
        let closedLiveSegments: [Segment]
    }

    private struct Statistics {
        var count = 0
        var minimum = Int.max
        var maximum = Int.min
        var mean = 0.0
        var m2 = 0.0
        var first: Int64 = 0
        var last: Int64 = 0

        mutating func add(_ rssi: Int, at timestamp: Int64) {
            count += 1
            minimum = min(minimum, rssi)
            maximum = max(maximum, rssi)
            let delta = Double(rssi) - mean
            mean += delta / Double(count)
            m2 += delta * (Double(rssi) - mean)
            if count == 1 { first = timestamp }
            last = timestamp
        }

        var payload: [String: ObservationJSONValue] {
            ["count": .number(Double(count)), "min": .number(Double(minimum)),
             "max": .number(Double(maximum)), "avg": .number(mean),
             "stdDev": .number(count > 1 ? sqrt(max(0, m2 / Double(count - 1))) : 0),
             "firstSeen": .number(Double(first)), "lastSeen": .number(Double(last))]
        }
    }

    private struct Sample {
        let payload: [String: ObservationJSONValue]
        let id: String
        let timestamp: Int64
        let elapsed: Int64
        let bucketID: String
        let ordinal: Int
        var emitted = false
    }

    private struct Bucket {
        let id = UUID().uuidString
        var statistics = Statistics()
        var firstSampleID = ""
        var lastSampleID = ""
    }

    private struct Signal {
        var statistics = Statistics()
        var buckets: [Int64: Bucket] = [:]
        var latest: Sample?
        var baseBytes = 0
    }

    private struct Window {
        let id = UUID().uuidString
        let context: Context
        var signals: [String: Signal] = [:]
        var first = Int64.max
        var last = Int64.min
        var firstElapsed = Int64.max
        var lastElapsed = Int64.min
        var sampleCount = 0
        var gapCount = 0
        var estimatedBytes: Int
    }

    private struct Watermark {
        let timestamp: Int64
        let elapsed: Int64
    }

    private static let bucketMs: Int64 = 10_000
    private static let windowMs: Int64 = 300_000
    private static let liveAgeMs: Int64 = 30_000
    private static let watermarkTtlMs: Int64 = 600_000
    private static let maxBeacons = 100
    private static let maxBuckets = 40
    private static let maxSamples = 65_536
    private static let maxWatermarks = 4096
    private static let maxCallbackIDs = 32
    private static let maxPayloadBytes = 524_288
    private static let envelopeBytes = 8192
    private static let statisticsBytes = 256
    private static let bucketBytes = 384

    private let lock = NSRecursiveLock()
    private let gapThresholdMs: Int64
    private var window: Window?
    private var watermarks: [String: Watermark] = [:]
    private var callbackIDs: [String] = []
    private var sequence: UInt64 = 0
    private var lastClock: SamplingClock?
    private var minimumSourceElapsed = Int64.min
    private(set) var captureStreamId: String
    private(set) var activeWindowId: String?

    init(captureStreamId: String = UUID().uuidString, baselineScanCallbackIntervalMs: Int64 = 1_000) {
        self.captureStreamId = captureStreamId
        gapThresholdMs = max(30_000, min(300_000, max(0, baselineScanCallbackIntervalMs)) * 2)
    }

    func observe(beacons: [Beacon], callbackID: String, context: Context, at clock: SamplingClock, isPhysical: Bool) -> CaptureResult {
        lock.lock()
        defer { lock.unlock() }
        guard isPhysical, clock.isReliable, clock.wallTimeMs > 0, clock.monotonicTimeMs >= 0 else {
            return CaptureResult(liveBeacons: [], closedSegments: [], acceptedSamples: 0, duplicateSamples: beacons.count, closedLiveSegments: [])
        }
        guard !callbackIDs.contains(callbackID) else {
            return CaptureResult(liveBeacons: [], closedSegments: [], acceptedSamples: 0, duplicateSamples: beacons.count, closedLiveSegments: [])
        }
        var closed: [Segment] = []
        var closedLive: [Segment] = []
        func seal() {
            if let live = drainLiveSegment(at: clock, maxAgeMs: Self.liveAgeMs) { closedLive.append(live) }
            if let segment = close(at: clock) { closed.append(segment) }
        }
        if let previous = lastClock,
           previous.bootIdentifier != clock.bootIdentifier || clock.monotonicTimeMs < previous.monotonicTimeMs ||
            abs(Double(clock.wallTimeMs - previous.wallTimeMs) - Double(clock.monotonicTimeMs - previous.monotonicTimeMs)) > 120_000 {
            seal()
            watermarks.removeAll()
            callbackIDs.removeAll()
            minimumSourceElapsed = clock.bootIdentifier == previous.bootIdentifier && clock.monotonicTimeMs >= previous.monotonicTimeMs
                ? previous.monotonicTimeMs : Int64.min
        }
        lastClock = clock
        callbackIDs.append(callbackID)
        if callbackIDs.count > Self.maxCallbackIDs { callbackIDs.removeFirst() }
        watermarks = watermarks.filter { clock.monotonicTimeMs < $0.value.elapsed || clock.monotonicTimeMs - $0.value.elapsed <= Self.watermarkTtlMs }
        if let existing = window, !sameContext(existing.context, context) {
            seal()
        }
        var payload = context.originalPayload
        payload.removeValue(forKey: "beacons")
        payload.removeValue(forKey: "sampling")
        guard let contextBytes = encodedSize(payload), contextBytes + Self.envelopeBytes < Self.maxPayloadBytes else {
            return CaptureResult(liveBeacons: [], closedSegments: closed, acceptedSamples: 0, duplicateSamples: 0, closedLiveSegments: closedLive)
        }
        let frozenContext = Context(tenantFingerprint: context.tenantFingerprint, contextID: context.contextID,
                                    originalPayload: payload, motion: context.motion, policy: context.policy)
        var accepted = 0
        var duplicates = 0
        for beacon in beacons.sorted(by: { $0.timestamp < $1.timestamp }) {
            let rawTimestamp = beacon.timestamp.timeIntervalSince1970 * 1000
            guard rawTimestamp.isFinite, rawTimestamp > 0, rawTimestamp < Double(Int64.max),
                  (-127...0).contains(beacon.rssi), beacon.accuracy.isFinite, beacon.accuracy >= -1,
                  (0...65535).contains(beacon.major), (0...65535).contains(beacon.minor) else { continue }
            let timestamp = Int64(rawTimestamp)
            guard timestamp <= clock.wallTimeMs, clock.wallTimeMs - timestamp <= Self.liveAgeMs else { duplicates += 1; continue }
            let age = clock.wallTimeMs - timestamp
            guard clock.monotonicTimeMs >= age else { continue }
            let elapsed = clock.monotonicTimeMs - age
            guard elapsed > minimumSourceElapsed else { duplicates += 1; continue }
            let key = "\(beacon.uuid.uuidString)_\(beacon.major)_\(beacon.minor)"
            let watermark = watermarks[key]
            if let watermark, timestamp <= watermark.timestamp || elapsed <= watermark.elapsed { duplicates += 1; continue }
            guard watermark != nil || watermarks.count < Self.maxWatermarks else { continue }
            let base = beaconPayload(beacon, timestamp: timestamp)
            guard let baseBytes = encodedSize(base), contextBytes + Self.envelopeBytes + baseBytes + Self.statisticsBytes + Self.bucketBytes <= Self.maxPayloadBytes else { continue }
            let gap = window.map { elapsed - $0.lastElapsed > gapThresholdMs || watermark.map { elapsed - $0.elapsed > gapThresholdMs } == true } ?? false
            if let existing = window,
               max(existing.last, timestamp) - min(existing.first, timestamp) >= Self.windowMs ||
                elapsed - existing.firstElapsed >= Self.windowMs || gap {
                if gap { window?.gapCount += 1 }
                seal()
            }
            if window == nil { open(frozenContext, contextBytes: contextBytes) }
            let index = timestamp / Self.bucketMs
            let signal = window!.signals[key]
            let newBucket = signal?.buckets[index] == nil
            let estimate = window!.estimatedBytes + baseBytes - (signal?.baseBytes ?? 0)
                + (signal == nil ? Self.statisticsBytes : 0) + (newBucket ? Self.bucketBytes : 0)
            if (signal == nil && window!.signals.count >= Self.maxBeacons) ||
                (newBucket && (signal?.buckets.count ?? 0) >= Self.maxBuckets) ||
                window!.sampleCount >= Self.maxSamples || estimate > Self.maxPayloadBytes {
                seal()
                open(frozenContext, contextBytes: contextBytes)
            }
            var target = window!.signals[key] ?? Signal()
            let occupied = target.buckets[index] == nil
            var bucket = target.buckets[index] ?? Bucket()
            sequence &+= 1
            let id = makeSampleID(signal: key)
            if bucket.statistics.count == 0 { bucket.firstSampleID = id }
            bucket.lastSampleID = id
            bucket.statistics.add(beacon.rssi, at: timestamp)
            target.statistics.add(beacon.rssi, at: timestamp)
            window!.estimatedBytes += baseBytes - target.baseBytes + (target.latest == nil ? Self.statisticsBytes : 0)
                + (occupied ? Self.bucketBytes : 0)
            target.baseBytes = baseBytes
            target.latest = Sample(payload: base, id: id, timestamp: timestamp, elapsed: elapsed,
                                   bucketID: bucket.id, ordinal: bucket.statistics.count)
            target.buckets[index] = bucket
            window!.signals[key] = target
            window!.first = min(window!.first, timestamp)
            window!.last = max(window!.last, timestamp)
            window!.firstElapsed = min(window!.firstElapsed, elapsed)
            window!.lastElapsed = max(window!.lastElapsed, elapsed)
            window!.sampleCount += 1
            watermarks[key] = Watermark(timestamp: timestamp, elapsed: elapsed)
            accepted += 1
        }
        return CaptureResult(liveBeacons: liveBeacons(at: clock, maxAgeMs: Self.liveAgeMs, consume: false),
                             closedSegments: closed, acceptedSamples: accepted, duplicateSamples: duplicates, closedLiveSegments: closedLive)
    }

    func close(at clock: SamplingClock) -> Segment? {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = window, existing.sampleCount > 0 else { return nil }
        var beacons: [[String: ObservationJSONValue]] = []
        for key in existing.signals.keys.sorted() {
            let signal = existing.signals[key]!
            var payload = signal.latest!.payload
            payload["rssiSamples"] = .object(signal.statistics.payload)
            payload["temporalBuckets"] = .array(signal.buckets.keys.sorted().map { index in
                let bucket = signal.buckets[index]!
                var statistics = bucket.statistics.payload
                statistics["bucketId"] = .string(bucket.id)
                statistics["firstSampleId"] = .string(bucket.firstSampleID)
                statistics["lastSampleId"] = .string(bucket.lastSampleID)
                return .object(statistics)
            })
            beacons.append(payload)
        }
        window = nil
        activeWindowId = nil
        return Segment(windowId: existing.id, observedFrom: existing.first, observedTo: existing.last,
                       beacons: beacons, context: existing.context, sampleCount: existing.sampleCount, gapCount: existing.gapCount)
    }

    func liveBeacons(at clock: SamplingClock, maxAgeMs: Int64, consume: Bool = true) -> [[String: ObservationJSONValue]] {
        lock.lock()
        defer { lock.unlock() }
        guard clock.isReliable, maxAgeMs > 0,
              lastClock?.bootIdentifier == clock.bootIdentifier else { return [] }
        var result: [[String: ObservationJSONValue]] = []
        var hasNewSample = false
        for key in (window?.signals.keys.map { $0 } ?? []).sorted() {
            guard var signal = window?.signals[key], var sample = signal.latest,
                  clock.monotonicTimeMs >= sample.elapsed,
                  clock.monotonicTimeMs - sample.elapsed <= min(Self.liveAgeMs, maxAgeMs) else { continue }
            var payload = sample.payload
            payload["sampleId"] = .string(sample.id)
            payload["bucketId"] = .string(sample.bucketID)
            payload["sampleOrdinal"] = .number(Double(sample.ordinal))
            result.append(payload)
            if !sample.emitted {
                hasNewSample = true
                if consume { sample.emitted = true; signal.latest = sample; window?.signals[key] = signal }
            }
        }
        return hasNewSample ? result : []
    }

    func drainLiveSegment(at clock: SamplingClock, maxAgeMs: Int64) -> Segment? {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = window, clock.isReliable, maxAgeMs > 0,
              lastClock?.bootIdentifier == clock.bootIdentifier else { return nil }
        let fresh = existing.signals.values.compactMap(\.latest).filter {
            clock.monotonicTimeMs >= $0.elapsed && clock.monotonicTimeMs - $0.elapsed <= min(Self.liveAgeMs, maxAgeMs)
        }
        let unseen = fresh.filter { !$0.emitted }.count
        guard unseen > 0, let first = fresh.map(\.timestamp).min(), let last = fresh.map(\.timestamp).max() else { return nil }
        let beacons = liveBeacons(at: clock, maxAgeMs: maxAgeMs)
        guard !beacons.isEmpty else { return nil }
        return Segment(windowId: existing.id, observedFrom: first, observedTo: last, beacons: beacons,
                       context: existing.context, sampleCount: unseen, gapCount: 0)
    }

    func reset(captureStreamId: String) {
        lock.lock()
        defer { lock.unlock() }
        self.captureStreamId = captureStreamId
        activeWindowId = nil
        window = nil
        watermarks.removeAll()
        callbackIDs.removeAll()
        sequence = 0
        lastClock = nil
        minimumSourceElapsed = Int64.min
    }

    private func open(_ context: Context, contextBytes: Int) {
        window = Window(context: context, estimatedBytes: contextBytes + Self.envelopeBytes)
        activeWindowId = window?.id
    }

    private func sameContext(_ first: Context, _ second: Context) -> Bool {
        first.tenantFingerprint == second.tenantFingerprint && first.contextID == second.contextID && first.policy == second.policy
    }

    private func encodedSize(_ payload: [String: ObservationJSONValue]) -> Int? { (try? JSONEncoder().encode(payload))?.count }

    private func makeSampleID(signal: String) -> String {
        let digest = SamplingTenantFingerprint.make(endpoint: captureStreamId, appID: String(sequence), deviceID: signal, businessToken: "")
        let parts = Array(digest.prefix(32))
        return "\(String(parts[0..<8]))-\(String(parts[8..<12]))-4\(String(parts[13..<16]))-8\(String(parts[17..<20]))-\(String(parts[20..<32]))"
    }

    private func beaconPayload(_ beacon: Beacon, timestamp: Int64) -> [String: ObservationJSONValue] {
        let proximity: String
        switch beacon.proximity {
        case .immediate: proximity = "immediate"
        case .near: proximity = "near"
        case .far: proximity = "far"
        case .bt: proximity = "bt"
        case .unknown: proximity = "unknown"
        }
        var payload: [String: ObservationJSONValue] = ["uuid": .string(beacon.uuid.uuidString),
            "major": .number(Double(beacon.major)), "minor": .number(Double(beacon.minor)),
            "rssi": .number(Double(beacon.rssi)), "accuracy": .number(beacon.accuracy),
            "proximity": .string(proximity), "timestamp": .number(Double(timestamp))]
        if let power = beacon.txPower { payload["txPower"] = .number(Double(power)) }
        if let metadata = beacon.metadata {
            var value: [String: ObservationJSONValue] = ["battery": .number(Double(metadata.batteryLevel)),
                "firmware": .string(metadata.firmwareVersion), "movements": .number(Double(metadata.movements)),
                "temperature": .number(Double(metadata.temperature))]
            if let power = metadata.txPower { value["txPower"] = .number(Double(power)) }
            if let rssi = metadata.rssiFromBLE { value["rssiFromBLE"] = .number(Double(rssi)) }
            if let connected = metadata.isConnectable { value["isConnectable"] = .bool(connected) }
            payload["metadata"] = .object(value)
        }
        return payload
    }
}
