import Foundation

/// The engine's immutable per-user feature representation — everything the
/// fitted models read, built once per scan tick from the whole store so the
/// typed `answer(_:)` API never touches SwiftData on the read path.
///
/// It is deliberately split from the actor: `build` is a *pure* function over
/// plain value rows (not `@Model` objects), so the whole feature pipeline —
/// the cumulative-by-hour series, the diurnal activity grid, the rate-limit
/// segmentation — unit-tests without a `ModelContainer`, and the same builder
/// runs against the research CSVs to validate on the real store.
///
/// The one genuinely new signal here is the **activity grid**: a `[7][24]`
/// `P(active)` diurnal shape (probability that a given weekday×hour has *any*
/// token arrival), measured over complete prior days. It feeds two things the
/// earlier PRs deferred for lack of a live feature stream: the empirical-Bayes
/// *prior* that `DiurnalBurnModel` shrinks thin per-cell rates toward, and the
/// end-of-day **idle/done gate** (don't scale a near-zero quiet day up by a
/// back-loaded weekday shape when the rest of the day is typically idle).
struct EngineFeatures: Sendable {

    let now: Date
    let calendar: Calendar
    /// Local start-of-day for `now`.
    let todayStart: Date

    /// `yyyy-MM-dd` → realized cost, for every day that had spend (gaps are
    /// absent — callers that need a zero-filled grid walk the calendar). The
    /// authoritative repriced daily cost, summed across models.
    let dailyCosts: [String: Double]

    /// Prior *complete* days as cumulative-by-hour `Point` series (oldest →
    /// newest), for the end-of-day shape and its conformal calibration. Capped
    /// to a recent window so old behaviour doesn't anchor the shape.
    let dailyPeriods: [ForecastInput.PriorPeriod]

    /// Today's cumulative-cost series so far (last point at `now`).
    let todayElapsed: [ForecastInput.Point]

    /// Rate-limit utilisation samples per window key (`five_hour`/`seven_day`),
    /// as the `(at, usedPercentage, resetsAt)` tuples `BurnTrajectory.segment`
    /// consumes. Only rows with a known reset are kept.
    let rateLimit: [String: [(at: Date, usedPercentage: Double, resetsAt: Date)]]

    /// `[weekday 0=Sun…6=Sat][hour 0…23]` probability that the cell has any
    /// token arrival, over complete prior days. Unit-meanable shape for the
    /// diurnal prior; `remainingActivityShare` reads it for the idle gate.
    let activityGrid: [[Double]]

    /// Wall-clock of the most recent token arrival — the idle gate's "have we
    /// gone quiet?" signal. `nil` when there's been no activity at all.
    let lastArrivalAt: Date?

    // MARK: - Plain input rows (so `build` is SwiftData-free and testable)

    struct DailyRow: Sendable { let date: String; let cost: Double }
    struct HourlyRow: Sendable { let date: String; let hour: Int; let cost: Double; let sampleCount: Int }
    struct RateRow: Sendable { let window: String; let at: Date; let usedPercentage: Double; let resetsAt: Date? }

    /// Build the feature snapshot from store rows. Pure — no I/O, no clock
    /// reads beyond the passed `now`.
    static func build(
        now: Date,
        calendar: Calendar,
        daily: [DailyRow],
        hourly: [HourlyRow],
        rate: [RateRow],
        lastArrivalAt: Date?,
        eodPriorDays: Int = 60
    ) -> EngineFeatures {
        let todayStart = calendar.startOfDay(for: now)
        let todayKey = TokenSample.formatDate(now, timeZone: calendar.timeZone)

        // Daily costs summed across models.
        var dailyCosts: [String: Double] = [:]
        for r in daily { dailyCosts[r.date, default: 0] += r.cost }

        // Hourly costs summed across models, indexed by (date, hour).
        var hourCost: [String: [Double]] = [:]    // date → [24] cost
        for r in hourly where r.hour >= 0 && r.hour < 24 && (r.cost > 0 || r.sampleCount > 0) {
            hourCost[r.date, default: [Double](repeating: 0, count: 24)][r.hour] += r.cost
        }

        // Prior complete days as cumulative-by-hour Point series.
        let priorKeys = hourCost.keys.filter { $0 < todayKey }.sorted()
        let kept = priorKeys.suffix(max(0, eodPriorDays))
        var dailyPeriods: [ForecastInput.PriorPeriod] = []
        for key in kept {
            guard let start = parseDay(key, calendar: calendar),
                  let pts = cumulativePoints(hourCost[key]!, dayStart: start, cap: nil) else { continue }
            // Carry the per-hour costs alongside the cumulative series — the
            // walk-forward calibration reads them thousands of times per
            // refit, and deriving them back from points costs 24 Calendar
            // operations a call (the difference between a ~1.5s and a
            // sub-200ms refit on a 50-day store).
            dailyPeriods.append(.init(start: start, points: pts, cachedHourlyCosts: hourCost[key]!))
        }

        // Today so far — last point pinned to `now`.
        let nowHour = calendar.component(.hour, from: now)
        var todayElapsed: [ForecastInput.Point] = []
        if let todayHours = hourCost[todayKey] {
            todayElapsed = cumulativePoints(todayHours, dayStart: todayStart, cap: nowHour, lastAt: now) ?? []
        }

        // Diurnal P(active) grid over complete prior days (idle days counted in
        // the denominator — a quiet Saturday lowers weekend activity).
        let activityGrid = buildActivityGrid(hourCost: hourCost, dailyCosts: dailyCosts,
                                             todayKey: todayKey, calendar: calendar)

        // Rate-limit tuples per window.
        var rateLimit: [String: [(at: Date, usedPercentage: Double, resetsAt: Date)]] = [:]
        for r in rate {
            guard let resets = r.resetsAt else { continue }
            rateLimit[r.window, default: []].append((r.at, r.usedPercentage, resets))
        }
        for k in rateLimit.keys { rateLimit[k]?.sort { $0.at < $1.at } }

        return EngineFeatures(
            now: now, calendar: calendar, todayStart: todayStart,
            dailyCosts: dailyCosts, dailyPeriods: dailyPeriods, todayElapsed: todayElapsed,
            rateLimit: rateLimit, activityGrid: activityGrid, lastArrivalAt: lastArrivalAt)
    }

    // MARK: - Idle gate

    /// Share of a weekday's typical daily activity that lands *after* `hour`,
    /// from the activity grid. ~0 means the rest of the day is normally idle;
    /// 1 (the safe default) when the grid can't judge, so the gate never fires
    /// on no information.
    static func remainingActivityShare(_ grid: [[Double]], weekday: Int, afterHour hour: Int) -> Double {
        guard grid.indices.contains(weekday) else { return 1 }
        let row = grid[weekday]
        let total = row.reduce(0, +)
        guard total > 0 else { return 1 }
        let from = hour + 1
        let remaining = from < 24 ? row[from...].reduce(0, +) : 0
        return remaining / total
    }

    // MARK: - Helpers

    /// Cumulative-cost `Point` series from a day's per-hour costs: one point at
    /// the middle of each active hour carrying the running total, so
    /// `HourOfDayShapeForecaster.hourlyCosts` reconstructs the per-hour costs
    /// exactly. `cap` limits to hours ≤ cap (today); `lastAt` pins the final
    /// point's timestamp (so "now" isn't in the future). `nil` if no activity.
    static func cumulativePoints(_ hourCosts: [Double], dayStart: Date, cap: Int?, lastAt: Date? = nil) -> [ForecastInput.Point]? {
        let maxHour = min(23, cap ?? 23)
        var cumulative = 0.0
        var pts: [ForecastInput.Point] = []
        for h in 0...maxHour where h < hourCosts.count {
            cumulative += hourCosts[h]
            guard hourCosts[h] > 0 else { continue }
            let at = dayStart.addingTimeInterval(Double(h) * 3600 + 1800)
            pts.append(.init(at: at, cumulative: cumulative))
        }
        guard !pts.isEmpty else { return nil }
        if let lastAt {
            let last = pts.removeLast()
            pts.append(.init(at: min(last.at, lastAt), cumulative: last.cumulative))
        }
        return pts
    }

    private static func buildActivityGrid(
        hourCost: [String: [Double]],
        dailyCosts: [String: Double],
        todayKey: String,
        calendar: Calendar
    ) -> [[Double]] {
        // Span the full calendar from the earliest observed day to the last
        // complete day, so idle (gap) days land in the per-weekday denominator.
        let allKeys = Set(hourCost.keys).union(dailyCosts.keys).filter { $0 < todayKey }
        guard let minKey = allKeys.min(),
              let start = parseDay(minKey, calendar: calendar),
              let todayStart = parseDay(todayKey, calendar: calendar),
              let lastComplete = calendar.date(byAdding: .day, value: -1, to: todayStart) else {
            return [[Double]](repeating: [Double](repeating: 0, count: 24), count: 7)
        }
        var dayCount = [Double](repeating: 0, count: 7)
        var activeCount = [[Double]](repeating: [Double](repeating: 0, count: 24), count: 7)
        var day = start
        while day <= lastComplete {
            let key = TokenSample.formatDate(day, timeZone: calendar.timeZone)
            let wd = calendar.component(.weekday, from: day) - 1
            if wd >= 0 && wd < 7 {
                dayCount[wd] += 1
                if let hours = hourCost[key] {
                    for h in 0..<24 where hours[h] > 0 { activeCount[wd][h] += 1 }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        var grid = [[Double]](repeating: [Double](repeating: 0, count: 24), count: 7)
        for wd in 0..<7 where dayCount[wd] > 0 {
            for h in 0..<24 { grid[wd][h] = activeCount[wd][h] / dayCount[wd] }
        }
        return grid
    }

    static func parseDay(_ ymd: String, calendar: Calendar) -> Date? {
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var dc = DateComponents(); dc.year = p[0]; dc.month = p[1]; dc.day = p[2]
        return calendar.date(from: dc)
    }
}
