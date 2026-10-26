import Foundation
import Testing
@testable import PacerCore

/// g1-01-sonnet-calibrate123: the child's forecast pulled toward its median
/// by 0.6. On a stub child, then against the Python's own deterministic
/// quantiles of the child (`fm-timestral-123m-meter.json`) through the same
/// map, end to end on this Mac's network (skipped without its weights).
@Suite struct EnsembleCalibrate123Tests {
    static let name = "g1-01-sonnet-calibrate123"

    final class Child: ArenaModel {
        init(context: ArenaContext) {}
        func fit(_ history: ArenaHistory) {}
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
            ArenaForecast(byKey: Dictionary(uniqueKeysWithValues: request.targets.map { tr in
                (tr.key, ArenaTargetForecast(levels: [0.1, 0.5, 0.9],
                                             quantiles: [tr.grid.map { _ in 10 }, tr.grid.map { _ in 20 },
                                                         tr.grid.map { _ in 90 }]))
            }))
        }
    }

    @Test func scalesTheChildAroundItsMedian() throws {
        let c = try #require(try ArenaFixtures.cases().cases.first)
        var spec = try #require(ArenaRegistry.spec(Self.name))
        spec.weights = []
        let runner = ArenaRunner(registry: [spec, ArenaModelSpec(name: "fm-timestral-123m-meter",
                                                                 targets: spec.targets) { Child(context: $0) }])
        let fc = try runner.forecast(model: Self.name, history: ArenaFixtures.history(c),
                                     request: ArenaFixtures.request(c))
        let tf = try #require(fc.byKey[c.request.key])
        #expect(tf.levels == [0.1, 0.5, 0.9])
        #expect(tf.quantile(0.1).allSatisfy { $0 == 14 })      // 20 + 0.6 · (10 − 20)
        #expect(tf.median.allSatisfy { $0 == 20 })
        #expect(tf.quantile(0.9).allSatisfy { abs($0 - 62) < 1e-12 })
        // Paths: the same map about the per-time median, clipped to [0, 100].
        let p = Calibrate123Model.scaled(ArenaTargetForecast(paths: [[0, 100], [10, 100], [30, 100]]), 0.5)
        #expect(p.paths == [[5, 100], [10, 100], [20, 100]])
    }

    @Test func matchesThePythonChildThroughTheMap() throws {
        guard TimestralTestWeights.url(FMWeights.timestral123M) != nil else {
            print("g1-01: Timestral-123M weights not on this Mac, skipped")
            return
        }
        let fixture = try ArenaFixtures.model("fm-timestral-123m-meter")
        let cases = Dictionary(uniqueKeysWithValues: try ArenaFixtures.cases().cases.map { ($0.id, $0) })
        var worst = 0.0
        for out in fixture.outputs {
            let c = try #require(cases[out.case])
            let runner = ArenaRunner(registry: ArenaRegistry.all, services: TimestralTestWeights.services())
            let fc = try runner.forecast(model: Self.name, history: ArenaFixtures.history(c),
                                         request: ArenaFixtures.request(c))
            let tf = try #require(fc.byKey[c.request.key])
            let mi = try #require(out.levels.firstIndex(of: 0.5))
            let med = out.quantiles[mi]
            for (li, lv) in out.levels.enumerated() {
                let want = out.quantiles[li].indices.map { min(max(med[$0] + 0.6 * (out.quantiles[li][$0] - med[$0]), 0), 100) }
                let got = tf.quantile(lv)
                let d = zip(got, want).map { abs($0 - $1) }.max() ?? 0
                worst = max(worst, d)
                #expect(d < 0.02, "case \(out.case) level \(lv): \(d)")
            }
        }
        print("g1-01 against the Python child's quantiles through the map: max |Δ| \(worst)")
    }
}
