import Foundation

/// Candidate forecasters for end-of-period **total** surfaces (end-of-day
/// cost, and later monthly). Each wraps a projection method Pacer already
/// ships, behind the uniform `Forecaster` interface so the tournament can
/// score them head-to-head. Ordered here by `complexity` (the selector's
/// tie-breaker).

/// Clock-linear pace: scale spend-so-far by how much of the period's
/// wall-clock has elapsed. The simplest possible baseline — `soFar × total /
/// elapsed`. Surprisingly hard to beat; it's the floor every other candidate
/// has to clear.
public struct AverageRateForecaster: Forecaster {
    public let id = "average-rate"
    public let complexity = 0
    public init() {}

    public func projectTotal(_ input: ForecastInput) -> Double? {
        let f = input.elapsedFraction
        guard f > 0.02 else { return nil }   // too early — pace is pure noise
        return input.soFar / f
    }
}

/// Recent run-rate × time left — the shape of Pacer's current naive
/// end-of-day projection ("last hour's rate, carried to midnight"). Reacts
/// fast; overshoots when the recent window happens to be hot.
public struct RecentRateForecaster: Forecaster {
    public let id = "recent-rate"
    public let complexity = 1
    /// How far back the "recent" rate is measured.
    public let window: TimeInterval
    public init(window: TimeInterval = 3600) { self.window = window }

    public func projectTotal(_ input: ForecastInput) -> Double? {
        guard let last = input.elapsed.last else { return nil }
        let cutoff = input.now.addingTimeInterval(-window)
        let earlier = input.elapsed.last(where: { $0.at <= cutoff }) ?? input.elapsed.first!
        let dt = last.at.timeIntervalSince(earlier.at)
        guard dt > 0 else { return input.soFar }
        let rate = (last.cumulative - earlier.cumulative) / dt
        return input.soFar + rate * input.remainingSeconds
    }
}

/// Recency-weighted slope of the cumulative curve via `TrendEstimator`
/// (acceleration off — it didn't help on real data). Smoother than the raw
/// recent rate; an old spike inside the period can't tilt it.
public struct RecencyWeightedSlopeForecaster: Forecaster {
    public let id = "recency-slope"
    public let complexity = 2
    public init() {}

    public func projectTotal(_ input: ForecastInput) -> Double? {
        let samples = input.elapsed.map {
            TrendEstimator.Sample(at: $0.at, value: $0.cumulative)
        }
        guard let fit = TrendEstimator.fit(samples: samples, parameters: .init(
            now: input.now,
            minSamples: 3,
            minSpanSeconds: 30 * 60,
            recencyHalfLifeSeconds: max(3600, input.totalSeconds * 0.15),
            dampingTauSeconds: max(3600, input.remainingSeconds),
            maxAccelSlopeFraction: 0
        )) else { return nil }
        return fit.projectedValue(at: input.periodEnd, now: input.now)
    }
}

/// Hour-of-day shape (the shipped end-of-day method): scale spend-so-far by
/// the typical cumulative fraction done by this hour, blended with the recent
/// rate early in the day. Knows the evening tapers. Reuses the tested
/// `ActivityProfile`; only applies to day-length periods.
public struct HourOfDayShapeForecaster: Forecaster {
    public let id = "hour-of-day-shape"
    public let complexity = 2
    public init() {}

    public func projectTotal(_ input: ForecastInput) -> Double? {
        let days = input.priorPeriods.compactMap {
            $0.cachedHourlyCosts ?? Self.hourlyCosts(points: $0.points, start: $0.start, calendar: input.calendar)
        }
        guard let shape = ActivityProfile.hourOfDayShape(days: days) else { return nil }
        let hour = input.calendar.component(.hour, from: input.now)
        let naive = RecentRateForecaster().projectTotal(input) ?? input.soFar
        return ActivityProfile.projectedEndOfDay(
            soFar: input.soFar, throughHour: hour, shape: shape, naive: naive)
    }

    /// Reconstruct a day's 24 per-hour costs from its cumulative points by
    /// differencing consecutive hour buckets.
    static func hourlyCosts(points: [ForecastInput.Point], start: Date, calendar: Calendar) -> [Double]? {
        guard !points.isEmpty else { return nil }
        // Cumulative value at the end of each hour (carry forward the last
        // seen cumulative through hours with no new point).
        var cumByHour = [Double](repeating: 0, count: 24)
        var lastSeen = 0.0
        var idx = 0
        let sorted = points.sorted { $0.at < $1.at }
        for h in 0..<24 {
            let hourEnd = calendar.date(byAdding: .hour, value: h + 1, to: start) ?? start
            while idx < sorted.count, sorted[idx].at < hourEnd {
                lastSeen = sorted[idx].cumulative
                idx += 1
            }
            cumByHour[h] = lastSeen
        }
        // Difference into per-hour costs.
        var costs = [Double](repeating: 0, count: 24)
        var prev = 0.0
        for h in 0..<24 {
            costs[h] = max(0, cumByHour[h] - prev)
            prev = cumByHour[h]
        }
        return costs
    }
}
