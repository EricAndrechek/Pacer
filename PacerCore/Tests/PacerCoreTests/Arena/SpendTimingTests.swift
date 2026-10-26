import Foundation
import Testing
@testable import PacerCore

/// Per-forecast wall time of spend-decay and its calibration wrapper, on a
/// fixture case and on a synthetic 120-day history (one account, a burst of
/// use most days, readings every two minutes while a window runs, spend in
/// five-minute per-family buckets as the app hands it over). Printed for the
/// report; the bounds only catch a blow-up (debug builds are ~10× slower).
@Suite(.serialized) struct SpendTimingTests {
    /// A deterministic synthetic history: no real usage in it.
    static func synthetic(days: Int = 120, tzMin: Int = -240, scoped: Bool = false) -> (ArenaHistoryStore, Millis) {
        var rng = ArenaRNG(seed: 20261026)
        let t0: Millis = 1_780_000_000_000 - (1_780_000_000_000 % ArenaTime.day) - Millis(tzMin) * ArenaTime.minute
        let fams = ["opus", "sonnet", "haiku", "fable"]
        let k5 = [0.6, 0.25, 0.05, 0.9], k7 = [0.06, 0.025, 0.005, 0.09]
        var spend: [ArenaSpendRow] = []
        var five: [ArenaReading] = [], week: [ArenaReading] = []
        var fiveReset: Millis?, fiveUtil = 0.0
        var weekReset: Millis = t0 + 7 * ArenaTime.day, weekUtil = 0.0, fableUtil = 0.0
        var fable: [ArenaReading] = []
        let step = 5 * ArenaTime.minute
        var t = t0
        let end = t0 + Millis(days) * ArenaTime.day
        // Each day: active from a random hour for a random number of hours.
        var activeFrom: Millis = 0, activeTo: Millis = 0
        while t < end {
            if (t - t0) % ArenaTime.day == 0 {
                let startH = 8 + Int(rng.uniform() * 4), len = rng.uniform() < 0.15 ? 0 : 3 + Int(rng.uniform() * 9)
                activeFrom = t + Millis(startH) * ArenaTime.hour
                activeTo = activeFrom + Millis(len) * ArenaTime.hour
            }
            if t >= weekReset { weekReset += 7 * ArenaTime.day; weekUtil = 0; fableUtil = 0 }
            if let r = fiveReset, t >= r { fiveReset = nil; fiveUtil = 0 }
            let active = t >= activeFrom && t < activeTo
            if active {
                if fiveReset == nil { fiveReset = t + 5 * ArenaTime.hour }
                for (f, fam) in fams.enumerated() where rng.uniform() < 0.6 {
                    let usd = (rng.uniform() * 2).rounded(.down) == 0 ? rng.uniform() * 0.8 : rng.uniform() * 3
                    spend.append(ArenaSpendRow(tEvent: t + step - 1, tKnown: t + step - 1, family: fam, costUSD: usd))
                    fiveUtil += usd * k5[f]; weekUtil += usd * k7[f]
                    if fam == "fable" { fableUtil += usd * 0.4 }
                }
            }
            // Readings every two minutes while the five-hour window runs,
            // every ten minutes otherwise; resets jitter by milliseconds.
            for sub in stride(from: Millis(0), to: step, by: Int(active || fiveReset != nil ? 2 * ArenaTime.minute : step)) {
                let ts = t + sub + 431
                let jitter = Millis(rng.uniform() * 900)
                if let r = fiveReset {
                    five.append(ArenaReading(tEvent: ts, tKnown: ts, utilPct: min(100, fiveUtil.rounded(.down)),
                                             resetsAt: r + jitter, active: true))
                } else {
                    five.append(ArenaReading(tEvent: ts, tKnown: ts, utilPct: 0, resetsAt: nil, active: false))
                }
                week.append(ArenaReading(tEvent: ts, tKnown: ts, utilPct: min(100, weekUtil.rounded(.down)),
                                         resetsAt: weekReset + jitter, active: true))
                if scoped {
                    fable.append(ArenaReading(tEvent: ts, tKnown: ts, utilPct: min(100, fableUtil.rounded(.down)),
                                              resetsAt: weekReset + jitter, active: true))
                }
            }
            t += step
        }
        var meters = [ArenaMeterID(account: "S1", windowKind: "five_hour"): five,
                      ArenaMeterID(account: "S1", windowKind: "seven_day"): week]
        if scoped { meters[ArenaMeterID(account: "S1", windowKind: "weekly_scoped", scopeModel: "Fable")] = fable }
        let store = ArenaHistoryStore(
            meters: meters,
            spend: ["S1": spend], tzOffsetMin: tzMin, dataStart: t0)
        return (store, end)
    }

    /// A moment in an active five-hour window near the end of the history.
    static func activeNow(_ store: ArenaHistoryStore, before end: Millis, meter: ArenaMeterID) -> Millis {
        let rows = store.meters[meter]!
        var t = end - ArenaTime.day
        while t > end - 10 * ArenaTime.day {
            let h = ArenaHistory(store: store, now: t, accounts: ["S1"])
            if let c = ArenaRunner.cycleAt(h.readings(meter), now: t), c.resetAt - t > ArenaTime.hour { return t }
            t -= 17 * ArenaTime.minute
        }
        return rows[rows.count - 1].tEvent
    }

    static func time(_ body: () throws -> Void) rethrows -> Double {
        let t = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
    }

    @Test func fixtureCaseTimings() throws {
        let c = try #require(try ArenaFixtures.cases("cases-spend").cases.first { $0.id == "s04" })
        let req = ArenaFixtures.request(c)
        var out: [String: Double] = [:]
        for name in ["spend-decay-30m", "calib-spend-decay-30m"] {
            let runner = ArenaRunner(registry: ArenaRegistry.all)
            out[name] = try Self.time { _ = try runner.forecast(model: name, history: ArenaFixtures.history(c), request: req) }
        }
        print("timing fixture s04: spend-decay-30m \(out["spend-decay-30m"]!) ms, calib-spend-decay-30m \(out["calib-spend-decay-30m"]!) ms (cold)")
        #expect(out["spend-decay-30m"]! < 5_000)
    }

    @Test func syntheticHistoryTimings() throws {
        let (store, end) = Self.synthetic()
        let five = ArenaMeterID(account: "S1", windowKind: "five_hour")
        let week = ArenaMeterID(account: "S1", windowKind: "seven_day")
        let now = Self.activeNow(store, before: end, meter: five)
        let h = ArenaHistory(store: store, now: now, accounts: ["S1"])
        let req = ArenaRunner.request(history: h, targets: [.meterFiveHour, .meterSevenDay])
        #expect(req.targets.count == 2)
        print("synthetic: \(store.meters[five]!.count) five-hour readings, \(store.meters[week]!.count) weekly, \(store.spend["S1"]!.count) spend rows")
        var lines: [String] = []
        for name in ["spend-decay-30m", "spend-decay-6h", "port-live-meter", "calib-spend-decay-30m", "calib-spend-decay-6h"] {
            let runner = ArenaRunner(registry: ArenaRegistry.all)
            let spec = try #require(ArenaRegistry.spec(name))
            let r = ArenaRequest(now: req.now, accounts: req.accounts, targets: req.targets.filter { spec.targets.contains($0.target) })
            var fc: ArenaForecast?
            let cold = try Self.time { fc = try runner.forecast(model: name, history: ArenaHistory(store: store, now: now, accounts: ["S1"]), request: r) }
            #expect(fc?.byKey.count == r.targets.count, "\(name)")
            // The next cut an hour on, with the runner (and its memo of the
            // child's backtests) kept: what a backfill pays per cut.
            let later = now + ArenaTime.hour
            let h2 = ArenaHistory(store: store, now: later, accounts: ["S1"])
            let r2 = ArenaRunner.request(history: h2, targets: spec.targets)
            let warm = try Self.time { _ = try runner.forecast(model: name, history: h2, request: r2) }
            lines.append("\(name): cold \(String(format: "%.1f", cold)) ms, next cut \(String(format: "%.1f", warm)) ms")
        }
        print("timing synthetic 120 d:\n  " + lines.joined(separator: "\n  "))
    }

    /// Where spend-decay's time goes on a fresh cut, kit step by kit step
    /// (each step memoized on the cut, so each later one pays only its own).
    @Test(arguments: ["five_hour", "seven_day"])
    func kitBreakdown(_ kind: String) throws {
        let (store, end) = Self.synthetic()
        let five = ArenaMeterID(account: "S1", windowKind: "five_hour")
        let now = Self.activeNow(store, before: end, meter: five)
        let h = ArenaHistory(store: store, now: now, accounts: ["S1"])
        var parts: [String] = []
        func step(_ label: String, _ body: () -> Void) {
            parts.append("\(label) \(String(format: "%.2f", Self.time(body)))")
        }
        step("readings") { _ = h.readings(account: "S1", windowKind: kind) }
        step("series") { _ = KitSpend.meterSeries(h, account: "S1", windowKind: kind) }
        step("ledger") { _ = KitSpend.ledger(h, account: "S1") }
        step("pastCycles") { _ = KitSpend.pastCycles(h, account: "S1", windowKind: kind) }
        step("intervals") { _ = KitSpend.intervals(h, account: "S1", windowKind: kind) }
        step("fitDetails") { _ = KitSpend.fitDetails(h, account: "S1", windowKind: kind) }
        let lookback: Millis = kind == "five_hour" ? 30 * ArenaTime.minute : 360 * ArenaTime.minute
        let days = kind == "five_hour" ? 60 : 120
        step("buildCases") { _ = SpendDecayModel.buildCases(h, "S1", kind, nil, lookback: lookback, maxDays: days) }
        let name = kind == "five_hour" ? "spend-decay-30m" : "spend-decay-6h"
        let req = ArenaRunner.request(history: h, targets: [kind == "five_hour" ? .meterFiveHour : .meterSevenDay])
        let runner = ArenaRunner(registry: ArenaRegistry.all)
        step("forecast (rest)") { _ = try? runner.forecast(model: name, history: h, request: req) }
        print("timing kit \(kind) ms: " + parts.joined(separator: ", "))
    }

    /// Where a calibration wrapper's time goes: the child's backtests, then
    /// the child at now plus the records and the fit, then the map's apply.
    @Test(arguments: ["calib-spend-decay-30m", "calib-spend-decay-6h"])
    func calibBreakdown(_ name: String) throws {
        let (store, end) = Self.synthetic()
        let five = ArenaMeterID(account: "S1", windowKind: "five_hour")
        let now = Self.activeNow(store, before: end, meter: five)
        final class Clock: @unchecked Sendable {
            var marks: [(UInt64, String)] = []
            let lock = NSLock()
            func mark(_ s: String) { lock.lock(); marks.append((DispatchTime.now().uptimeNanoseconds, s)); lock.unlock() }
        }
        let clock = Clock()
        let services = ArenaServices(log: { _, m in clock.mark(m) })
        let runner = ArenaRunner(registry: ArenaRegistry.all, services: services)
        let spec = try #require(ArenaRegistry.spec(name))
        for (label, t) in [("cold", now), ("next cut", now + ArenaTime.hour)] {
            clock.marks.removeAll()
            let h = ArenaHistory(store: store, now: t, accounts: ["S1"])
            let req = ArenaRunner.request(history: h, targets: spec.targets)
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = try runner.forecast(model: name, history: h, request: req)
            let t1 = DispatchTime.now().uptimeNanoseconds
            let bt = clock.marks.last { $0.1.hasPrefix("backtest") }?.0 ?? t0
            let cal = clock.marks.last { $0.1.hasPrefix("calib") }?.0 ?? bt
            func ms(_ a: UInt64, _ b: UInt64) -> String { String(format: "%.1f", Double(b - a) / 1e6) }
            print("timing \(name) \(label): backtests \(ms(t0, bt)) ms, child at now + records + fit \(ms(bt, cal)) ms, apply \(ms(cal, t1)) ms, total \(ms(t0, t1)) ms")
        }
    }
}
