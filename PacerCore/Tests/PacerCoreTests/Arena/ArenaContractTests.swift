import Foundation
import Testing
@testable import PacerCore

/// The contract's own behaviour: the fixtures decode, the runner's grid and
/// cycle rules match the arena's, and a parent reaches its children (and
/// their backtests) only through the runner, with the parent's view.
@Suite struct ArenaContractTests {
    @Test func fixturesDecode() throws {
        let cases = try ArenaFixtures.cases()
        #expect(cases.format == "pacer-arena-port-fixture/1")
        #expect(cases.cases.count == 20)
        let spend = try ArenaFixtures.cases("cases-spend")
        #expect(spend.cases.allSatisfy { $0.inputs.turns != nil })
        let analog = try ArenaFixtures.model("g1-10-fable-analog")
        #expect(analog.outputs.count == 20)
        #expect(analog.outputs[0].quantiles.count == analog.outputs[0].levels.count)
    }

    /// The fixture grids are the runner's for five-hour cases (weekly ones
    /// are coarsened to 2 h in the files, so only the head and the end match).
    @Test func gridMatchesTheRunner() throws {
        for c in try ArenaFixtures.cases().cases {
            let target = ArenaTarget(rawValue: c.request.target)!
            let g = try #require(ArenaRunner.grid(target: target, now: c.request.now, resetAt: c.request.reset_at))
            #expect(g.last == c.request.reset_at)
            if target == .meterFiveHour { #expect(g == c.request.grid, "case \(c.id)") }
            else { #expect(Array(g.prefix(3)) == Array(c.request.grid.prefix(3)), "case \(c.id)") }
        }
    }

    /// The cycle known at a case's `now` is the one its request names.
    @Test func cycleAtFindsTheRequestedReset() throws {
        for c in try ArenaFixtures.cases().cases {
            let h = ArenaFixtures.history(c)
            let meter = ArenaMeterID(account: c.inputs.account, windowKind: c.inputs.window_kind,
                                     scopeModel: c.inputs.scope_model)
            let cycle = try #require(ArenaRunner.cycleAt(h.readings(meter), now: h.now), "case \(c.id)")
            #expect(cycle.resetAt == c.request.reset_at, "case \(c.id)")
        }
    }

    @Test func historyCutsNeverLeak() throws {
        let c = try ArenaFixtures.cases().cases[0]
        let h = ArenaFixtures.history(c)
        let meter = ArenaMeterID(account: c.inputs.account, windowKind: c.inputs.window_kind)
        let all = h.readings(meter)
        let mid = all[all.count / 2].tEvent
        let cut = h.asOf(mid)
        #expect(cut.readings(meter).allSatisfy { $0.tKnown <= mid })
        #expect(cut.readings(meter).count < all.count)
    }

    // A parent that forecasts its child's median plus one, and records what
    // its child's backtest returned.
    final class Flat: ArenaModel {
        var last: Double = 0
        init(context: ArenaContext) {}
        func fit(_ history: ArenaHistory) {
            last = history.readings(history.meters(account: history.accounts[0])[0]).last?.utilPct ?? 0
        }
        func forecast(_ request: ArenaRequest) -> ArenaForecast {
            ArenaForecast(byKey: Dictionary(uniqueKeysWithValues: request.targets.map {
                ($0.key, ArenaTargetForecast.point(Array(repeating: last, count: $0.grid.count)))
            }))
        }
    }

    final class PlusOne: ArenaModel {
        let ctx: ArenaContext
        nonisolated(unsafe) static var backtestCount = 0
        init(context: ArenaContext) { ctx = context }
        func fit(_ history: ArenaHistory) {}
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
            let child = try ctx.model("flat").forecast(request)
            Self.backtestCount = try ctx.backtest("flat", every: ArenaTime.hour, targets: [.meterFiveHour]).count
            return ArenaForecast(byKey: child.byKey.mapValues { .point($0.median.map { $0 + 1 }) })
        }
    }

    @Test func parentReachesItsChildThroughTheRunner() throws {
        let c = try #require(try ArenaFixtures.cases().cases.first { $0.request.target == "meter.five_hour" })
        let runner = ArenaRunner(registry: [
            ArenaModelSpec(name: "flat", targets: [.meterFiveHour]) { Flat(context: $0) },
            ArenaModelSpec(name: "plus-one", targets: [.meterFiveHour], children: ["flat"]) { PlusOne(context: $0) },
        ])
        let h = ArenaFixtures.history(c)
        let fc = try runner.forecast(model: "plus-one", history: h, request: ArenaFixtures.request(c))
        let last = h.readings(account: c.inputs.account, windowKind: c.inputs.window_kind).last?.utilPct ?? 0
        let median = try #require(fc.byKey[c.request.key]?.median)
        #expect(median.allSatisfy { $0 == last + 1 })
        #expect(PlusOne.backtestCount > 0)
        #expect(PlusOne.backtestCount <= runner.maxBacktestPoints)
        // An undeclared child is refused.
        let ctx = ArenaContext(spec: runner.registry["flat"]!, seed: 1, services: ArenaServices(), runner: runner,
                               history: { h })
        #expect(throws: ArenaError.notDeclaredChild("plus-one")) { try ctx.model("plus-one") }
    }

    @Test func quantilesInterpolateBetweenLevels() {
        let f = ArenaTargetForecast(levels: [0.1, 0.5, 0.9], quantiles: [[0, 10], [1, 20], [2, 30]])
        #expect(f.median == [1, 20])
        #expect(zip(f.quantile(0.3), [0.5, 15]).allSatisfy { abs($0 - $1) < 1e-12 })
        #expect(f.quantile(0.01) == [0, 10])
        var rng = ArenaRNG(seed: 7)
        let paths = f.samplePaths(50, rng: &rng)
        #expect(paths.count == 50)
        #expect(paths.allSatisfy { $0[0] >= 0 && $0[0] <= 2 && $0[1] >= 10 && $0[1] <= 30 })
    }
}

@Suite struct ArenaContractMemoTests {
    @Test func optionalValuesAreComputedOnce() {
        let memo = ArenaMemo()
        var calls = 0
        let a: Int? = memo.value("k") { calls += 1; return nil }
        let b: Int? = memo.value("k") { calls += 1; return 5 }
        #expect(a == nil && b == nil && calls == 1)
        let c: Int? = memo.value("j") { 3 }
        #expect(c == 3)
    }

    final class Stub: ArenaModel {
        init(context: ArenaContext) {}
        func fit(_ history: ArenaHistory) {}
        func forecast(_ request: ArenaRequest) -> ArenaForecast { ArenaForecast(byKey: [:]) }
    }

    @Test func aParentNeedsItsChildrensWeights() throws {
        let c = try ArenaFixtures.cases().cases[0]
        let runner = ArenaRunner(registry: [
            ArenaModelSpec(name: "net", targets: [.meterFiveHour], weights: ["org/net@1"]) { Stub(context: $0) },
            ArenaModelSpec(name: "pool", targets: [.meterFiveHour], children: ["net"]) { Stub(context: $0) },
        ], services: ArenaServices(weights: { _ in nil }))
        #expect(runner.requiredWeights("pool") == ["org/net@1"])
        #expect(throws: ArenaError.weightsUnavailable("org/net@1")) {
            try runner.forecast(model: "pool", history: ArenaFixtures.history(c), request: ArenaFixtures.request(c))
        }
    }
}
