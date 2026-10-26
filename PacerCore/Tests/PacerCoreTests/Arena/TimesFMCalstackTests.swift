import Foundation
import Testing
@testable import PacerCore

/// g1-01-sonnet-calstack: a CRPS stack of g1-01-sonnet-calibrate123 and
/// fm-timesfm25-meter over their backtests (`kit/ml/combine.Combiner`, rule
/// "stack", mixture pool). On stub children first (the registered spec, its
/// children replaced by deterministic models named as they are), then on
/// its real children on the 120-day synthetic history when both networks'
/// weights are on this Mac.
@Suite struct TimesFMCalstackTests {
    static let name = "g1-01-sonnet-calstack"

    /// The meter now plus `rate` points per hour, a ±`spread` band.
    final class Stub: ArenaModel {
        let rate: Double, spread: Double, fails: Bool
        var history: ArenaHistory?
        init(context: ArenaContext) {
            rate = context.config.double("rate", 1)
            spread = context.config.double("spread", 2)
            fails = context.config.bool("fails", false)
        }
        func fit(_ history: ArenaHistory) { self.history = history }
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
            if fails { throw ArenaError.invalid("stub failure") }
            var out: [String: ArenaTargetForecast] = [:]
            for tr in request.targets {
                let rows = history?.readings(tr.meter) ?? []
                let now = rows.last?.utilPct ?? 0
                let med = tr.grid.map { min(100, now + rate * Double($0 - request.now) / Double(ArenaTime.hour)) }
                out[tr.key] = ArenaTargetForecast(levels: [0.1, 0.5, 0.9], quantiles: [
                    med.map { max(now, $0 - spread) }, med, med.map { min(100, $0 + spread) },
                ])
            }
            return ArenaForecast(byKey: out)
        }
    }

    static func stubRunner(_ a: ArenaConfig, _ b: ArenaConfig, shrink: Double? = nil) throws -> ArenaRunner {
        var spec = try #require(ArenaRegistry.spec(name))
        spec.weights = []
        if let shrink { spec.config.values["shrink"] = .double(shrink) }
        let stubs = zip(spec.children, [a, b]).map { child, cfg in
            ArenaModelSpec(name: child, targets: spec.targets, config: cfg) { Stub(context: $0) }
        }
        return ArenaRunner(registry: [spec] + stubs)
    }

    @Test func registeredAsTheModelTomlSays() throws {
        let spec = try #require(ArenaRegistry.spec(Self.name))
        #expect(spec.children == ["g1-01-sonnet-calibrate123", "fm-timesfm25-meter"])
        #expect(spec.targets == [.meterFiveHour, .meterSevenDay, .meterScoped])
        #expect(spec.config.string("pool", "") == "mixture")
        #expect(spec.config.double("shrink", 0) == 0.15)
        #expect(spec.config.int("half_life_n", 0) == 24)
        #expect(spec.config.int("backtest_n", 0) == 4)
        #expect(spec.config.int("max_evals", 0) == 16)
        #expect(spec.config.table("backtest_every_h").int("five_hour", 0) == 3)
        #expect(spec.config.table("backtest_every_h").int("seven_day", 0) == 12)
        #expect(CalstackModel.rule == "stack" && CalstackModel.defaultPool == "mixture")
    }

    /// The 120-day synthetic history, cut where the five-hour meter is live.
    static func liveCut(_ store: ArenaHistoryStore, target: ArenaTarget) -> (ArenaHistory, ArenaRequest)? {
        let last = store.meters.values.compactMap { $0.last?.tEvent }.max()!
        for i in 0..<200 {
            let now = last - Millis(i) * 37 * ArenaTime.minute
            let h = ArenaHistory(store: store, now: now, accounts: ["A1"])
            let req = ArenaRunner.request(history: h, targets: [target])
            if !req.targets.isEmpty { return (h, req) }
        }
        return nil
    }

    @Test func stacksItsChildrenFromTheirBacktests() throws {
        let store = TimestralSyntheticHistory.store(days: 30)
        for target in [ArenaTarget.meterFiveHour, .meterSevenDay] {
            let (h, req) = try #require(Self.liveCut(store, target: target))
            let runner = try Self.stubRunner(["rate": 1.0, "spread": 2.0], ["rate": 6.0, "spread": 8.0])
            let fc = try runner.forecast(model: Self.name, history: h, request: req)
            let tf = try #require(fc.byKey[req.targets[0].key])
            let paths = try #require(tf.paths)
            #expect(paths.count == req.targets[0].nPaths)
            #expect(paths.allSatisfy { $0.allSatisfy { $0 >= 0 && $0 <= 100 } })
            // A mixture of the two: its median lies between theirs (up to
            // the pool's sampling of 200 paths).
            let kids = try ["g1-01-sonnet-calibrate123", "fm-timesfm25-meter"].map {
                try #require(runner.forecast(model: $0, history: h, request: req).byKey[req.targets[0].key]).median
            }
            let med = tf.median
            for j in med.indices {
                let lo = min(kids[0][j], kids[1][j]), hi = max(kids[0][j], kids[1][j])
                #expect(med[j] >= lo - 1 && med[j] <= hi + 1, "\(target) grid \(j): \(med[j]) not in [\(lo), \(hi)]")
            }
            // The weights it learned from the stubs' backtests: a simplex point.
            let w = try #require(try Self.lastWeights(runner, h, req))
            #expect(abs(w.values.reduce(0, +) - 1) < 1e-9 && w.values.allSatisfy { $0 >= 0 })
            print("\(Self.name) on stubs, \(target): weights \(w.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.3f", $0.value))" })")
        }
    }

    /// The model itself, built and run the way the runner does, for its weights.
    static func lastWeights(_ runner: ArenaRunner, _ h: ArenaHistory, _ req: ArenaRequest) throws -> [String: Double]? {
        let spec = try #require(runner.registry[name])
        let ctx = ArenaContext(spec: spec, seed: 42, services: runner.services, runner: runner, history: { h })
        let m = try CalstackModel(context: ctx)
        try m.fit(h)
        _ = try m.forecast(req)
        return m.lastWeights[req.targets[0].key]
    }

    @Test func aFailingChildLeavesTheOther() throws {
        let store = TimestralSyntheticHistory.store(days: 30)
        let (h, req) = try #require(Self.liveCut(store, target: .meterFiveHour))
        let runner = try Self.stubRunner(["fails": true], ["rate": 2.0, "spread": 1.0])
        let fc = try runner.forecast(model: Self.name, history: h, request: req)
        let tf = try #require(fc.byKey[req.targets[0].key])
        let only = try #require(runner.forecast(model: "fm-timesfm25-meter", history: h, request: req)
            .byKey[req.targets[0].key])
        for (a, b) in zip(tf.median, only.median) { #expect(abs(a - b) <= 0.5) }
    }

    /// The real children: Timestral-123M (through calibrate123's map) and
    /// TimesFM 2.5, on the synthetic history; weights learned from the
    /// backtests, timed.
    @Test func runsOnItsRealChildren() throws {
        guard let tfm = TimestralTestWeights.url(FMWeights.timesfm25),
              TimestralTestWeights.url(FMWeights.timestral123M) != nil else {
            print("\(Self.name): TimesFM or Timestral-123M weights not on this Mac, skipped"); return
        }
        let store = TimestralSyntheticHistory.store(days: 30)
        var lines: [String] = []
        for target in [ArenaTarget.meterFiveHour, .meterSevenDay] {
            let (h, req) = try #require(Self.liveCut(store, target: target))
            let runner = ArenaRunner(registry: ArenaRegistry.all, services: ArenaServices(weights: {
                $0 == FMWeights.timesfm25 ? tfm : TimestralTestWeights.url($0)
            }))
            let t0 = DispatchTime.now().uptimeNanoseconds
            let fc = try runner.forecast(model: Self.name, history: h, request: req)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            let tf = try #require(fc.byKey[req.targets[0].key])
            #expect(tf.paths?.allSatisfy { $0.allSatisfy { $0 >= 0 && $0 <= 100 } } == true)
            lines.append(String(format: "%@: %.0f ms with its backtests, median at reset %.2f", target.rawValue, ms,
                                tf.median.last ?? .nan))
        }
        print("\(Self.name) on its real children\n" + lines.joined(separator: "\n"))
    }
}
