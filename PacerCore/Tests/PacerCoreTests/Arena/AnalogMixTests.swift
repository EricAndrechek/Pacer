import Foundation
import Testing
@testable import PacerCore

/// `g1-10-fable-mix` with its real analog child and stand-ins for the two
/// children other ports provide, registered under their names: the shares,
/// the rounding, the draw without replacement, the fallback to whoever
/// answered, and the clip.
@Suite struct AnalogMixTests {
    static let mix = "g1-10-fable-mix"
    static let analog = "g1-10-fable-analog"

    /// A point forecast at `value` (`port-engine-recent-rate`'s stand-in).
    final class PointChild: ArenaModel {
        let value: Double
        init(context: ArenaContext) { value = context.config.double("value", 0) }
        func fit(_ history: ArenaHistory) {}
        func forecast(_ request: ArenaRequest) -> ArenaForecast {
            ArenaForecast(byKey: Dictionary(uniqueKeysWithValues: request.targets.map {
                ($0.key, ArenaTargetForecast.point(Array(repeating: value, count: $0.grid.count)))
            }))
        }
    }

    /// `nPaths` distinct flat paths `value + i / 1000` (`spend-decay-1d`'s stand-in).
    final class PathsChild: ArenaModel {
        let value: Double
        init(context: ArenaContext) { value = context.config.double("value", 0) }
        func fit(_ history: ArenaHistory) {}
        func forecast(_ request: ArenaRequest) -> ArenaForecast {
            ArenaForecast(byKey: Dictionary(uniqueKeysWithValues: request.targets.map { tr in
                (tr.key, ArenaTargetForecast(paths: (0..<tr.nPaths).map { i in
                    Array(repeating: value + Double(i) / 1000, count: tr.grid.count)
                }))
            }))
        }
    }

    static func registry(recentRate: Double? = 33.3, spendDecay: Double? = 66.6) -> [ArenaModelSpec] {
        var r = [ArenaRegistry.fableAnalog, ArenaRegistry.fableMix]
        if let recentRate {
            r.append(ArenaModelSpec(name: "port-engine-recent-rate", targets: [.meterFiveHour, .meterSevenDay],
                                    config: ["value": .double(recentRate)]) { PointChild(context: $0) })
        }
        if let spendDecay {
            r.append(ArenaModelSpec(name: "spend-decay-1d", targets: [.meterSevenDay, .meterScoped],
                                    config: ["value": .double(spendDecay)]) { PathsChild(context: $0) })
        }
        return r
    }

    static func fixture(_ kind: String) throws -> (ArenaHistory, ArenaRequest, String) {
        let c = try #require(try ArenaFixtures.cases().cases.first { $0.inputs.window_kind == kind })
        return (ArenaFixtures.history(c), ArenaFixtures.request(c), c.request.key)
    }

    /// Five-hour: 70 % analog (its exact quantiles at 140 even levels), 30 %
    /// the point child, 200 paths.
    @Test func fiveHourPoolsSeventyThirty() throws {
        let (h, req, key) = try Self.fixture("five_hour")
        let runner = ArenaRunner(registry: Self.registry())
        let fc = try #require(try runner.forecast(model: Self.mix, history: h, request: req).byKey[key])
        let paths = try #require(fc.paths)
        #expect(paths.count == 200)
        let a = try #require(try runner.forecast(model: Self.analog, history: h, request: req).byKey[key])
        for j in 0..<req.targets[0].grid.count {
            let col = paths.map { $0[j] }
            #expect(col.filter { $0 == 33.3 }.count == 60, "grid \(j)")
            let analogPart = col.filter { $0 != 33.3 }
            let want = (0..<140).map { a.quantile((Double($0) + 0.5) / 140)[j] }
            #expect(analogPart == want, "grid \(j)")
        }
    }

    /// Weekly: half the analog's own simulated paths, half the paths child's,
    /// each drawn without replacement.
    @Test func weeklyPoolsHalfAndHalfWithoutReplacement() throws {
        let (h, req, key) = try Self.fixture("seven_day")
        let runner = ArenaRunner(registry: Self.registry())
        let fc = try #require(try runner.forecast(model: Self.mix, history: h, request: req).byKey[key])
        let paths = try #require(fc.paths)
        #expect(paths.count == 200)
        let analogPaths = try #require(try runner.forecast(model: Self.analog, history: h, request: req).byKey[key]?.paths)
        let fromChild = paths.filter { $0[0] >= 66.6 && $0[0] < 66.6 + 0.2 + 1e-9 && $0[0] != $0[0].rounded() }
        #expect(fromChild.count == 100)
        #expect(Set(fromChild.map { $0[0] }).count == 100, "drawn without replacement")
        let fromAnalog = paths.filter { p in !fromChild.contains(p) }
        #expect(fromAnalog.count == 100)
        #expect(fromAnalog.allSatisfy { p in analogPaths.contains(p) })
    }

    /// A child that is not there (not ported yet, or failed) drops out of
    /// the shares; the rest are renormalized.
    @Test func missingChildrenRenormalize() throws {
        let (h, req, key) = try Self.fixture("five_hour")
        let runner = ArenaRunner(registry: Self.registry(recentRate: nil, spendDecay: nil))
        let fc = try #require(try runner.forecast(model: Self.mix, history: h, request: req).byKey[key])
        let paths = try #require(fc.paths)
        #expect(paths.count == 200)
        let a = try #require(try runner.forecast(model: Self.analog, history: h, request: req).byKey[key])
        for j in [0, req.targets[0].grid.count - 1] {
            #expect(paths.map { $0[j] } == (0..<200).map { a.quantile((Double($0) + 0.5) / 200)[j] })
        }
    }

    /// Meter paths stay within [0, 100].
    @Test func pooledPathsAreClipped() throws {
        let (h, req, key) = try Self.fixture("five_hour")
        let runner = ArenaRunner(registry: Self.registry(recentRate: 150))
        let paths = try #require(try runner.forecast(model: Self.mix, history: h, request: req).byKey[key]?.paths)
        #expect(paths.allSatisfy { $0.allSatisfy { $0 >= 0 && $0 <= 100 } })
        #expect(paths.filter { $0[0] == 100 }.count >= 60)
    }
}
