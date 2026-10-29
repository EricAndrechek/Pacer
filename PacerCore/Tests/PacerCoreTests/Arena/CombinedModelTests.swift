import Foundation
import Testing
@testable import PacerCore

/// g1-08-opus-fm and g2-06-opus-fmgate2 as registered (no offline prior):
/// every meter target answers with sane paths, a scoped cap gates on its own
/// model family's turns, and a cancellation is never mistaken for a failure.
@Suite struct CombinedModelTests {
    static var weightsHere: Bool { TimestralTestWeights.url(FMWeights.timestral123M) != nil }

    @Test func registered() throws {
        for name in ["g1-08-opus-fm", "g2-06-opus-fmgate2"] {
            let s = try #require(ArenaRegistry.spec(name))
            #expect(s.targets == [.meterFiveHour, .meterSevenDay, .meterScoped])
            #expect(s.weights == [FMWeights.timestral123M])
            #expect(s.children.isEmpty)
            #expect(s.complexity == 5)
        }
        let g = ArenaRegistry.spec("g2-06-opus-fmgate2")!.config
        #expect(g.table("gate").table("five_hour").bool("on", false))
        #expect(!g.table("gate").table("seven_day").bool("on", true))
        #expect(g.table("gate").table("weekly_scoped").string("mode", "") == "cut")
        #expect(g.table("g108").table("meter") == ArenaRegistry.spec("g1-08-opus-fm")!.config.table("meter"))
        #expect(ArenaRegistry.spec("g1-08-opus-fm")!.config.table("meter")["prior"] == nil)
        #expect(Gate.capFamily("Fable") == "fable" && Gate.capFamily("Claude Opus 4.7") == "opus" && Gate.capFamily(nil) == nil)
    }

    static func check(_ tf: ArenaTargetForecast?, grid: Int, whole: Bool) throws {
        let p = try #require(tf?.paths)
        #expect(p.count == 200)
        for row in p {
            #expect(row.count == grid)
            #expect(row.allSatisfy { $0 >= 0 && $0 <= 100 && $0.isFinite })
            if whole { #expect(row.allSatisfy { $0 == $0.rounded() }) }
        }
    }

    @Test func fiveHourAndWeeklyAsRegistered() throws {
        guard Self.weightsHere else { return }
        let cases = try ArenaFixtures.cases("cases-spend").cases.filter { ["s04", "s05"].contains($0.id) }
        let runner = ArenaRunner(registry: ArenaRegistry.all, services: TimestralTestWeights.services())
        for c in cases {
            for name in ["g1-08-opus-fm", "g2-06-opus-fmgate2"] {
                let fc = try runner.forecast(model: name, history: ArenaFixtures.history(c), request: ArenaFixtures.request(c))
                try Self.check(fc.byKey[c.request.key], grid: c.request.grid.count, whole: name.hasPrefix("g2-06"))
                let med = fc.byKey[c.request.key]!.median
                // Never below the meter now, never falling.
                #expect(zip(med, med.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 }, "\(name) \(c.id)")
            }
        }
    }

    /// A weekly case relabelled as a scoped cap ("Fable"), its turns split
    /// between two families: g2-06 gates the scoped meter on the cap's own
    /// family's turns only.
    @Test func scopedCap() throws {
        guard Self.weightsHere else { return }
        let c = try #require(try ArenaFixtures.cases("cases-spend").cases.first { $0.id == "s03" })
        let base = ArenaFixtures.history(c)
        let acct = c.inputs.account
        let readings = base.readings(account: acct, windowKind: "seven_day")
        let spend = base.spend(account: acct).enumerated().map { i, r in
            ArenaSpendRow(tEvent: r.tEvent, tKnown: r.tKnown, family: i % 3 == 0 ? "fable" : "opus", costUSD: r.costUSD)
        }
        let id = ArenaMeterID(account: acct, windowKind: "weekly_scoped", scopeModel: "Fable")
        let store = ArenaHistoryStore(meters: [id: readings], spend: [acct: spend], tzOffsetMin: c.inputs.tz_offset_min,
                                      dataStart: c.inputs.history_start)
        let h = ArenaHistory(store: store, now: c.request.now, accounts: [acct])
        let req = ArenaRunner.request(history: h, targets: [.meterScoped])
        let tr = try #require(req.targets.first)
        #expect(tr.cap == "Fable" && tr.key == "meter.scoped:\(acct):Fable")
        let runner = ArenaRunner(registry: ArenaRegistry.all, services: TimestralTestWeights.services())
        for name in ["g1-08-opus-fm", "g2-06-opus-fmgate2"] {
            let fc = try runner.forecast(model: name, history: h, request: req)
            try Self.check(fc.byKey[tr.key], grid: tr.grid.count, whole: name.hasPrefix("g2-06"))
        }
        let book = Gate.TurnBook(h)
        #expect(book.times(acct, family: "fable").count == spend.filter { $0.family == "fable" }.count)
        #expect(book.times(acct).count == spend.count)
    }

    final class Countdown: @unchecked Sendable {
        let lock = NSLock()
        var left: Int
        init(_ n: Int) { left = n }
        func tick() -> Bool { lock.lock(); defer { lock.unlock() }; left -= 1; return left < 0 }
    }

    /// Cancelled in the middle of a self-backtest: both models throw
    /// `cancelled` (g2-06 must not fall back to the flat meter).
    @Test func cancellationPropagates() throws {
        guard Self.weightsHere else { return }
        let c = try #require(try ArenaFixtures.cases("cases-spend").cases.first { $0.id == "s01" })
        for name in ["g1-08-opus-fm", "g2-06-opus-fmgate2"] {
            let countdown = Countdown(3)
            let services = ArenaServices(weights: { TimestralTestWeights.url($0) }, isCancelled: { countdown.tick() })
            let runner = ArenaRunner(registry: ArenaRegistry.all, services: services)
            #expect(throws: ArenaError.cancelled) {
                // A fresh history (no memo), and a long weekly backtest to cancel.
                let h = ArenaFixtures.history(c)
                let ctx = ArenaContext(spec: ArenaRegistry.spec(name)!, seed: 1, services: services, runner: runner,
                                       history: { h })
                let m: any ArenaModel = name.hasPrefix("g1-08") ? try G108OpusFM(context: ctx) : try G206OpusFMGate2(context: ctx)
                if let g = m as? G108OpusFM { g.meters.cutCache = FMCalCutCache(capacity: 64) }
                if let g = m as? G206OpusFMGate2 { g.fm.cutCache = FMCalCutCache(capacity: 64) }
                try m.fit(h)
                _ = try m.forecast(ArenaFixtures.request(c))
            }
        }
    }
}
