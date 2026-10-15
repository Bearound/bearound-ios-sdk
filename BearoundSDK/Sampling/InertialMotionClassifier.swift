import Foundation

struct InertialSample: Equatable {
    let monotonicAtMs: Int64
    let xG: Double
    let yG: Double
    let zG: Double
}

struct InertialWindow: Equatable {
    enum Classification: String { case active, quiet, ambiguous }
    let generation: UInt64
    let startedAtMonotonicMs: Int64
    let endedAtMonotonicMs: Int64
    let sampleCount: Int
    let dynamicRmsG: Double
    let excursionRatio: Double
    let classification: Classification
    var sourceClock: SamplingClock? = nil
}

enum InertialMotionClassifier {
    static let toleranceG = 0.000001

    static func atLeast(_ value: Double, threshold: Double) -> Bool {
        // One machine epsilon preserves inclusive tolerance after magnitude subtraction.
        value + toleranceG + Double.ulpOfOne >= threshold
    }

    static func classify(
        _ samples: [InertialSample], generation: UInt64,
        openedAtMs: Int64, closedAtMs: Int64, completedAtMs: Int64
    ) -> InertialWindow? {
        guard (30 ... 128).contains(samples.count), openedAtMs >= 0,
              closedAtMs >= openedAtMs, closedAtMs - openedAtMs <= 3_000,
              completedAtMs >= closedAtMs, completedAtMs - closedAtMs <= 250,
              let first = samples.first, let last = samples.last,
              first.monotonicAtMs >= openedAtMs, last.monotonicAtMs <= closedAtMs,
              last.monotonicAtMs - first.monotonicAtMs >= 2_000,
              completedAtMs - last.monotonicAtMs <= 5_000 else { return nil }
        var previous: Int64?
        var magnitudes: [Double] = []
        for sample in samples {
            guard sample.xG.isFinite, sample.yG.isFinite, sample.zG.isFinite,
                  sample.monotonicAtMs >= openedAtMs, sample.monotonicAtMs <= closedAtMs,
                  previous.map({ sample.monotonicAtMs > $0 && sample.monotonicAtMs - $0 <= 250 }) ?? true
            else { return nil }
            let magnitude = hypot(hypot(sample.xG, sample.yG), sample.zG)
            guard magnitude.isFinite else { return nil }
            magnitudes.append(magnitude)
            previous = sample.monotonicAtMs
        }
        let sorted = magnitudes.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? sorted[middle - 1] / 2 + sorted[middle] / 2 : sorted[middle]
        let dynamic = magnitudes.map { $0 - median }
        let rms = sqrt(dynamic.reduce(0) { $0 + $1 * $1 } / Double(dynamic.count))
        guard rms.isFinite else { return nil }
        let fraction = Double(dynamic.filter { atLeast(abs($0), threshold: 0.04) }.count) / Double(dynamic.count)
        let classification: InertialWindow.Classification = atLeast(rms, threshold: 0.06) && fraction >= 0.2
            ? .active : (rms <= 0.02 + toleranceG + Double.ulpOfOne ? .quiet : .ambiguous)
        return InertialWindow(generation: generation, startedAtMonotonicMs: first.monotonicAtMs,
            endedAtMonotonicMs: last.monotonicAtMs, sampleCount: samples.count,
            dynamicRmsG: rms, excursionRatio: fraction, classification: classification)
    }
}
