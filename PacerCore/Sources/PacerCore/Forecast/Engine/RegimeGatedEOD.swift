import Foundation

/// End-of-day cost projector — regime-gated, empirical-Bayes-shrunk hour-of-day
/// spend shape, with conformal predictive bands. The validated round-2 upgrade
/// over the shipped (weekday-blind, band-less) `HourOfDayShapeForecaster`.
///
/// How it works: learn the *cumulative fraction of the day's spend done by each
/// hour* — separately for weekdays and weekends — then project
/// `EOD = spend-so-far ÷ fraction-typically-done-by-this-hour`. The empirical-
/// Bayes shrinkage of each (regime, hour) cell toward the pooled hour profile is
/// what makes the *thin* cells safe: they only diverge from the pooled shape as
/// far as the data supports, so the model can't overfit a handful of days.
///
/// Honest framing, from validating it on the real store through the unified
/// harness (not the round-2 synthesis, which oversold a weekend win that didn't
/// reproduce at n≈5): this candidate's real, reproducible edge is the **early-to-
/// mid weekday cuts** — at ~9am it scored ~51% median error vs clock-linear's
/// ~72% (paired Δ−23pp, 65% of days), the hardest and most actionable cut — plus
/// the **calibrated band** the shipped method lacks. It is NOT a global winner:
/// the bare multiplicative scale-up over-projects idle weekends (a back-loaded
/// shape applied to a near-zero Saturday), and the activity-aware idle gate that
/// would fix that needs the live arrival/online feature stream. That's fine — a
/// candidate need not win every bucket; the per-regime selector (the walk-forward
/// harness) routes weekends to a recent-rate expert where it wins instead.
///
/// So `projectTotal` is the point (for the tournament), and `estimate` pairs it
/// with a conformal interval and an honest confidence.
///
/// Stateless by design: the shape is rebuilt from `input.priorPeriods` on every
/// call, so the walk-forward harness scores it leak-free (it never sees a profile
/// built from days it's trying to predict). The conformal calibrator is fit
/// separately from the user's realized history via `calibrate`.
public struct RegimeGatedEOD: Forecaster {
    public let id = "regime-gated-eod"
    public let complexity = 3

    /// Below this fraction-done the multiplicative scale-up is pure noise
    /// (a tiny denominator explodes); the model declines rather than guess.
    public let minShapeFraction: Double

    public init(minShapeFraction: Double = 0.08) {
        self.minShapeFraction = minShapeFraction
    }

    // MARK: - Forecaster (point)

    public func projectTotal(_ input: ForecastInput) -> Double? {
        projection(input)?.point
    }

    /// The projection plus the intermediate quantities `estimate` needs.
    struct Projection { let point: Double; let fraction: Double; let regime: DayRegime; let dayCount: Int }

    func projection(_ input: ForecastInput) -> Projection? {
        guard input.soFar > 0 else { return nil }   // can't scale up from nothing
        guard let prof = profiles(from: input.priorPeriods, calendar: input.calendar) else { return nil }
        let regime = DayRegime.of(input.periodStart, calendar: input.calendar)
        let hour = input.calendar.component(.hour, from: input.now)
        let frac = prof.fraction[regime]?[hour] ?? prof.pooled[hour]
        guard frac >= minShapeFraction else { return nil }   // too early to project
        return Projection(point: input.soFar / frac, fraction: frac, regime: regime, dayCount: prof.dayCount)
    }

    // MARK: - Estimate (point + band)

    /// Full estimate: the point projection, conformal 80/50 bands from `calibrator`
    /// (built by `calibrate` on the user's history), and an honest confidence that
    /// drops early in the day and on thin history.
    public func estimate(_ input: ForecastInput, calibrator: ConformalCalibrator? = nil) -> Estimate {
        guard let p = projection(input) else {
            return .insufficient(method: id,
                note: "too early or not enough history to project end-of-day",
                support: input.priorPeriods.count)
        }
        let band80 = calibrator?.interval(around: p.point, level: 0.8)
        let band50 = calibrator?.interval(around: p.point, level: 0.5)
        let confidence: Estimate.Confidence
        if p.dayCount < 5 || p.fraction < 0.30 {
            confidence = .low            // thin history, or so early the point is noisy
        } else if p.fraction < 0.60 {
            confidence = .medium
        } else {
            confidence = .high           // most of the day observed
        }
        var note: String? = p.regime == .weekend ? "weekend profile" : nil
        if p.fraction < 0.30 { note = "early in the day — lean on the range" }
        return Estimate(value: p.point, interval80: band80, interval50: band50,
                        method: id, confidence: confidence, support: p.dayCount, note: note)
    }

    // MARK: - Profiles (built per-call from priors → leak-free)

    struct Profiles { let fraction: [DayRegime: [Double]]; let pooled: [Double]; let dayCount: Int }

    /// Learn the EB-shrunk cumulative-fraction-by-hour profile per regime from
    /// the prior complete days.
    func profiles(from priors: [ForecastInput.PriorPeriod], calendar: Calendar) -> Profiles? {
        var byRegime: [DayRegime: [[Double]]] = [.weekday: [], .weekend: []]
        var all: [[Double]] = []
        for p in priors {
            guard let costs = HourOfDayShapeForecaster.hourlyCosts(points: p.points, start: p.start, calendar: calendar) else { continue }
            let total = costs.reduce(0, +)
            guard total > 0 else { continue }
            var cum = 0.0
            var frac = [Double](repeating: 0, count: 24)
            for h in 0..<24 { cum += costs[h]; frac[h] = cum / total }
            all.append(frac)
            byRegime[DayRegime.of(p.start, calendar: calendar), default: []].append(frac)
        }
        guard !all.isEmpty else { return nil }

        let pooled = (0..<24).map { h in Self.mean(all.map { $0[h] }) }

        // Per hour, EB-shrink the present regimes' cells toward the pooled mean.
        var fraction: [DayRegime: [Double]] = [:]
        for h in 0..<24 {
            let present = DayRegime.allCases.compactMap { r -> (DayRegime, EmpiricalBayes.Group)? in
                let days = byRegime[r] ?? []
                guard !days.isEmpty else { return nil }
                let vals = days.map { $0[h] }
                return (r, EmpiricalBayes.Group(mean: Self.mean(vals), count: vals.count, within: Self.variance(vals)))
            }
            let shrunk = EmpiricalBayes.shrink(present.map { $0.1 })
            for (i, (r, _)) in present.enumerated() {
                fraction[r, default: [Double](repeating: 0, count: 24)][h] = shrunk.shrunkMeans[i]
            }
        }

        // Fill regimes with no history from the pooled profile; enforce a
        // monotone-nondecreasing, [0,1]-clamped curve that ends at 1.
        for r in DayRegime.allCases {
            var f = fraction[r] ?? pooled
            var prev = 0.0
            for h in 0..<24 { f[h] = min(1, max(prev, f[h])); prev = f[h] }
            f[23] = 1
            fraction[r] = f
        }
        return Profiles(fraction: fraction, pooled: pooled, dayCount: all.count)
    }

    // MARK: - Conformal calibration

    /// Build the multiplicative conformal calibrator from the user's own history
    /// by walk-forward replay: at past cut-points, project EOD using only earlier
    /// days, and collect the truth/prediction ratios. Leak-free.
    public static func calibrate(
        periods: [ForecastInput.PriorPeriod],
        calendar: Calendar,
        dayLength: TimeInterval = 86400,
        cutFractions: [Double] = [0.3, 0.45, 0.6, 0.75, 0.9]
    ) -> ConformalCalibrator {
        let model = RegimeGatedEOD()
        let sorted = periods.sorted { $0.start < $1.start }
        var preds: [Double] = []
        var truths: [Double] = []
        for (i, p) in sorted.enumerated() {
            let priors = Array(sorted[0..<i])
            guard !priors.isEmpty else { continue }
            let total = p.points.last?.cumulative ?? 0
            guard total > 0 else { continue }
            let end = p.start.addingTimeInterval(dayLength)
            for cf in cutFractions {
                let now = p.start.addingTimeInterval(dayLength * cf)
                let elapsed = p.points.filter { $0.at <= now }
                guard !elapsed.isEmpty else { continue }
                let input = ForecastInput(now: now, periodStart: p.start, periodEnd: end,
                                          calendar: calendar, elapsed: elapsed, priorPeriods: priors)
                if let pt = model.projectTotal(input), pt > 0 {
                    preds.append(pt); truths.append(total)
                }
            }
        }
        return ConformalCalibrator.fromPairs(mode: .multiplicative, predictions: preds, truths: truths)
    }

    // MARK: - Stats

    static func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
    static func variance(_ xs: [Double]) -> Double {
        guard xs.count > 1 else { return 0 }
        let m = mean(xs)
        return xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1)
    }
}
