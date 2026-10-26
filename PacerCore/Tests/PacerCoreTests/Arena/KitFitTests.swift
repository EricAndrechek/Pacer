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
}
