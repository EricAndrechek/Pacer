import Foundation
import Testing
@testable import PacerCore

/// `kit/fm/series.py` and `kit/fm/paths.py`: the context the Timestral
/// fixture recorded (`detail.context`, `detail.used`) is rebuilt from each
/// case's readings, and the path helpers behave as numpy/scipy do.
@Suite struct FMSeriesTests {
    static func stepMs(_ wk: String) -> Millis { (wk == "five_hour" ? 5 : 15) * FMSeries.minMs }
    static func contextSteps(_ wk: String) -> Int { wk == "five_hour" ? 144 : 288 }

    @Test func contextMatchesTheFixture() throws {
        let cases = try ArenaFixtures.cases().cases
        let fm = try ArenaFixtures.model("fm-timestral-5m-meter")
        var checked = 0
        for out in fm.outputs {
            let c = try #require(cases.first { $0.id == out.case })
            let h = ArenaFixtures.history(c)
            let wk = c.inputs.window_kind
            let s = FMSeries.meterSeries(h, account: c.inputs.account, windowKind: wk,
                                         scopeModel: c.inputs.scope_model, now: c.request.now)
            let used = s.usedNow(c.request.reset_at) ?? s.lastActiveUtil ?? 0
            let detail = try #require(out.detail)
            #expect(abs(used - (detail["used"]?.number ?? .nan)) < 1e-6, "case \(c.id) used")
            let grid = FMSeries.regularGrid(now: c.request.now, stepMs: Self.stepMs(wk), n: Self.contextSteps(wk))
            let ctx = FMSeries.resampleLast(times: s.times, values: s.cum, grid: grid)
            let want = try #require(detail["context"]?.numbers)
            #expect(ctx.count == want.count)
            for (i, (a, b)) in zip(ctx, want).enumerated() {
                if let b { #expect(abs(a - b) < 1e-6, "case \(c.id) context[\(i)]: \(a) vs \(b)") }
                else { #expect(a.isNaN, "case \(c.id) context[\(i)] should be NaN, got \(a)") }
            }
            checked += 1
        }
        #expect(checked == 20)
    }

    @Test func cumulativeBurnAcrossCyclesAndRebases() {
        let h = FMSeries.hourMs
        func r(_ t: Millis, _ u: Double?, _ reset: Millis?, _ active: Bool = true) -> ArenaReading {
            ArenaReading(tEvent: t, tKnown: t, utilPct: u, resetsAt: reset, active: active)
        }
        let rows = [
            r(0, 10, 5 * h), r(h, 30, 5 * h),          // cycle 1: 10, +20
            r(2 * h, 0, nil, false),                   // idle: adds 0
            r(3 * h, 25, 5 * h),                       // same reset, a fall: adds 0
            r(4 * h, 40, 5 * h),                       // +15 from the lower value
            r(4 * h + 1, nil, 5 * h),                  // unknown util: dropped
            r(6 * h, 7, 10 * h),                       // new cycle: whole value
        ]
        let s = FMSeries.meterSeries(rows, windowKind: "five_hour")
        #expect(s.count == 6)
        #expect(s.cum == [10, 30, 30, 30, 45, 52])
        #expect(s.usedNow(5 * h) == 40)
        #expect(s.usedNow(10 * h) == 7)
        #expect(s.usedNow(20 * h) == nil)
        #expect(FMSeries.meterSeries(rows, windowKind: "five_hour", now: 3 * h).count == 4)
    }

    @Test func resampleAndGrid() {
        let g = FMSeries.regularGrid(now: 100, stepMs: 10, n: 4)
        #expect(g == [70, 80, 90, 100])
        let v = FMSeries.resampleLast(times: [65, 90], values: [1, 2], grid: g, staleMs: 10)
        #expect(v[0] == 1 && v[1].isNaN && v[2] == 2 && v[3] == 2)
        #expect(FMSeries.fillGaps([.nan, 1, .nan, 3, .nan]) == [1, 1, 2, 3, 3])
        #expect(FMSeries.fillGaps([.nan, .nan]) == [0, 0])
        #expect(FMSeries.hourBins([-1, 0, 1, 3_600_000], now: 3_600_000, hours: 2) == [0, 0, 1, 1])
        #expect(FMSeries.hourBins([-3_600_000, 3_600_001], now: 3_600_000, hours: 2) == [-1, -1])
    }

    @Test func calendarIsLocalTime() {
        // 1970-01-05 00:30 UTC is a Monday; at UTC+60 min the hour's middle is 01:00.
        let end = 4 * FMSeries.dayMs + FMSeries.hourMs
        let c = FMSeries.calendar([end], tzOffsetMin: 0)
        let hod = (0.5 / 24)
        #expect(abs(c[0][0] - sin(2 * .pi * hod)) < 1e-12)
        #expect(abs(c[2][0] - sin(2 * .pi * (hod / 7))) < 1e-12)
    }

    @Test func normalQuantilesMatchScipy() {
        #expect(abs(FMPaths.ndtri(0.975) - 1.959963984540054) < 1e-14)
        #expect(abs(FMPaths.ndtri(0.01) + 2.3263478740408408) < 1e-14)
        #expect(abs(FMPaths.ndtri(1e-10) + 6.361340902404056) < 1e-12)
        #expect(abs(FMPaths.ndtr(1.959963984540054) - 0.975) < 1e-14)
    }

    @Test func tailsExtendOnlyOutward() {
        let (lv, q) = FMPaths.extendTails([0.1, 0.5, 0.9], [[1, 2, 3], [5, 5, 5]])
        #expect(lv == [0.01, 0.1, 0.5, 0.9, 0.99])
        let slope = 1.0 / (FMPaths.ndtri(0.5) - FMPaths.ndtri(0.1))
        #expect(abs(q[0][0] - (1 - slope * (FMPaths.ndtri(0.1) - FMPaths.ndtri(0.01)))) < 1e-12)
        #expect(q[1] == [5, 5, 5, 5, 5])
        // Levels already at 1 % and 99 %: nothing added.
        #expect(FMPaths.extendTails([0.01, 0.5, 0.99], [[1, 2, 3]]).levels.count == 3)
    }

    @Test func burnAndMeterClipping() {
        let b = FMPaths.burnQuantiles([[9, 11], [12, 10], [11, 13]], cLast: 10)
        #expect(b == [[0, 1], [1, 2], [2, 3]])
        #expect(FMPaths.monotoneMeter([[5, 3, 120, 50]], floor: 4) == [[5, 5, 100, 100]])
        #expect(FMPaths.isotonic([1, 3, 2, 4]) == [1, 2.5, 2.5, 4])
        let t = FMPaths.interpTimes([0, 10], [-1, 5, 20], [[0, 10], [10, 30]])
        #expect(t == [[0, 10], [5, 20], [10, 30]])
    }

    @Test func comonotonePathsReadOneLevelEverywhere() {
        var rng = ArenaRNG(seed: 3)
        let p = FMPaths.toPaths([0.01, 0.5, 0.99], [[0, 1, 2], [10, 11, 12]], nPaths: 4, rng: &rng)
        #expect(p.count == 4)
        for row in p { #expect(abs((row[1] - row[0]) - 10) < 1e-12) }
        let us = FMPaths.uniforms(5, 3, .ar1, rho: 0.8, rng: &rng)
        #expect(us.allSatisfy { $0.count == 3 && $0.allSatisfy { $0 > 0 && $0 < 1 } })
    }
}

/// The shared store series: every cut's prefix of it is exactly the series
/// built from the cut's own rows (a 30-day synthetic history, cuts every
/// few hours, including one whose `now` argument is before the cut's).
@Suite struct FMStoreSeriesTests {
    @Test func prefixEqualsTheCutsOwnSeries() {
        let store = TimestralSyntheticHistory.store(days: 30, seed: 5)
        let last = store.meters.values.compactMap { $0.last?.tEvent }.max()!
        for wk in ["five_hour", "seven_day"] {
            for i in 0..<40 {
                let now = last - Millis(i) * 17 * ArenaTime.hour - 13 * ArenaTime.minute
                let h = ArenaHistory(store: store, now: now, accounts: ["A1"])
                for arg in [now, now - 3 * ArenaTime.day] {
                    let (s, k) = FMSeries.meterSeriesPrefix(h, account: "A1", windowKind: wk, now: arg)
                    let own = FMSeries.meterSeries(h.readings(account: "A1", windowKind: wk), windowKind: wk, now: arg)
                    #expect(k == own.count, "\(wk) cut \(i)")
                    #expect(Array(s.times.prefix(k)) == own.times && Array(s.cum.prefix(k)) == own.cum, "\(wk) cut \(i)")
                    #expect(Array(s.cycleUtil.prefix(k)) == own.cycleUtil && Array(s.active.prefix(k)) == own.active)
                }
            }
        }
        // A cut that does not see the account sees nothing.
        let h = ArenaHistory(store: store, now: last, accounts: ["B"])
        #expect(FMSeries.meterSeriesPrefix(h, account: "A1", windowKind: "five_hour").count == 0)
    }
}
