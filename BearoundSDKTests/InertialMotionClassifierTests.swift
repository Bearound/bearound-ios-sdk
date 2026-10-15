import CryptoKit
import Foundation
import Testing
@testable import BearoundSDK

@Suite("Inertial Motion Classifier Tests")
struct InertialMotionClassifierTests {
    private final class FixtureBundle: NSObject {}
    private struct Fixtures: Decodable {
        struct Case: Decodable { let id: String; let expected: String; let samples: [[Double]] }
        let cases: [Case]
    }
    private func samples(amplitude: Double = 0.1) -> [InertialSample] {
        (0 ..< 40).map { InertialSample(monotonicAtMs: Int64($0 * 60), xG: 0, yG: 0,
            zG: 1 + ($0.isMultiple(of: 2) ? amplitude : -amplitude)) }
    }
    private func classify(_ values: [InertialSample], closed: Int64 = 3_000, completed: Int64 = 3_000) -> InertialWindow? {
        InertialMotionClassifier.classify(values, generation: 7, openedAtMs: 0,
            closedAtMs: closed, completedAtMs: completed)
    }

    @Test("Ten packaged shared fixtures match the frozen SHA and cross platform classifications")
    func frozenFixtures() throws {
        let bundle = Bundle(for: FixtureBundle.self)
        let url = try #require(bundle.url(forResource: "inertial-fixtures", withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "inertial-fixtures", withExtension: "json"))
        let data = try Data(contentsOf: url)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            == "a181a979fdaddd4532fb01a544fddd210811a37bad6b3b0287827b95416f808d")
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: data)
        #expect(fixtures.cases.count == 10)
        for fixture in fixtures.cases {
            let values = fixture.samples.map { InertialSample(monotonicAtMs: Int64($0[0]), xG: $0[1], yG: $0[2], zG: $0[3]) }
            let result = classify(values)
            #expect((result?.classification.rawValue ?? "invalid") == fixture.expected, "Fixture \(fixture.id)")
            let normalized = values.map { InertialSample(monotonicAtMs: $0.monotonicAtMs,
                xG: $0.xG * 9.80665 / 9.80665, yG: $0.yG * 9.80665 / 9.80665, zG: $0.zG * 9.80665 / 9.80665) }
            #expect(classify(normalized)?.classification == result?.classification)
            if let result, let counterpart = classify(normalized) {
                #expect(abs(result.dynamicRmsG - counterpart.dynamicRmsG) <= 0.000001)
            }
        }
    }

    @Test("RMS and quiet boundaries apply only the frozen scalar tolerance")
    func scalarBoundaries() {
        for amplitude in [0.06 - 0.000001, 0.06, 0.06 + 0.000001] {
            #expect(classify(samples(amplitude: amplitude))?.classification == .active)
        }
        #expect(classify(samples(amplitude: 0.06 - 0.0000011))?.classification == .ambiguous)
        #expect(classify(samples(amplitude: 0.02 + 0.0000009))?.classification == .quiet)
        #expect(classify(samples(amplitude: 0.02 + 0.0000011))?.classification == .ambiguous)
        for count in [7, 8] {
            let values = (0 ..< 40).map { i in InertialSample(monotonicAtMs: Int64(i * 60), xG: 0, yG: 0,
                zG: 1 + (i < count ? (i.isMultiple(of: 2) ? 0.2 : -0.2) : 0)) }
            #expect(classify(values)?.classification == (count == 8 ? .active : .ambiguous))
        }
    }

    @Test("Invalid axes timing gaps duplicate samples overflow and delayed completion reject the entire window")
    func invalidWindows() {
        let base = samples()
        for bad in [Double.nan, .infinity, -.infinity] {
            var values = base; values[10] = InertialSample(monotonicAtMs: 600, xG: bad, yG: 0, zG: 1)
            #expect(classify(values) == nil)
        }
        var duplicate = base; duplicate[10] = duplicate[9]
        var gap = base; gap[10] = InertialSample(monotonicAtMs: 1_000, xG: 0, yG: 0, zG: 1)
        #expect(classify(duplicate) == nil && classify(gap) == nil)
        #expect(classify(Array(base.prefix(29))) == nil)
        #expect(classify(Array(repeating: base[0], count: 129)) == nil)
        #expect(classify(base, completed: 3_251) == nil)
        #expect(classify(base, completed: 3_250) != nil)
        #expect(classify(base, completed: 2_999) == nil)
        #expect(classify(base, closed: 2_000) == nil)
        #expect(classify(base, completed: 9_000) == nil)
        let before = base.map { InertialSample(monotonicAtMs: $0.monotonicAtMs - 1, xG: 0, yG: 0, zG: 1) }
        #expect(classify(before) == nil)
    }
    @Test("Exactly thirty samples and a two second span qualify without tolerance on counts or timestamps")
    func minimumCoverageBoundary() {
        for span: Int64 in [1_999, 2_000] {
            let values = (0 ..< 30).map { InertialSample(monotonicAtMs: Int64($0) * span / 29,
                xG: 0, yG: 0, zG: 1) }
            #expect((classify(values) != nil) == (span == 2_000))
        }
    }

}
