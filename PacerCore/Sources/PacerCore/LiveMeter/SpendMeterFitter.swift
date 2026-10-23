import Foundation

/// One meter reading, as the fit needs it: a `RateLimitSample` or a scoped
/// `UsageLimitSample`, reduced to its three numbers.
public struct MeterReading: Sendable, Equatable {
    public let at: Date
    public let percent: Double
    public let resetsAt: Date?

    public init(at: Date, percent: Double, resetsAt: Date?) {
        self.at = at
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

/// One local hour's API-list spend on one model: an `AccountHourlyAggregate`
/// row, already priced by the dated price ledger (#319).
public struct HourlySpend: Sendable, Equatable {
    public let date: String
    public let hour: Int
    public let model: String
    public let costUSD: Double

    public init(date: String, hour: Int, model: String, costUSD: Double) {
        self.date = date
        self.hour = hour
        self.model = model
        self.costUSD = costUSD
    }
}

/// A local clock hour, keyed the way the hourly rollups are: the
/// `TokenSample.formatDate` day and the 0–23 hour.
public struct LocalHour: Hashable, Comparable, Sendable {
    public let date: String
    public let hour: Int

    public init(date: String, hour: Int) {
        self.date = date
        self.hour = hour
    }

    /// `yyyy-MM-dd` sorts as text, so the pair sorts as time.
    public static func < (a: LocalHour, b: LocalHour) -> Bool {
        a.date != b.date ? a.date < b.date : a.hour < b.hour
    }
}

/// What the meter did in one local hour: how far it rose, and for how many
/// seconds of the hour it was being watched (covered by a pair of readings).
public struct HourObservation: Sendable, Equatable {
    public var rise: Double
    public var watchedSeconds: Double

    /// The share of the hour that was watched, at most 1.
    public var watched: Double { min(1, watchedSeconds / 3600) }
}

/// What a fit found: meter points per API dollar, per model, for one account
/// and one window. The value the daily job stores as a `SpendMeterFit`.
public struct SpendMeterFitResult: Sendable, Equatable {
    public let accountId: String
    /// `five_hour`, `seven_day`, or a scoped `limits[]` identity.
    public let window: String
    public let spanStart: Date
    public let spanEnd: Date
    /// Points of this window's meter per API-list dollar, for every model
    /// with enough spend in the span to fit.
    public let modelRates: [String: Double]
    /// Points per watched hour that local spend does not explain.
    public let interceptPerHour: Double
    /// One factor for every model the window counts: Σ rise ÷ Σ spend over
    /// the fit's hours.
    public let pooledRate: Double
    /// The per-model fit's R² and RMSE (points per hour) over its active
    /// hours. See `SpendMeterFitter.fit`.
    public let r2: Double
    public let rmse: Double
    /// `pooledRate`'s R² over the same hours.
    public let pooledR2: Double
    /// Observed hours: the rows of the fit.
    public let hours: Int
    /// The observed hours with any rise or any spend.
    public let activeHours: Int
    public let totalSpendUSD: Double
    public let totalRise: Double
    /// Spend on models too small to get a column (under 1% of the span's
    /// spend each). Left out of the fit; included in `totalSpendUSD`.
    public let unfittedSpendUSD: Double
    /// The share of the rise the NNLS intercept puts off this Mac:
    /// `interceptPerHour` × watched hours ÷ `totalRise`.
    public let interceptShare: Double
    /// The share of the rise that fell in observed hours with no local spend
    /// (under $0.05): the lab's model-free measure of usage off this Mac.
    public let noSpendRiseShare: Double
    public let method: String
}

/// Converts API-list spend into usage-meter points (#317): for one account
/// and one window, a non-negative least-squares fit of the meter's hourly
/// rise on that hour's spend per model, plus an intercept.
///
/// **Rows are observed hours**: every local hour some pair of consecutive
/// readings overlaps, so the meter was being watched. Idle hours that were
/// watched are rows too — an hour the meter sat still with nothing spent is
/// evidence about the intercept, and leaving those out would credit "off
/// this Mac" with whatever the fit misses in busy hours. Hours nobody read
/// (the Mac asleep, a login not polled) are not rows, so their spend never
/// pairs with a rise of zero.
///
/// **Rise.** Between consecutive readings of the same cycle
/// (`RateLimitCycle.contains`, never `resetsAt ==`), under an hour apart,
/// and only when non-negative. A pair spanning a reset, a long gap or a
/// sleep says nothing about any one hour, so it is dropped rather than
/// guessed at.
///
/// **A pair that crosses an hour boundary is split between the two hours
/// by time.** The research harness credits a pair's whole rise to the later
/// reading's hour, which is right there because it sums the spend over the
/// same pair. Spend here comes from the hourly rollup instead, bucketed by
/// each turn's own time, and crediting the later hour then moves rise a few
/// minutes later than the spend behind it every hour. On the owner's store
/// that cost one account's hourly R² 0.82 against 0.91 for the harness's
/// pair-aligned spend; splitting by time gets it to 0.90 with no change in
/// any rate.
///
/// **Columns.** One per model with at least 1% of the span's spend (capped
/// at `maxModelColumns`, biggest first), plus the intercept. Smaller models
/// are left out rather than fitted from a few dollars, which would hand them
/// a coefficient set by noise; whoever reads the fit should price a model
/// with no rate of its own at `pooledRate`. The intercept's column is the
/// share of the hour that was watched, so it is a rate per watched hour and
/// a half-watched hour asks half as much of it.
///
/// **Error** is scored over the active hours (rise or spend), the way the
/// research harness scores it, so the numbers compare with it directly;
/// watched idle hours would pad R² with hours any fit gets right.
///
/// Pure and `Sendable`-only: no store, no clock beyond what it is handed.
public enum SpendMeterFitter {

    public static let method = "nnls-hourly-v1"
    /// Trailing days per fit. The owner's decision on #317: the factor
    /// drifts by about ±30% across model generations, and 14 days is what
    /// the lab replay tested.
    public static let spanDays = 14
    /// Consecutive readings further apart than this are not a pair.
    public static let maxPairGap: TimeInterval = 3600
    /// An hour below this much spend counts as "no local spend" for
    /// `noSpendRiseShare`. The lab's threshold.
    public static let noSpendThresholdUSD = 0.05
    /// A model below this share of the span's spend gets no column.
    public static let minModelShare = 0.01
    /// Fifteen models and the intercept: NNLS's cost grows with the square.
    public static let maxModelColumns = 15

    // Below these a fit is noise, and no fit is better than a wrong one: the
    // live meter (#318) shows the plain reading when it has no rate.
    public static let minHours = 24
    public static let minRise = 2.0
    public static let minSpendUSD = 5.0

    public enum Outcome: Sendable, Equatable {
        case fitted(SpendMeterFitResult)
        case skipped(reason: String)
    }

    /// The span a fit made on `day` covers: the `spanDays` whole local days
    /// before it. Whole days, so a fit is the same whether it ran at 00:05
    /// or at a 15:00 launch, and today's half-finished hours never enter it.
    public static func span(endingAtStartOf day: Date, calendar: Calendar) -> DateInterval {
        let end = calendar.startOfDay(for: day)
        let start = calendar.date(byAdding: .day, value: -spanDays, to: end)
            ?? end.addingTimeInterval(-Double(spanDays) * 86_400)
        return DateInterval(start: start, end: end)
    }

    /// Which models' spend can move a scoped cap: those whose id names the
    /// cap's model. The Fable weekly cap arrives as `modelDisplayName:
    /// "Fable"` with no id, and counts `claude-fable-5-1`. Nil when the cap
    /// names no model (a surface-only cap), meaning every model counts.
    ///
    /// The fit needs it because NNLS cannot tell a cap's own model from one
    /// that merely runs at the same hours. On the owner's store one account
    /// spent $23 on Fable in a fortnight against $4,000 on everything, so
    /// given every model's spend Fable fell under the 1% column threshold and
    /// the fit put the cap's 8 points on Opus 5.5, at 0.003 points per dollar:
    /// a live Fable meter that would climb with Opus work. Restricted to
    /// Fable's own spend, it fits 0.34 points per Fable dollar.
    public static func capCounts(modelId: String?, displayName: String?) -> (@Sendable (String) -> Bool)? {
        let needles = [modelId, displayName]
            .compactMap { $0?.lowercased() }
            .map { $0.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ".", with: "-") }
            .filter { !$0.isEmpty }
        guard !needles.isEmpty else { return nil }
        return { model in
            let m = model.lowercased()
            return needles.contains { m.contains($0) }
        }
    }

    // MARK: - Fit

    /// `counts` restricts the spend to the models that can move this window
    /// (`capCounts`); nil counts every model.
    public static func fit(
        accountId: String, window: String, duration: TimeInterval,
        readings: [MeterReading], spend: [HourlySpend],
        span: DateInterval, timeZone: TimeZone,
        counts: (@Sendable (String) -> Bool)? = nil
    ) -> Outcome {
        let observed = hourlyRise(readings: readings, duration: duration, span: span, timeZone: timeZone)
        guard observed.count >= minHours else {
            return .skipped(reason: "\(observed.count) observed hours (need \(minHours))")
        }

        // Spend in the observed hours only. Every sum here runs in a fixed
        // order (hour, then model), never a dictionary's or the store's: the
        // same rows must give the same bits however they were fetched, or a
        // same-day refit rewrites every row with values a rounding apart.
        var spendByHour: [LocalHour: [String: Double]] = [:]
        let ordered = spend.sorted {
            ($0.date, $0.hour, $0.model, $0.costUSD) < ($1.date, $1.hour, $1.model, $1.costUSD)
        }
        for row in ordered where row.costUSD > 0 && (counts?(row.model) ?? true) {
            let h = LocalHour(date: row.date, hour: row.hour)
            guard observed[h] != nil else { continue }
            spendByHour[h, default: [:]][row.model, default: 0] += row.costUSD
        }

        let hours = observed.keys.sorted()
        var modelTotals: [String: Double] = [:]
        for h in hours {
            guard let byModel = spendByHour[h] else { continue }
            for model in byModel.keys.sorted() { modelTotals[model, default: 0] += byModel[model]! }
        }
        let modelNames = modelTotals.keys.sorted()
        let totalSpend = modelNames.reduce(0) { $0 + modelTotals[$1]! }
        let totalRise = hours.reduce(0) { $0 + observed[$1]!.rise }
        guard totalSpend >= minSpendUSD else {
            return .skipped(reason: String(format: "$%.2f spent (need $%.0f)", totalSpend, minSpendUSD))
        }
        guard totalRise >= minRise else {
            return .skipped(reason: String(format: "%.0f points of rise (need %.0f)", totalRise, minRise))
        }

        let models = modelTotals
            .filter { $0.value >= minModelShare * totalSpend }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(maxModelColumns)
            .map(\.key)
        let fittedSet = Set(models)
        let unfitted = modelNames.filter { !fittedSet.contains($0) }.reduce(0) { $0 + modelTotals[$1]! }

        // Design: one column per model, then the intercept's watched share.
        var design: [[Double]] = []
        var y: [Double] = []
        var hourSpend: [Double] = []
        design.reserveCapacity(hours.count)
        for h in hours {
            let byModel = spendByHour[h] ?? [:]
            design.append(models.map { byModel[$0] ?? 0 } + [observed[h]!.watched])
            y.append(observed[h]!.rise)
            hourSpend.append(byModel.keys.sorted().reduce(0) { $0 + byModel[$1]! })
        }
        let coefficients = NNLS.solve(rows: design, b: y).x
        let intercept = coefficients[models.count]
        var rates: [String: Double] = [:]
        for (j, model) in models.enumerated() { rates[model] = coefficients[j] }
        let pooled = totalRise / totalSpend
        let watchedHours = hours.reduce(0) { $0 + observed[$1]!.watched }

        // Score over the active hours.
        var fitted: [Double] = []
        var pooledFitted: [Double] = []
        var actual: [Double] = []
        var noSpendRise = 0.0
        for (i, row) in design.enumerated() {
            if hourSpend[i] < noSpendThresholdUSD { noSpendRise += y[i] }
            guard y[i] > 0 || hourSpend[i] > 0 else { continue }
            var p = 0.0
            for j in 0..<row.count { p += row[j] * coefficients[j] }
            fitted.append(p)
            pooledFitted.append(pooled * hourSpend[i])
            actual.append(y[i])
        }
        let (r2, rmse) = score(actual: actual, predicted: fitted)
        let (pooledR2, _) = score(actual: actual, predicted: pooledFitted)

        return .fitted(SpendMeterFitResult(
            accountId: accountId, window: window,
            spanStart: span.start, spanEnd: span.end,
            modelRates: rates, interceptPerHour: intercept, pooledRate: pooled,
            r2: r2, rmse: rmse, pooledR2: pooledR2,
            hours: hours.count, activeHours: actual.count,
            totalSpendUSD: totalSpend, totalRise: totalRise,
            unfittedSpendUSD: unfitted,
            interceptShare: intercept * watchedHours / totalRise,
            noSpendRiseShare: noSpendRise / totalRise,
            method: method))
    }

    /// Centered R² and RMSE. R² is 0 when the actuals do not vary.
    static func score(actual: [Double], predicted: [Double]) -> (r2: Double, rmse: Double) {
        guard !actual.isEmpty else { return (0, 0) }
        let mean = actual.reduce(0, +) / Double(actual.count)
        var sse = 0.0
        var sst = 0.0
        for i in 0..<actual.count {
            sse += (actual[i] - predicted[i]) * (actual[i] - predicted[i])
            sst += (actual[i] - mean) * (actual[i] - mean)
        }
        return (sst > 0 ? 1 - sse / sst : 0, (sse / Double(actual.count)).squareRoot())
    }

    // MARK: - Bucketing

    /// Meter rise per local hour inside `span`, and how much of each hour
    /// was watched. An hour is present exactly when some pair overlaps it.
    ///
    /// Readings tie-break on value, so two logins reading the same account
    /// at the same instant telescope upward rather than in whatever order
    /// the store returned them; then on reset, so the order is total.
    public static func hourlyRise(
        readings: [MeterReading], duration: TimeInterval,
        span: DateInterval, timeZone: TimeZone
    ) -> [LocalHour: HourObservation] {
        let sorted = readings.sorted {
            ($0.at, $0.percent, $0.resetsAt ?? .distantPast) < ($1.at, $1.percent, $1.resetsAt ?? .distantPast)
        }
        var hourOf = LocalHourMapper(timeZone: timeZone)
        var out: [LocalHour: HourObservation] = [:]
        func credit(_ hour: (key: LocalHour, start: Date), rise: Double, seconds: Double) {
            guard hour.start >= span.start, hour.start < span.end, seconds > 0 || rise > 0 else { return }
            var o = out[hour.key] ?? HourObservation(rise: 0, watchedSeconds: 0)
            o.rise += rise
            o.watchedSeconds += seconds
            out[hour.key] = o
        }
        guard sorted.count >= 2 else { return out }
        for i in 1..<sorted.count {
            let a = sorted[i - 1]
            let b = sorted[i]
            guard b.at > span.start, a.at < span.end else { continue }
            let gap = b.at.timeIntervalSince(a.at)
            guard gap < maxPairGap, sameCycle(a, b, duration: duration) else { continue }
            let delta = b.percent - a.percent
            guard delta >= 0 else { continue }

            let later = hourOf(b.at)
            guard gap > 0, a.at < later.start else {
                credit(later, rise: delta, seconds: gap)
                continue
            }
            // Under an hour apart, so the pair touches at most these two.
            let inLater = b.at.timeIntervalSince(later.start)
            credit(later, rise: delta * inLater / gap, seconds: inLater)
            credit(hourOf(a.at), rise: delta * (gap - inLater) / gap, seconds: gap - inLater)
        }
        return out
    }

    /// Whether two consecutive readings belong to one cycle:
    /// `RateLimitCycle.contains`, jitter-tolerant. A `nil` reset is the
    /// post-reset 0% reading before the next window anchors, so it pairs
    /// with either neighbour: the drop into it is negative and dropped, the
    /// climb out of it is the new cycle's first rise.
    static func sameCycle(_ a: MeterReading, _ b: MeterReading, duration: TimeInterval) -> Bool {
        guard let anchor = a.resetsAt else { return true }
        return RateLimitCycle.contains(sampleReset: b.resetsAt, resets: anchor, duration: duration)
    }
}

/// Instant → local hour and the instant it began, memoised per UTC quarter
/// hour. Every time zone's offset is a whole number of quarter hours, so all
/// instants in one UTC quarter hour share a local hour, and the calendar runs
/// once per quarter rather than once per reading (a busy account reads every
/// few seconds).
struct LocalHourMapper {
    private let calendar: Calendar
    private let timeZone: TimeZone
    private var cache: [Int: (key: LocalHour, start: Date)] = [:]

    init(timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.timeZone = timeZone
    }

    mutating func callAsFunction(_ instant: Date) -> (key: LocalHour, start: Date) {
        let slot = Int((instant.timeIntervalSince1970 / 900).rounded(.down))
        if let hit = cache[slot] { return hit }
        let key = LocalHour(date: TokenSample.formatDate(instant, timeZone: timeZone),
                            hour: calendar.component(.hour, from: instant))
        let start = calendar.dateInterval(of: .hour, for: instant)?.start
            ?? Date(timeIntervalSince1970: (instant.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        let hit = (key, start)
        cache[slot] = hit
        return hit
    }
}
