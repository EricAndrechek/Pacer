import Foundation
import Testing
@testable import PacerCore

/// The readings half of the Swift kit (`KitSpend` readings, cycles, the
/// ledger and intervals; `KitBaselines.meterNow`) against the port fixtures
/// and the Python's own invariants.
@Suite struct KitReadingsTests {
    static func allCases() throws -> [ArenaFixtures.Case] {
        try ArenaFixtures.cases().cases + ArenaFixtures.cases("cases-spend").cases
    }

    /// `current_cycle`'s reset is the one the request names, for every case.
    @Test func currentCycleIsTheRequests() throws {
        for c in try Self.allCases() {
            let h = ArenaFixtures.history(c)
            let cyc = try #require(KitSpend.currentCycle(h, account: c.inputs.account, windowKind: c.inputs.window_kind,
                                                        scopeModel: c.inputs.scope_model), "case \(c.id)")
            #expect(cyc.reset == c.request.reset_at, "case \(c.id)")
            #expect(cyc.start == cyc.reset - KitSpend.windowMs(c.inputs.window_kind))
            #expect(cyc.rows.allSatisfy { $0.tEvent <= h.now && $0.active }, "case \(c.id)")
            #expect(zip(cyc.rows, cyc.rows.dropFirst()).allSatisfy { $0.tEvent <= $1.tEvent })
        }
    }

    /// `meter_now` agrees with what the Python's spend-decay read
    /// (`detail.latest`, `latest_t`, `start`, `reset`).
    @Test func meterNowMatchesTheFixtures() throws {
        let cases = Dictionary(uniqueKeysWithValues: try ArenaFixtures.cases("cases-spend").cases.map { ($0.id, $0) })
        var checked = 0
        for name in ["spend-decay-30m", "spend-decay-6h"] {
            for o in try ArenaFixtures.model(name).outputs {
                let c = try #require(cases[o.case])
                let d = try #require(o.detail)
                let tr = ArenaFixtures.request(c).targets[0]
                let m = KitBaselines.meterNow(ArenaFixtures.history(c), tr)
                #expect(m.latest == d["latest"]?.number, "case \(o.case)")
                #expect(Double(m.latestT) == d["latest_t"]?.number, "case \(o.case)")
                #expect(Double(m.start) == d["start"]?.number, "case \(o.case)")
                #expect(Double(m.reset) == d["reset"]?.number, "case \(o.case)")
                checked += 1
            }
        }
        #expect(checked == 12)
    }

    /// Past cycles: reset by now, oldest first, start = reset − W, readings
    /// in time order, consecutive cycles at least half a window apart.
    @Test func pastCyclesHoldTheirInvariants() throws {
        var total = 0
        for c in try Self.allCases() {
            let h = ArenaFixtures.history(c)
            let w = KitSpend.windowMs(c.inputs.window_kind)
            let cycles = KitSpend.pastCycles(h, account: c.inputs.account, windowKind: c.inputs.window_kind,
                                             scopeModel: c.inputs.scope_model)
            total += cycles.count
            for p in cycles {
                #expect(p.reset <= h.now)
                #expect(p.start == p.reset - w)
                #expect(!p.t.isEmpty && p.t.count == p.util.count)
                #expect(zip(p.t, p.t.dropFirst()).allSatisfy { $0 <= $1 })
            }
            #expect(zip(cycles, cycles.dropFirst()).allSatisfy { Double($1.reset - $0.reset) >= Double(w) / 2 })
            // The cycle in progress is not a past one.
            #expect(cycles.allSatisfy { abs(Double($0.reset - c.request.reset_at)) >= Double(w) / 2 })
        }
        #expect(total > 50)
    }

    /// The run-merging grouping equals the Python's sort-everything one,
    /// on every fixture, a synthetic history, and resets that interleave,
    /// drift and tie in time.
    @Test func fastPastCyclesEqualTheSortedOnes() throws {
        func same(_ a: [KitSpend.PastCycle], _ b: [KitSpend.PastCycle]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { $0.reset == $1.reset && $0.t == $1.t && $0.util == $1.util }
        }
        var n = 0
        for c in try Self.allCases() {
            let h = ArenaFixtures.history(c)
            let r = KitSpend.meterSeries(h, account: c.inputs.account, windowKind: c.inputs.window_kind)
            #expect(same(KitSpend.pastCyclesFast(r, windowKind: c.inputs.window_kind, now: h.now),
                         KitSpend.pastCyclesBySort(r, windowKind: c.inputs.window_kind, now: h.now)), "case \(c.id)")
            n += 1
        }
        let (store, end) = SpendTimingTests.synthetic(days: 30)
        let h = ArenaHistory(store: store, now: end, accounts: ["S1"])
        for kind in ["five_hour", "seven_day"] {
            let r = KitSpend.meterSeries(h, account: "S1", windowKind: kind)
            #expect(same(KitSpend.pastCyclesFast(r, windowKind: kind, now: h.now),
                         KitSpend.pastCyclesBySort(r, windowKind: kind, now: h.now)), "synthetic \(kind)")
        }
        // Adversarial: two cycles' readings interleaved, a reset that drifts
        // a minute per reading (one chained group), equal times, odd and
        // even group sizes.
        var rng = ArenaRNG(seed: 3)
        let H = ArenaTime.hour
        var t: [Millis] = [], p: [Double] = [], reset: [Millis] = [], active: [Bool] = []
        for i in 0..<400 {
            let base: Millis = 1_780_000_000_000 + Millis(i / 3) * 60_000
            t.append(base); p.append(Double(i % 9))
            switch i % 4 {
            case 0: reset.append(1_780_000_000_000 + 5 * H + Millis(rng.uniform() * 900))
            case 1: reset.append(1_780_000_000_000 + 10 * H + Millis(rng.uniform() * 900))
            case 2: reset.append(1_780_000_000_000 + 20 * H + Millis(i) * 61_000)
            default: reset.append(1_780_000_000_000 + 5 * H + 2 * H + Millis(rng.uniform() * 3 * Double(H)))
            }
            active.append(i % 11 != 0)
        }
        let r = KitSpend.MeterSeries(t: t, p: p, reset: reset, active: active)
        let now: Millis = 1_780_000_000_000 + 100 * H
        let fast = KitSpend.pastCyclesFast(r, windowKind: "five_hour", now: now)
        #expect(same(fast, KitSpend.pastCyclesBySort(r, windowKind: "five_hour", now: now)))
        #expect(fast.count >= 2)
        #expect(n == 32)
    }

    @Test func selectMedianIsTheTruncatedMedian() {
        var rng = ArenaRNG(seed: 9)
        for n in [1, 2, 3, 4, 7, 10, 101, 1000] {
            var xs = (0..<n).map { _ in Millis(rng.uniform() * 1e6) + (rng.uniform() < 0.3 ? 0 : 1_780_000_000_000) }
            let want = KitSpend.truncatedMedian(xs)
            #expect(KitSpend.selectMedian(&xs) == want, "n \(n)")
        }
    }

    @Test func truncatedMedianIsNumpys() {
        #expect(KitSpend.truncatedMedian([5]) == 5)
        #expect(KitSpend.truncatedMedian([1, 4]) == 2)              // 2.5 → 2
        #expect(KitSpend.truncatedMedian([10, 3, 7]) == 7)
        #expect(KitSpend.truncatedMedian([1_780_000_000_001, 1_780_000_000_000]) == 1_780_000_000_000)
    }

    /// Intervals: within one cycle, under an hour, never falling, and their
    /// spend is the ledger's sum over (t0, t1].
    @Test func intervalsAndTheLedger() throws {
        for c in try ArenaFixtures.cases("cases-spend").cases {
            let h = ArenaFixtures.history(c)
            let iv = KitSpend.intervals(h, account: c.inputs.account, windowKind: c.inputs.window_kind)
            #expect(iv.count > 0, "case \(c.id)")
            let rows = h.spend(account: c.inputs.account)
            for i in stride(from: 0, to: iv.count, by: max(1, iv.count / 25)) {
                #expect(iv.t1[i] > iv.t0[i] && iv.t1[i] - iv.t0[i] < KitSpend.maxPairGapMs)
                #expect(iv.rise[i] >= 0)
                var direct = [Double](repeating: 0, count: 5)
                for r in rows where r.tEvent > iv.t0[i] && r.tEvent <= iv.t1[i] {
                    direct[KitSpend.familyIndex(r.family)] += r.costUSD ?? 0
                }
                for f in 0..<5 { #expect(abs(iv.spend(i, f) - direct[f]) < 1e-9, "case \(c.id) interval \(i)") }
            }
            #expect(zip(iv.t1, iv.t1.dropFirst()).allSatisfy { $0 <= $1 })
            // The whole history's spend, through the ledger.
            let total = KitSpend.spentBetween(h, account: c.inputs.account, Millis.min / 2, h.now).reduce(0, +)
            let direct = rows.reduce(0) { $0 + ($1.costUSD ?? 0) }
            #expect(abs(total - direct) < 1e-9 * max(1, direct))
        }
    }

    @Test func hourlySeriesSumsTheLastHours() throws {
        for c in try ArenaFixtures.cases("cases-spend").cases {
            let h = ArenaFixtures.history(c)
            let (ends, v) = KitSpend.hourlySeries(h, accounts: [c.inputs.account], hours: 48)
            #expect(ends.count == 48 && ends.last == h.now && ends[0] == h.now - 47 * ArenaTime.hour)
            let rows = h.spend(account: c.inputs.account)
            for (i, e) in ends.enumerated() {
                let direct = rows.filter { $0.tEvent > e - ArenaTime.hour && $0.tEvent <= e }.reduce(0) { $0 + ($1.costUSD ?? 0) }
                #expect(abs(v[i] - direct) < 1e-9)
            }
            let opus = KitSpend.hourlySeries(h, accounts: [c.inputs.account], hours: 48, family: "opus").values
            #expect(zip(opus, v).allSatisfy { $0 <= $1 + 1e-12 })
        }
    }

    @Test func localDayStartIsLocalMidnight() throws {
        for c in try ArenaFixtures.cases("cases-spend").cases {
            let h = ArenaFixtures.history(c)
            let off = KitSpend.tzOffsetMs(h)
            #expect(off == Millis(c.inputs.tz_offset_min ?? 0) * 60_000)
            let d = KitSpend.localDayStart(h)
            #expect(d <= h.now && h.now < d + ArenaTime.day)
            #expect((d + off) % ArenaTime.day == 0)
            #expect(KitSpend.localDayStart(h, at: d) == d)
            #expect(KitSpend.localDayStart(h, at: d - 1) == d - ArenaTime.day)
        }
        // Before the epoch, floor division (not truncation).
        #expect(KitSpend.floorDiv(-1, ArenaTime.day) == -1)
    }

    @Test func capFamilies() {
        #expect(KitSpend.capFamily("Fable") == "fable")
        #expect(KitSpend.capFamily(" Opus 4.7 ") == "opus")
        #expect(KitSpend.capFamily("Something") == nil)
        #expect(KitSpend.capFamily(nil) == nil)
        #expect(KitSpend.counted("Fable") == [true, false, false, false, false])
        #expect(KitSpend.counted(nil) == [true, true, true, true, true])
    }

    @Test func flatAndLinearBaselines() throws {
        for c in try Self.allCases() {
            let h = ArenaFixtures.history(c)
            let tr = ArenaFixtures.request(c).targets[0]
            let m = KitBaselines.meterNow(h, tr)
            let flat = KitBaselines.meterFlat(h, tr).median
            #expect(flat.count == tr.grid.count && flat.allSatisfy { $0 == m.latest })
            let lin = KitBaselines.meterLinear(h, tr).median
            #expect(zip(lin, lin.dropFirst()).allSatisfy { $0 <= $1 + 1e-12 })
            #expect(lin.allSatisfy { $0 >= m.latest && $0 <= max(100, m.latest) })
        }
        // An idle meter falls back on the request's reset, at 0 %.
        let c = try ArenaFixtures.cases().cases[0]
        let h = ArenaFixtures.history(c)
        var tr = ArenaFixtures.request(c).targets[0]
        tr.accounts = ["nobody"]
        let m = KitBaselines.meterNow(h, tr)
        #expect(m.reset == c.request.reset_at && m.latest == 0 && m.t.isEmpty)
        #expect(m.latestT == m.start)
    }

    /// Derived values are memoized per cut: a second call returns the same
    /// storage without re-deriving.
    @Test func memoizedPerCut() throws {
        let c = try ArenaFixtures.cases("cases-spend").cases[0]
        let h = ArenaFixtures.history(c)
        let a = KitSpend.pastCycles(h, account: c.inputs.account, windowKind: c.inputs.window_kind)
        let b = KitSpend.pastCycles(h, account: c.inputs.account, windowKind: c.inputs.window_kind)
        #expect(a.map(\.reset) == b.map(\.reset))
        let earlier = h.asOf(h.now - 2 * ArenaTime.day)
        let e = KitSpend.pastCycles(earlier, account: c.inputs.account, windowKind: c.inputs.window_kind)
        #expect(e.count < a.count)
        #expect(e.allSatisfy { $0.reset <= earlier.now })
    }
}
