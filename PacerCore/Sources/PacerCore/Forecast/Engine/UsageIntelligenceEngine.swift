import Foundation
import SwiftData

/// A rate-limit window, typed for the engine's question API. (`RateLimitWindow`
/// is already a per-window *snapshot* struct elsewhere; this is just the window
/// identity.)
public enum RateLimitWindowKind: String, Sendable, CaseIterable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
}

/// Horizon for a cost projection.
public enum CostHorizon: Sendable, Equatable {
    /// End of the current local day.
    case today
    /// End of the current calendar month.
    case thisMonth
}

/// The fixed set of questions the engine answers. Every one resolves to an
/// `Estimate` (value + honest band + confidence + support), so a view renders
/// one consistent shape and can lean on the interval when the point is too
/// early to trust. The engine owns the meaning of `value` per question:
/// dollars for `projectedCost`, utilisation percentage points for
/// `rateLimitOutlook`, a percentile in [0,1] for `pace`, a robust z-score for
/// `isAnomalous` (with the categorical verdict in `note`).
public enum EngineQuestion: Sendable, Equatable {
    /// Projected total cost for a horizon (dollars).
    case projectedCost(CostHorizon)
    /// Projected final utilisation at the window's reset (percentage points).
    case rateLimitOutlook(RateLimitWindowKind)
    /// Today's projected spend as a percentile of the user's own daily norm.
    case pace
    /// Typical daily cost for today's weekday (the personal "normal" band).
    case typicalUsage
    /// Whether the most recent complete day was anomalous (z-score; `note`
    /// carries `lull`/`normal`/`spike`).
    case isAnomalous
    /// A next-day cost estimate — wide by nature; ship the band, not the point.
    case shortHorizon
}

/// The standalone, on-device usage-intelligence engine.
///
/// A background actor with **its own `ModelContext`** that owns the whole
/// dataset: on each scan tick it reads the store, rebuilds the per-user
/// `EngineFeatures`, and refits the per-user models (the regime-gated
/// end-of-day shape and its conformal calibrator, the diurnal rate-limit
/// model shrunk toward the activity-grid prior plus its calibrator, the usage-
/// norm bands, the daily baseline). Views never hand it data — they `ask`
/// typed questions and get back calibrated `Estimate`s computed from the
/// cached fit. This is the question→`Estimate` contract the rest of the
/// app (and future plugins) call.
///
/// Everything the models need is the validated pure-Swift work from the
/// earlier engine PRs (`RegimeGatedEOD`, `DiurnalBurnModel`, `UsageNorms`,
/// `MonthlyProjector`, `ConformalCalibrator`) — no CreateML/Accelerate at this
/// data scale. The actor is the integration layer: store → features → fit →
/// answer. The answer logic is split into pure statics so it tests without a
/// container. Self-eval persistence and per-regime winner selection across all
/// surfaces is the next PR; here selection is the on-the-fly walk-forward
/// backtest the burn tournament already does.
@ModelActor
public actor UsageIntelligenceEngine {

    /// The most recent feature snapshot, or nil before the first recompute.
    private var features: EngineFeatures?
    /// The per-user fit derived from `features`.
    private var fit = Fit()
    /// The per-user end-of-day method track record, refreshed each recompute.
    private var eodAccuracy: EngineSelfEval.Accuracy?

    /// Per-user fitted state cached between scans. Holds the shapes that are
    /// expensive to derive (calibrators, the diurnal rate table); the cheap,
    /// time-dependent projection runs on read.
    struct Fit {
        /// Multiplicative conformal calibrators for the two end-of-day experts,
        /// each fit to that expert's own walk-forward residuals.
        var eodShapeCalibrator: ConformalCalibrator?
        var eodClockCalibrator: ConformalCalibrator?
        /// Fraction-of-day from which the learned hour-of-day shape robustly
        /// beats clock-linear on the user's own history. Below it the engine
        /// uses the simple line; at/above it, the learned shape. `.infinity`
        /// when the shape never robustly wins (so clock all day).
        var eodShapeCrossover: Double = .infinity
        var rl: [String: RateLimitFit] = [:]
        var normBands: [Int: UsageNorms.Band] = [:]
        /// Prior complete days' costs, zero-filled over gaps (for pace/anomaly).
        var dailyBaseline: [Double] = []
        /// Precomputed anomaly verdict for the most recent complete day.
        var anomaly: Estimate = .insufficient(method: "anomaly-z", note: "no history yet")
    }

    struct RateLimitFit {
        var roster: [any BurnTrajectory.Model]
        var selectedId: String?
        var calibrator: ConformalCalibrator?
        var duration: TimeInterval
        var historyCount: Int
    }

    // MARK: - Recompute (called on the scan tick)

    /// Rebuild the feature snapshot and refit every model from the live store.
    /// Cheap enough to run per scan: it reads pre-aggregated rows, not raw
    /// samples (save for a single most-recent token timestamp), and the fits
    /// are closed-form. Failures degrade to an empty fit rather than throwing.
    public func recompute(now: Date = Date(), calendar: Calendar = .current) {
        let f = EngineFeatures.build(
            now: now, calendar: calendar,
            daily: fetchDaily(),
            hourly: fetchHourly(),
            rate: fetchRate(now: now),
            lastArrivalAt: fetchLastArrival())
        self.features = f

        // Self-eval feedback loop: score any newly-completed days into the
        // persisted scoreboard (idempotent), then drive end-of-day selection
        // from the accumulated per-user track record — not a value recomputed
        // cold each launch. Empty store ⇒ no records ⇒ clock-only (safe).
        recordNewEODOutcomes(periods: f.dailyPeriods, calendar: calendar, now: now)
        let records = fetchEODRecords()
        self.eodAccuracy = EngineSelfEval.accuracy(from: records)
        self.fit = Self.makeFit(f, eodCrossover: EngineSelfEval.crossover(from: records))
    }

    /// Number of historical days the fit was trained on — for a future
    /// "the engine knows X days about you" affordance and for tests.
    public func trainingDayCount() -> Int { features?.dailyPeriods.count ?? 0 }

    /// How each end-of-day prediction method is doing on this user's own data —
    /// median absolute % error and how many completed days back it, best-first.
    /// `nil` before the first recompute; empty methods until some days complete.
    public func selfEvalAccuracy() -> EngineSelfEval.Accuracy? { eodAccuracy }

    // MARK: - Ask (the typed question → Estimate contract)

    /// Answer one question from the cached fit. Pure read — no store access.
    /// Returns an `insufficient` estimate (never throws, never a confident
    /// wrong number) when there isn't enough history yet.
    public func ask(_ question: EngineQuestion) -> Estimate {
        guard let f = features else {
            return .insufficient(method: "engine", note: "engine not warmed up yet")
        }
        return Self.answer(question, features: f, fit: fit)
    }

    /// The pure answer function — `(question, features, fit) → Estimate`. The
    /// actor's `ask` is a thin wrapper so this whole surface tests directly.
    static func answer(_ question: EngineQuestion, features f: EngineFeatures, fit: Fit) -> Estimate {
        switch question {
        case .projectedCost(.today):     return projectedCostToday(f, fit)
        case .projectedCost(.thisMonth): return MonthlyProjector.project(dailyCosts: f.dailyCosts, now: f.now, calendar: f.calendar)
        case .rateLimitOutlook(let w):   return rateLimitOutlook(f, fit, window: w)
        case .pace:                      return pace(f, fit)
        case .typicalUsage:              return typicalUsage(fit, weekday: f.calendar.component(.weekday, from: f.now))
        case .isAnomalous:               return fit.anomaly
        case .shortHorizon:              return shortHorizon(f, fit)
        }
    }

    // MARK: - End-of-day (+ idle/done gate)

    static func projectedCostToday(_ f: EngineFeatures, _ fit: Fit) -> Estimate {
        let input = ForecastInput(
            now: f.now, periodStart: f.todayStart,
            periodEnd: f.todayStart.addingTimeInterval(86400),
            calendar: f.calendar, elapsed: f.todayElapsed, priorPeriods: f.dailyPeriods)

        // Route to the expert that wins the user's own history at this cut.
        // On real data the learned shape only beats clock-linear once most of
        // the day is observed (evening); early on, the simple line is better,
        // so the engine uses it rather than over-projecting a noisy shape.
        let clock = clockEstimate(input, calibrator: fit.eodClockCalibrator, support: f.dailyPeriods.count)
        var routed = clock
        if input.elapsedFraction >= fit.eodShapeCrossover {
            let shape = RegimeGatedEOD().estimate(input, calibrator: fit.eodShapeCalibrator)
            // Past the crossover the shape can still decline on an unusually
            // quiet day — fall back to clock so we always answer.
            if !shape.isInsufficient { routed = shape }
        }
        return idleGate(routed, input: input, features: f)
    }

    /// The clock-linear (`soFar ÷ elapsed-fraction`) end-of-day estimate with a
    /// conformal band — the strong simple baseline, wrapped as an `Estimate`.
    static func clockEstimate(_ input: ForecastInput, calibrator: ConformalCalibrator?, support: Int) -> Estimate {
        guard let point = AverageRateForecaster().projectTotal(input), point > 0 else {
            return .insufficient(method: "eod-clock", note: "too early to project end-of-day", support: support)
        }
        let frac = input.elapsedFraction
        let confidence: Estimate.Confidence = frac < 0.3 ? .low : (frac < 0.6 ? .medium : .high)
        return Estimate(value: point,
                        interval80: calibrator?.interval(around: point, level: 0.8),
                        interval50: calibrator?.interval(around: point, level: 0.5),
                        method: "eod-clock", confidence: confidence, support: support,
                        note: frac < 0.3 ? "early in the day — lean on the range" : nil)
    }

    // MARK: - Rate-limit outlook

    static func rateLimitOutlook(_ f: EngineFeatures, _ fit: Fit, window: RateLimitWindowKind) -> Estimate {
        let key = window.rawValue
        guard let samples = f.rateLimit[key], let rf = fit.rl[key] else {
            return .insufficient(method: "rate-limit", note: "no rate-limit history yet")
        }
        let (currentOpt, _) = BurnTrajectory.segment(samples: samples, duration: rf.duration, now: f.now)
        guard let current = currentOpt else {
            return .insufficient(method: "rate-limit", note: "no live cycle")
        }
        let model = rf.roster.first { $0.id == rf.selectedId } ?? rf.roster.first
        guard let model, let projection = model.fit(current) else {
            return .insufficient(method: "rate-limit", note: "too early in the cycle to project", support: rf.historyCount)
        }
        let raw = projection(current.resetsAt)
        let point = min(100, max(current.usedNow, raw))
        let band80 = rf.calibrator?.interval(around: raw, level: 0.8).map { clampPct($0) }
        let band50 = rf.calibrator?.interval(around: raw, level: 0.5).map { clampPct($0) }

        let confidence: Estimate.Confidence
        if rf.historyCount < 3 { confidence = .low }
        else if current.durationHours > 0 && current.nowHours / current.durationHours < 0.3 { confidence = .low }
        else { confidence = .medium }

        // P(hitting 100%) is unlearnable for this user (one cap-hit in ~80 5h
        // cycles): never assert a hit, just flag it as rare when the projection
        // and history both sit low.
        let note = (point < 60 && raw < 90) ? "hitting the cap is rare for you" : nil
        return Estimate(value: point, interval80: band80, interval50: band50,
                        method: "rl-\(model.id)", confidence: confidence,
                        support: rf.historyCount, note: note)
    }

    // MARK: - Pace vs norm

    static func pace(_ f: EngineFeatures, _ fit: Fit) -> Estimate {
        let projected = projectedCostToday(f, fit).value
        guard projected.isFinite, !fit.dailyBaseline.isEmpty,
              let rank = UsageNorms.paceRank(value: projected, baseline: fit.dailyBaseline) else {
            return .insufficient(method: "pace-rank", note: "not enough history to judge pace",
                                 support: fit.dailyBaseline.count)
        }
        let note: String
        switch rank {
        case ..<0.25:  note = "quieter than usual"
        case ..<0.75:  note = "about normal"
        default:       note = "running hot"
        }
        let confidence: Estimate.Confidence = fit.dailyBaseline.count >= 14 ? .medium : .low
        return Estimate(value: rank, method: "pace-rank", confidence: confidence,
                        support: fit.dailyBaseline.count, note: note)
    }

    // MARK: - Typical usage / short horizon (norm bands)

    static func typicalUsage(_ fit: Fit, weekday: Int) -> Estimate {
        guard let band = fit.normBands[weekday] else {
            return .insufficient(method: "usage-norm", note: "not enough history for a typical range")
        }
        let confidence: Estimate.Confidence = band.count >= 8 ? .medium : .low
        return Estimate(value: band.typical, interval80: band.range80, interval50: band.range50,
                        method: "usage-norm", confidence: confidence, support: band.count,
                        note: "typical for this weekday")
    }

    static func shortHorizon(_ f: EngineFeatures, _ fit: Fit) -> Estimate {
        // Next-day estimate = the personal norm band for tomorrow's weekday.
        // The research is blunt that next-day point error is a property of the
        // data (~60%), not fixable — so present the band and a low confidence.
        guard let tomorrow = f.calendar.date(byAdding: .day, value: 1, to: f.now) else {
            return .insufficient(method: "short-horizon", note: "could not resolve tomorrow")
        }
        let wd = f.calendar.component(.weekday, from: tomorrow)
        guard let band = fit.normBands[wd] else {
            return .insufficient(method: "short-horizon", note: "not enough history for a next-day estimate")
        }
        return Estimate(value: band.typical, interval80: band.range80, interval50: band.range50,
                        method: "short-horizon", confidence: .low, support: band.count,
                        note: "next-day estimate — wide by nature")
    }

    // MARK: - Fitting (pure; testable without a store)

    /// Build the per-user fit. `eodCrossover` is the learned clock→shape switch
    /// fraction, resolved by `recompute` from the persisted self-eval scoreboard
    /// (`.infinity` = clock all day, the safe default before any track record).
    static func makeFit(_ f: EngineFeatures, eodCrossover: Double = .infinity) -> Fit {
        var fit = Fit()
        let shape = RegimeGatedEOD()
        let clock = AverageRateForecaster()
        fit.eodShapeCalibrator = eodCalibrator(model: shape, periods: f.dailyPeriods, calendar: f.calendar)
        fit.eodClockCalibrator = eodCalibrator(model: clock, periods: f.dailyPeriods, calendar: f.calendar)
        fit.eodShapeCrossover = eodCrossover

        // Norm bands + baselines from zero-filled prior complete days.
        let prior = priorDays(f)
        fit.dailyBaseline = prior.map { $0.cost }
        fit.normBands = normBands(prior)
        fit.anomaly = anomalyEstimate(prior)

        // Rate-limit fits per window.
        for window in RateLimitWindowKind.allCases {
            guard let samples = f.rateLimit[window.rawValue], !samples.isEmpty,
                  let duration = PaceMath.windowDuration(for: window.rawValue) else { continue }
            let (_, history) = BurnTrajectory.segment(samples: samples, duration: duration, now: f.now)

            // The 7-day window is where the diurnal idle structure lives; a 5h
            // window rarely straddles a day/night boundary (a measured null),
            // so it competes only the simple baselines there.
            var roster = BurnTrajectory.defaultModels
            if window == .sevenDay {
                let table = DiurnalBurnModel.rateTable(cycles: history, calendar: f.calendar, prior: f.activityGrid)
                roster.append(DiurnalBurnModel(rate: table, calendar: f.calendar))
            }

            let scores = BurnTrajectory.score(models: roster, cycles: history)
            let picked = ForecastSelector.select(
                scores: scores, policy: .init(minScoredCases: 6, minCoverage: 0.5)).id
            // Cold-start default: the diurnal model for 7d (it works off the
            // activity prior even with no completed cycles), recency-weighted
            // for 5h (tracks that window best on real data).
            let selectedId = picked ?? (window == .sevenDay ? "diurnal-rate" : "recency-weighted")
            let model = roster.first { $0.id == selectedId } ?? roster.first
            let calibrator = model.map { rateLimitCalibrator(model: $0, history: history, duration: duration) }

            fit.rl[window.rawValue] = RateLimitFit(
                roster: roster, selectedId: selectedId, calibrator: calibrator,
                duration: duration, historyCount: history.count)
        }
        return fit
    }

    /// Don't scale a near-done quiet day up by a back-loaded weekday shape.
    /// When the rest of today is typically idle *and* there's been no recent
    /// arrival, the day is effectively done — project end-of-day at what's
    /// already been spent (it can only edge up), rather than dividing a small
    /// spend by a small fraction and exploding. This is the EOD idle/done gate
    /// the activity-grid feature unlocks (deferred from PR3 for lack of the
    /// arrival stream).
    static let doneRemainingShareThreshold = 0.05
    static let doneIdleMinutes: Double = 120

    static func idleGate(_ scaled: Estimate, input: ForecastInput, features f: EngineFeatures) -> Estimate {
        let soFar = input.soFar
        guard soFar > 0 else { return scaled }
        let weekday = f.calendar.component(.weekday, from: f.now) - 1
        let hour = f.calendar.component(.hour, from: f.now)
        let remaining = EngineFeatures.remainingActivityShare(f.activityGrid, weekday: weekday, afterHour: hour)
        let idleMinutes = f.lastArrivalAt.map { f.now.timeIntervalSince($0) / 60 } ?? .infinity
        guard remaining < doneRemainingShareThreshold, idleMinutes > doneIdleMinutes else { return scaled }

        // Held estimate: the day can only edge up by the tiny remaining share.
        let hi = max(soFar * (1 + max(remaining, 0)), soFar)
        return Estimate(
            value: soFar,
            interval80: soFar...hi,
            interval50: soFar...(soFar * (1 + remaining / 2)),
            method: "eod-done-gate",
            confidence: scaled.isInsufficient ? .low : scaled.confidence,
            support: f.dailyPeriods.count,
            note: "today looks done — held at spend so far")
    }

    // MARK: - Norm / baseline helpers

    struct DayPoint { let weekday: Int; let cost: Double }

    /// Prior complete days (strictly before today), zero-filled over gap days,
    /// oldest → newest. Missing day = $0 is load-bearing (the anomalies on this
    /// user are lulls, not spikes), so gaps are real zeros, not skipped.
    static func priorDays(_ f: EngineFeatures) -> [DayPoint] {
        let todayKey = TokenSample.formatDate(f.now, timeZone: f.calendar.timeZone)
        guard let minKey = f.dailyCosts.keys.filter({ $0 < todayKey }).min(),
              let start = EngineFeatures.parseDay(minKey, calendar: f.calendar) else { return [] }
        var out: [DayPoint] = []
        var day = start
        while true {
            let key = TokenSample.formatDate(day, timeZone: f.calendar.timeZone)
            guard key < todayKey else { break }
            out.append(DayPoint(weekday: f.calendar.component(.weekday, from: day),
                                cost: f.dailyCosts[key] ?? 0))
            guard let next = f.calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }

    static func normBands(_ prior: [DayPoint]) -> [Int: UsageNorms.Band] {
        guard !prior.isEmpty else { return [:] }
        let samples = prior.map { (key: String($0.weekday), value: $0.cost) }
        let byKey = UsageNorms.bands(samples)
        var out: [Int: UsageNorms.Band] = [:]
        for (k, band) in byKey { if let wd = Int(k) { out[wd] = band } }
        return out
    }

    static func anomalyEstimate(_ prior: [DayPoint]) -> Estimate {
        guard let test = prior.last else {
            return .insufficient(method: "anomaly-z", note: "no complete day to judge yet")
        }
        let baseline = prior.dropLast().map { $0.cost }
        guard baseline.count >= 14 else {
            return .insufficient(method: "anomaly-z",
                                 note: "not enough history to judge what's normal yet",
                                 support: baseline.count)
        }
        let z = UsageNorms.anomalyZ(value: test.cost, baseline: baseline)
        let verdict = UsageNorms.classify(z: z)
        let note: String
        switch verdict {
        case .lull:   note = "lull — unusually quiet"
        case .spike:  note = "spike — unusually busy"
        case .normal: note = "normal"
        }
        return Estimate(value: z, method: "anomaly-z", confidence: .medium,
                        support: baseline.count, note: note)
    }

    /// Additive conformal calibrator for a rate-limit model: walk-forward over
    /// completed cycles, projecting the final at each cut, residual = truth −
    /// projection (percentage points).
    static func rateLimitCalibrator(
        model: any BurnTrajectory.Model,
        history: [BurnTrajectory.Cycle],
        duration: TimeInterval,
        cutFractions: [Double] = [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]
    ) -> ConformalCalibrator {
        var preds: [Double] = []
        var truths: [Double] = []
        for cycle in history {
            let trueFinal = cycle.samples.map { $0.usedPercentage }.max() ?? 0
            guard trueFinal > 0 else { continue }
            for cf in cutFractions {
                let cutNow = cycle.cycleStart.addingTimeInterval(duration * cf)
                let seen = cycle.samples.filter { $0.at <= cutNow }
                guard seen.count >= 3 else { continue }
                let partial = BurnTrajectory.PartialCycle(
                    samples: seen, now: cutNow, cycleStart: cycle.cycleStart, resetsAt: cycle.resetsAt)
                if let projection = model.fit(partial) {
                    preds.append(projection(cycle.resetsAt)); truths.append(trueFinal)
                }
            }
        }
        return ConformalCalibrator.fromPairs(mode: .additive, predictions: preds, truths: truths)
    }

    /// Multiplicative conformal calibrator for any end-of-day `Forecaster`,
    /// from its walk-forward residuals over the prior complete days: at each
    /// cut of each past day, project the day total using only earlier days and
    /// collect truth/prediction ratios. Leak-free.
    static func eodCalibrator(
        model: any Forecaster,
        periods: [ForecastInput.PriorPeriod],
        calendar: Calendar,
        cutFractions: [Double] = EngineSelfEval.cutFractions
    ) -> ConformalCalibrator {
        let sorted = periods.sorted { $0.start < $1.start }
        var preds: [Double] = []
        var truths: [Double] = []
        for (i, p) in sorted.enumerated() {
            let priors = Array(sorted[0..<i])
            guard !priors.isEmpty, p.total > 0 else { continue }
            let end = p.start.addingTimeInterval(86400)
            for cf in cutFractions {
                let now = p.start.addingTimeInterval(86400 * cf)
                let elapsed = p.points.filter { $0.at <= now }
                guard !elapsed.isEmpty else { continue }
                let input = ForecastInput(now: now, periodStart: p.start, periodEnd: end,
                                          calendar: calendar, elapsed: elapsed, priorPeriods: priors)
                if let pt = model.projectTotal(input), pt > 0 { preds.append(pt); truths.append(p.total) }
            }
        }
        return ConformalCalibrator.fromPairs(mode: .multiplicative, predictions: preds, truths: truths)
    }

    static func clampPct(_ r: ClosedRange<Double>) -> ClosedRange<Double> {
        let lo = min(100, max(0, r.lowerBound))
        let hi = min(100, max(0, r.upperBound))
        return lo...max(lo, hi)
    }

    // MARK: - Store reads

    private func fetchDaily() -> [EngineFeatures.DailyRow] {
        let rows = (try? modelContext.fetch(FetchDescriptor<DailyAggregate>())) ?? []
        return rows.map { .init(date: $0.date, cost: $0.totalCostUSD) }
    }

    private func fetchHourly() -> [EngineFeatures.HourlyRow] {
        let rows = (try? modelContext.fetch(FetchDescriptor<HourlyAggregate>())) ?? []
        return rows.map { .init(date: $0.date, hour: $0.hour, cost: $0.totalCostUSD, sampleCount: $0.sampleCount) }
    }

    /// ~32 days of rate-limit samples — enough to hold several complete 7-day
    /// cycles for the backtest while staying a small read.
    private func fetchRate(now: Date) -> [EngineFeatures.RateRow] {
        let cutoff = now.addingTimeInterval(-32 * 24 * 3600)
        let descriptor = FetchDescriptor<RateLimitSample>(
            predicate: #Predicate { $0.sampledAt >= cutoff },
            sortBy: [SortDescriptor(\.sampledAt, order: .forward)])
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        return rows.map { .init(window: $0.window, at: $0.sampledAt, usedPercentage: $0.usedPercentage, resetsAt: $0.resetsAt) }
    }

    private func fetchLastArrival() -> Date? {
        var descriptor = FetchDescriptor<TokenSample>(sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.sampledAt
    }

    // MARK: - Self-eval persistence

    private func fetchEODRecords() -> [EngineSelfEval.Record] {
        let surface = EngineSelfEval.surfaceEOD
        let descriptor = FetchDescriptor<EngineEvalOutcome>(predicate: #Predicate { $0.surface == surface })
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        return rows.map { .init(method: $0.method, bucket: $0.bucket, periodKey: $0.periodKey,
                                predicted: $0.predicted, truth: $0.truth) }
    }

    /// Score the prior complete days' candidates into persisted outcomes, once
    /// each (idempotent by key) — the standing re-score that grows the per-user
    /// track record on every scan.
    private func recordNewEODOutcomes(periods: [ForecastInput.PriorPeriod], calendar: Calendar, now: Date) {
        let surface = EngineSelfEval.surfaceEOD
        let descriptor = FetchDescriptor<EngineEvalOutcome>(predicate: #Predicate { $0.surface == surface })
        let existingKeys = Set((try? modelContext.fetch(descriptor))?.map { $0.key } ?? [])
        let news = EngineSelfEval.newOutcomesEOD(periods: periods, calendar: calendar, existingKeys: existingKeys)
        guard !news.isEmpty else { return }
        for n in news {
            modelContext.insert(EngineEvalOutcome(
                surface: n.surface, method: n.method, bucket: n.bucket, periodKey: n.periodKey,
                predicted: n.predicted, truth: n.truth, recordedAt: now))
        }
        try? modelContext.save()
    }
}
