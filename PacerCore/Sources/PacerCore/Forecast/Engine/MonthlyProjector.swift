import Foundation

/// Month-total cost projector — the fix for the original demotion problem that
/// started this whole rework (the shipped month-level day-of-week method got
/// ruled ineligible on 2 months of history and fell back to a flat average that
/// over-projected).
///
/// The round-2 structural insight: **don't model the month, model the daily
/// series and sum it.** A month has only a handful of completed instances, but a
/// daily series has ~50 points — and the per-day forecast errors are noisy but
/// *unbiased*, so they cancel in the sum (the realized month total is far more
/// predictable than any single day). Each remaining day of the month is forecast
/// by a recency-weighted, empirical-Bayes-shrunk per-weekday mean, and added to
/// what's already been spent.
///
/// Three honest guards from the research: **trend is OFF** (the +50%/mo ramp is
/// transient onboarding, not compounding — adding a trend term hurt); the weekday
/// effect is **EB-shrunk** (this user's weekday signal is weak, so it collapses
/// toward flat automatically rather than overfitting); and below an eligibility
/// bar it **falls back to the flat average** with low confidence rather than
/// shipping a seasonal guess on too little history.
public enum MonthlyProjector {
    public static let minActiveDays = 20
    public static let minPriorMonths = 2
    public static let minWeekendDays = 2

    /// Project the current calendar month's total cost.
    /// - Parameter dailyCosts: `yyyy-MM-dd` → cost, for the current month plus
    ///   prior history (in the same calendar/timezone as `calendar`).
    public static func project(
        dailyCosts: [String: Double],
        now: Date = Date(),
        calendar: Calendar = .current,
        halfLifeDays: Double = 14
    ) -> Estimate {
        guard let monthInterval = calendar.dateInterval(of: .month, for: now),
              let earliestKey = dailyCosts.keys.min(),
              let earliest = parse(earliestKey, calendar: calendar) else {
            return .insufficient(method: "monthly", note: "not enough history yet")
        }
        let firstOfMonth = monthInterval.start
        let monthPrefix = String(TokenSample.formatDate(firstOfMonth, timeZone: calendar.timeZone).prefix(7))
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let dayOfMonth = calendar.component(.day, from: now)
        let today = calendar.startOfDay(for: now)

        // One pass over the daily calendar: observed-so-far this month, plus
        // recency-weighted per-weekday accumulators over strictly-earlier days.
        var observed = 0.0
        var wValues: [Int: [(w: Double, v: Double)]] = [:]
        var activeDays = 0, weekendDays = 0
        var priorMonthsSet = Set<String>()
        var globalSum = 0.0, globalW = 0.0
        var day = earliest
        while day <= today {
            let key = TokenSample.formatDate(day, timeZone: calendar.timeZone)
            let cost = dailyCosts[key] ?? 0
            if day >= firstOfMonth { observed += cost }
            if day < today {                                   // history for forecasting
                let age = today.timeIntervalSince(day) / 86400
                let weight = pow(0.5, age / halfLifeDays)
                let wd = calendar.component(.weekday, from: day)
                wValues[wd, default: []].append((weight, cost))
                globalSum += weight * cost; globalW += weight
                if cost > 0 {
                    activeDays += 1
                    if wd == 1 || wd == 7 { weekendDays += 1 }
                    if !key.hasPrefix(monthPrefix) { priorMonthsSet.insert(String(key.prefix(7))) }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        let globalMean = globalW > 0 ? globalSum / globalW : 0

        // Eligibility — otherwise fall back to the flat average, low confidence.
        let eligible = activeDays >= minActiveDays
            && priorMonthsSet.count >= minPriorMonths
            && weekendDays >= minWeekendDays
        if !eligible {
            if let flat = MonthlyForecast.compute(dailyCosts: dailyCosts, now: now, calendar: calendar) {
                return Estimate(value: flat.projectedMonthTotal, method: "monthly-flat",
                                confidence: .low, support: activeDays,
                                note: "flat average — not enough history for the seasonal model yet")
            }
            return .insufficient(method: "monthly", note: "not enough data this month yet", support: activeDays)
        }

        // EB-shrunk recency-weighted per-weekday means.
        let groups: [EmpiricalBayes.Group] = (1...7).map { wd in
            let vals = wValues[wd] ?? []
            let wsum = vals.reduce(0) { $0 + $1.w }
            let mean = wsum > 0 ? vals.reduce(0) { $0 + $1.w * $1.v } / wsum : globalMean
            let wvar = wsum > 0 ? vals.reduce(0) { $0 + $1.w * ($1.v - mean) * ($1.v - mean) } / wsum : 0
            return .init(mean: mean, count: vals.count, within: wvar)
        }
        let shr = EmpiricalBayes.shrink(groups)
        let weekdayForecast = (1...7).reduce(into: [Int: Double]()) { acc, wd in
            acc[wd] = max(0, shr.shrunkMeans[wd - 1])
        }

        // Sum the remaining days' forecasts onto what's already spent.
        var projected = observed
        var varianceSum = 0.0
        if dayOfMonth < daysInMonth {
            for d in (dayOfMonth + 1)...daysInMonth {
                var dc = calendar.dateComponents([.year, .month], from: now); dc.day = d
                guard let date = calendar.date(from: dc) else { continue }
                let wd = calendar.component(.weekday, from: date)
                projected += weekdayForecast[wd] ?? globalMean
                varianceSum += groups[wd - 1].within
            }
        }

        let sd = varianceSum.squareRoot()
        func band(_ z: Double) -> ClosedRange<Double>? {
            guard sd > 0 else { return nil }
            return Swift.max(observed, projected - z * sd)...(projected + z * sd)
        }
        let confidence: Estimate.Confidence = dayOfMonth * 2 >= daysInMonth ? .medium : .low
        return Estimate(value: projected, interval80: band(1.2816), interval50: band(0.6745),
                        method: "monthly-daily-sum", confidence: confidence, support: activeDays)
    }

    static func parse(_ ymd: String, calendar: Calendar) -> Date? {
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var dc = DateComponents(); dc.year = p[0]; dc.month = p[1]; dc.day = p[2]
        return calendar.date(from: dc)
    }
}
