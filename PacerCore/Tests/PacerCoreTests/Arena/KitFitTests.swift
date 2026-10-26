import Foundation
import Testing
@testable import PacerCore

/// The conversion's fast path (per-hour sums, `fitFromHours`) against the
/// row-by-row fit the Python computes (`fitOnDayByRows`), on every day a
/// fixture case or the synthetic history fits.
@Suite struct KitFitTests {
    static func compare(_ h: ArenaHistory, account: String, kind: String, days: [Millis]) -> (Int, Double) {
        var checked = 0, worst = 0.0
        for d in days {
            let a = KitSpend.fitOnDay(h, account: account, windowKind: kind, scopeModel: nil, dayStart: d)
            let b = KitSpend.fitOnDayByRows(h, account: account, windowKind: kind, scopeModel: nil, dayStart: d)
            #expect((a == nil) == (b == nil), "day \(d)")
            guard let a, let b else { continue }
            #expect(a.conversion.weak == b.conversion.weak, "day \(d) weak")
            #expect(a.nRows == b.nRows && a.own == b.own, "day \(d) rows")
            for f in 0..<5 {
                let rel = abs(a.rates[f] - b.rates[f]) / max(abs(b.rates[f]), 1e-12)
                worst = max(worst, rel)
                #expect(rel <= 1e-9, "day \(d) rate \(f): \(a.rates[f]) vs \(b.rates[f])")
            }
            #expect(abs(a.conversion.r2 - b.conversion.r2) <= 1e-9, "day \(d) r2 \(a.conversion.r2) vs \(b.conversion.r2)")
            #expect(abs(a.pooled - b.pooled) <= 1e-12 * max(1, abs(b.pooled)))
            checked += 1
        }
        return (checked, worst)
    }

    @Test func hourBucketsMatchRowsOnTheFixtures() throws {
        var checked = 0, worst = 0.0
        for c in try ArenaFixtures.cases("cases-spend").cases {
            let h = ArenaFixtures.history(c)
            let today = KitSpend.localDayStart(h)
            let days = (0..<12).map { today - Millis($0) * ArenaTime.day }
            let (n, w) = Self.compare(h, account: c.inputs.account, kind: c.inputs.window_kind, days: days)
            checked += n; worst = max(worst, w)
        }
        #expect(checked > 40)
        print("hour-bucket fit vs rows (fixtures): \(checked) fits, max relative |Δrate| \(worst)")
    }

    @Test func hourBucketsMatchRowsOnASyntheticHistory() throws {
        let (store, end) = SpendTimingTests.synthetic(days: 40)
        let h = ArenaHistory(store: store, now: end - 3 * ArenaTime.hour, accounts: ["S1"])
        let today = KitSpend.localDayStart(h)
        let days = (0..<30).map { today - Millis($0) * ArenaTime.day }
        var checked = 0, worst = 0.0
        for kind in ["five_hour", "seven_day"] {
            let (n, w) = Self.compare(h, account: "S1", kind: kind, days: days)
            checked += n; worst = max(worst, w)
        }
        #expect(checked > 40)
        print("hour-bucket fit vs rows (synthetic): \(checked) fits, max relative |Δrate| \(worst)")
    }

    /// An interval ending exactly on a local hour counts in the next
    /// hour's R² group, and one ending exactly at the span's end is in it.
    @Test func intervalsEndingOnTheHour() throws {
        let off = Millis(-240) * ArenaTime.minute
        let day: Millis = 1_780_000_000_000 - (1_780_000_000_000 + off) % ArenaTime.day + ArenaTime.day
        var readings: [ArenaReading] = [], spend: [ArenaSpendRow] = []
        var util = 0.0
        let reset = day + 2 * ArenaTime.hour
        // Readings every 10 min across the 14 days before `day`, several of
        // them exactly on the hour (and the last exactly at `day`).
        var t = day - 14 * ArenaTime.day + 10 * ArenaTime.minute
        var i = 0
        while t <= day {
            let usd = Double(i % 7) * 0.4
            spend.append(ArenaSpendRow(tEvent: t - 1, tKnown: t - 1, family: i % 3 == 0 ? "opus" : "sonnet", costUSD: usd))
            util += usd * (i % 3 == 0 ? 0.5 : 0.2)
            let cycleReset = reset - ((day - t) / (5 * ArenaTime.hour)) * 5 * ArenaTime.hour
            readings.append(ArenaReading(tEvent: t, tKnown: t, utilPct: util.rounded(.down), resetsAt: cycleReset, active: true))
            t += 10 * ArenaTime.minute; i += 1
        }
        let store = ArenaHistoryStore(meters: [ArenaMeterID(account: "S1", windowKind: "seven_day"): readings],
                                      spend: ["S1": spend], tzOffsetMin: -240)
        let h = ArenaHistory(store: store, now: day + ArenaTime.hour, accounts: ["S1"])
        let (n, w) = Self.compare(h, account: "S1", kind: "seven_day", days: [day])
        #expect(n == 1)
        #expect(w <= 1e-9)
    }

    /// Two accounts in view, one with too few intervals of its own: the fit
    /// pools both (own false), and the hour buckets still match the rows,
    /// R² grouped by (account, hour).
    @Test func pooledAcrossAccounts() throws {
        let (a, end) = SpendTimingTests.synthetic(days: 30)
        // A second account: three days of the first's rows, renamed and shifted.
        let five = ArenaMeterID(account: "S1", windowKind: "five_hour")
        let cut = end - 3 * ArenaTime.day
        // Every 20th reading (40 minutes apart): under 100 intervals of its own.
        let otherReadings = a.meters[five]!.filter { $0.tEvent >= cut }.enumerated().filter { $0.offset % 20 == 0 }
            .map(\.element)
        let otherSpend = a.spend["S1"]!.filter { $0.tEvent >= cut }
        var meters = a.meters
        meters[ArenaMeterID(account: "S0", windowKind: "five_hour")] = otherReadings
        let store = ArenaHistoryStore(meters: meters, spend: ["S1": a.spend["S1"]!, "S0": otherSpend],
                                      tzOffsetMin: a.tzOffsetMin, dataStart: a.dataStart)
        let h = ArenaHistory(store: store, now: end - ArenaTime.hour, accounts: ["S0", "S1"])
        let today = KitSpend.localDayStart(h)
        let (n, w) = Self.compare(h, account: "S0", kind: "five_hour", days: [today, today - ArenaTime.day])
        #expect(n == 2 && w <= 1e-9)
        let d = try #require(KitSpend.fitDetails(h, account: "S0", windowKind: "five_hour"))
        #expect(!d.own)
        #expect(KitSpend.fitDetails(h, account: "S1", windowKind: "five_hour")?.own == true)
    }

    /// No spend at all: no conversion, so spend-decay is the reading, flat;
    /// the calibration wrapper passes that through; port-live-meter too.
    @Test func noSpendIsFlat() throws {
        let (a, end) = SpendTimingTests.synthetic(days: 20)
        let store = ArenaHistoryStore(meters: a.meters, spend: [:], tzOffsetMin: a.tzOffsetMin, dataStart: a.dataStart)
        let five = ArenaMeterID(account: "S1", windowKind: "five_hour")
        let now = SpendTimingTests.activeNow(store, before: end, meter: five)
        let h = ArenaHistory(store: store, now: now, accounts: ["S1"])
        let req = ArenaRunner.request(history: h, targets: [.meterFiveHour, .meterSevenDay])
        let runner = ArenaRunner(registry: ArenaRegistry.all)
        for name in ["spend-decay-30m", "calib-spend-decay-30m", "port-live-meter"] {
            let fc = try runner.forecast(model: name, history: h, request: req)
            for tr in req.targets where ArenaRegistry.spec(name)!.targets.contains(tr.target) {
                let tf = try #require(fc.byKey[tr.key], "\(name)")
                let latest = KitBaselines.meterNow(h, tr).latest
                #expect(tf.quantile(0.05).allSatisfy { $0 == latest } && tf.quantile(0.95).allSatisfy { $0 == latest },
                        "\(name) \(tr.key)")
            }
        }
    }
}
