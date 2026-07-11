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
    /// Projected final utilisation for a SCOPED per-model window, keyed by its
    /// `limits[]` identity (`kind|model|surface`). Same forecast/band treatment
    /// as `rateLimitOutlook`; the generic sibling for windows the server invents.
    case scopedOutlook(String)
    /// Today's projected spend as a percentile of the user's own daily norm.
    case pace
    /// Spend-so-far vs the user's typical spend **by this hour** on this kind
    /// of day (weekday/weekend regime). `value` is the multiple — 1.8 means
    /// "1.8× your usual Friday by now". The most insightful intraday number:
    /// it compares like-for-like at the same clock position instead of
    /// against a whole-day figure.
    case paceVsNow
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
    /// Per-surface method track records (end-of-day, rate-limit windows),
    /// refreshed each recompute.
    private var accuracyBySurface: [String: EngineSelfEval.Accuracy] = [:]
    /// Last prediction-snapshot written per surface (signature + when) — the
    /// change/heartbeat policy that keeps the trail from growing per tick.
    /// In-memory only: a relaunch writes one fresh row per surface, which
    /// doubles as a restart marker in the trail.
    private var lastSnapshotSig: [String: (at: Date, sig: String)] = [:]
    /// Local-day key of the last retention prune (prune once per day).
    private var lastSnapshotPruneDay: String?

    /// Per-user fitted state cached between scans. Holds the shapes that are
    /// expensive to derive (calibrators, the diurnal rate table); the cheap,
    /// time-dependent projection runs on read.
    struct Fit {
        /// Per-cut trimmed pool for the end-of-day point — at each cut
        /// fraction, the candidate ids whose accumulated per-cut record is
        /// near-best, ordered best-first. The point is the median of the
        /// members' live projections (combination over selection).
        var eodPools: [Int: [String]] = [:]
        /// Remainder-ratio normalized conformal bands, per cut bucket.
        var eodRemainder: RemainderConformal?
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
        /// Stratified additive conformal calibrators keyed
        /// `"early|weekday"`-style, plus the `"pooled"` fallback. Strata
        /// thinner than 10 scores aren't built — lookups fall back to pooled,
        /// per the merge-or-pool rule (validated: early-weekday coverage
        /// 0.64 → 0.80 with stratification; weekend strata correctly pool).
        var calibrators: [String: ConformalCalibrator] = [:]
        var duration: TimeInterval
        var historyCount: Int
        /// Natural-frequency facts over completed cycles, for honest risk
        /// phrasing ("topped 90% about 1 in 12 afternoons — never hit the cap").
        var cyclesObserved: Int = 0
        var cyclesPeakOver90: Int = 0
        var cyclesHit100: Int = 0
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

        // Self-eval feedback loop: score newly-completed periods into the
        // persisted scoreboard (idempotent), then drive selection from the
        // accumulated per-user track record — not a value recomputed cold each
        // launch. Empty store ⇒ no records ⇒ safe defaults.
        //
        // The eval table is fetched ONCE per refit and sliced in memory —
        // it holds thousands of rows, and the previous five separate fetches
        // (existing-keys ×2 + per-surface records ×3) were a measured ~0.4s
        // of every refit.
        var allRows = fetchAllEvalRows()
        let existing = Set(allRows.map { $0.key })
        let newEOD = EngineSelfEval.newOutcomesEOD(periods: f.dailyPeriods, calendar: calendar, existingKeys: existing)
        persist(newEOD, now: now)
        let newRL = newRLOutcomes(features: f, calendar: calendar, now: now, existingKeys: existing)
        persist(newRL, now: now)
        allRows.append(contentsOf: (newEOD + newRL).map {
            (key: EngineEvalOutcome.makeKey(surface: $0.surface, method: $0.method, bucket: $0.bucket, periodKey: $0.periodKey),
             surface: $0.surface, record: EngineSelfEval.Record(method: $0.method, bucket: $0.bucket, periodKey: $0.periodKey, predicted: $0.predicted, truth: $0.truth))
        })
        let bySurface = Dictionary(grouping: allRows, by: { $0.surface })
        func records(_ surface: String) -> [EngineSelfEval.Record] {
            (bySurface[surface] ?? []).map { $0.record }
        }

        let eodRecords = records(EngineSelfEval.surfaceEOD)
        accuracyBySurface[EngineSelfEval.surfaceEOD] = EngineSelfEval.accuracy(from: eodRecords)

        // Per-cut trimmed pools from the accumulated per-user record.
        var pools: [Int: [String]] = [:]
        for (ci, cf) in EngineSelfEval.cutFractions.enumerated() {
            pools[ci] = EngineSelfEval.poolMembers(forCut: cf, records: eodRecords)
        }

        // Evening track record: per evening cut, the best pool member's
        // realized errors — the "earned skill" number the UI footer shows.
        var eveningErrors: [Double] = []
        var eveningDays = Set<String>()
        for cf in EngineSelfEval.cutFractions where cf >= 0.75 {
            let bucket = "cut=\(String(format: "%.2f", cf))|all"
            guard let bestId = EngineSelfEval.poolMembers(forCut: cf, records: eodRecords).first else { continue }
            for r in eodRecords where r.bucket == bucket && r.method == bestId && r.truth > 0 {
                eveningErrors.append(r.absPctError)
                eveningDays.insert(r.periodKey)
            }
        }
        eveningRecord = eveningErrors.count >= 8
            ? TrackRecord(medianAbsPctError: EngineSelfEval.median(eveningErrors), days: eveningDays.count)
            : nil

        // Pick each rate-limit window's outlook model from its accumulated
        // record (the diurnal model now competes here on realized accuracy).
        // Iterates the generic window SET — fixed 5h/7d plus any scoped
        // per-model windows — each keyed by its own surface, so scoped windows
        // can never pollute the fixed windows' selection.
        var rlSelection: [String: String] = [:]
        for window in f.windows {
            let surface = EngineSelfEval.rlSurface(window.key)
            let recs = records(surface)
            accuracyBySurface[surface] = EngineSelfEval.accuracy(surface: surface, from: recs)
            if let pick = EngineSelfEval.bestMethod(from: recs, complexity: Self.rlComplexities(),
                                                    provisionalMinPeriods: Self.rlShadowFloors(duration: window.duration)) {
                rlSelection[window.key] = pick
            }
        }

        self.fit = Self.makeFit(f, eodPools: pools, rlSelection: rlSelection)

        // Prediction trail: record what this refit would tell the user —
        // the live answers with their bands, residual evidence, and version
        // tags — behind the change/heartbeat policy.
        recordPredictionSnapshots(f, now: now)
    }

    /// Number of historical days the fit was trained on — for a future
    /// "the engine knows X days about you" affordance and for tests.
    public func trainingDayCount() -> Int { features?.dailyPeriods.count ?? 0 }

    /// The evening track record — how close the engine's end-of-day answer has
    /// landed once most of the day is observed (cuts ≥ 0.75), as a
    /// median |error| % over the scored days. This is the honest number for a
    /// "how accurate has this been for you" affordance: the morning APE is a
    /// property of the data, the evening APE is the engine's earned skill.
    public struct TrackRecord: Sendable, Equatable {
        public let medianAbsPctError: Double
        public let days: Int
    }

    public func eveningTrackRecord() -> TrackRecord? { eveningRecord }
    private var eveningRecord: TrackRecord?

    /// Yesterday's realized cost and its rank among all complete days — for
    /// counting-statement copy ("your 3rd-highest day in 10 weeks") instead of
    /// indefensible smooth tail probabilities from ~50 points.
    public func yesterdayRank() -> (cost: Double, rankFromTop: Int, of: Int)? {
        guard let yesterday = fit.dailyBaseline.last, fit.dailyBaseline.count >= 7 else { return nil }
        let higher = fit.dailyBaseline.filter { $0 > yesterday }.count
        return (yesterday, higher + 1, fit.dailyBaseline.count)
    }

    /// How each prediction method is doing on this user's own data for a surface
    /// (`EngineSelfEval.surfaceEOD`, or `EngineSelfEval.rlSurface(window)`):
    /// median absolute % error and how many completed periods back it,
    /// best-first. `nil` before the first recompute or for an unscored surface.
    public func selfEvalAccuracy(surface: String = EngineSelfEval.surfaceEOD) -> EngineSelfEval.Accuracy? {
        accuracyBySurface[surface]
    }

    /// Roster complexities for a rate-limit window — so the persisted-scoreboard
    /// pick can break near-ties toward the simpler model. Window-agnostic (every
    /// window shares the one roster), so it takes no window argument.
    static func rlComplexities() -> [String: Int] {
        var c = Dictionary(uniqueKeysWithValues: BurnTrajectory.defaultModels.map { ($0.id, $0.complexity) })
        c["diurnal-rate"] = 3
        return c
    }

    /// The SHADOW candidates for a window and the promotion floor each must
    /// clear (completed periods in its scored record) before `bestMethod` may
    /// select it for display. Kalman is new everywhere; the diurnal model is
    /// established on weekly-cadence windows but a shadow on session-cadence
    /// ones — the 2026-06 backtest measured a null on the 5h block (session
    /// cycles rarely straddle a day/night boundary), and the shadow record
    /// re-tests that assumption instead of trusting it forever. Keyed off the
    /// window's *duration* (via `WindowSpec.isWeeklyScale`), so scoped per-model
    /// windows get the same rule with no new code — a scoped weekly cap treats
    /// diurnal as established, a scoped session cap as a shadow.
    public static func rlShadowFloors(duration: TimeInterval) -> [String: Int] {
        let floor = EngineParams.current.shadowPromotionMinPeriods
        var floors = ["kalman-trend": floor]
        if !WindowSpec.isWeeklyScale(duration: duration) { floors["diurnal-rate"] = floor }
        return floors
    }

    /// Enum-typed adapter for the fixed windows — preserved for the widget/UI/
    /// tests that ask by `RateLimitWindowKind`.
    public static func rlShadowFloors(_ window: RateLimitWindowKind) -> [String: Int] {
        rlShadowFloors(duration: WindowSpec.fixed(window).duration)
    }

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
        case .rateLimitOutlook(let w):   return rateLimitOutlook(f, fit, windowKey: w.rawValue)
        case .scopedOutlook(let key):    return rateLimitOutlook(f, fit, windowKey: key)
        case .pace:                      return pace(f, fit)
        case .paceVsNow:                 return paceVsNow(f)
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
        let fraction = input.elapsedFraction

        // Point: median of the cut's trimmed pool — the candidates whose
        // accumulated per-cut record on this user is near-best (combination
        // over selection, per the M4 evidence). On the real store the pooled
        // point beats or ties the old clock↔shape router at every cut.
        let bucketIdx = fit.eodRemainder?.bucketIndex(for: fraction)
            ?? EngineSelfEval.cutFractions.enumerated()
                .min { abs($0.element - fraction) < abs($1.element - fraction) }?.offset
        let memberIds = bucketIdx.flatMap { fit.eodPools[$0] } ?? EngineSelfEval.eodCandidates.map { $0.id }
        let instances = EngineSelfEval.eodCandidates
        let points = memberIds.compactMap { id -> Double? in
            guard let cand = instances.first(where: { $0.id == id }),
                  let p = cand.projectTotal(input), p.isFinite, p >= input.soFar * 0.999, p > 0
            else { return nil }
            return p
        }
        guard !points.isEmpty else {
            return idleGate(.insufficient(method: "eod-pool",
                                          note: "not enough history to project end-of-day",
                                          support: f.dailyPeriods.count),
                            input: input, features: f)
        }
        let point = EngineSelfEval.median(points)

        // Band: remainder-ratio normalized conformal at this cut — floored at
        // spend-so-far by construction, asymmetric for the right tail, and
        // width that tightens through the day as knowledge accrues.
        let band80 = fit.eodRemainder?.interval(fraction: fraction, point: point, spend: input.soFar, level: 0.8)
        let band50 = fit.eodRemainder?.interval(fraction: fraction, point: point, spend: input.soFar, level: 0.5)
        let support = fit.eodRemainder?.support(fraction: fraction) ?? 0

        // Confidence keyed to what the band actually says (the UX lexicon
        // pairs every confidence word with its evidence): wide-relative-to-
        // point or thin record → low; tight band on a solid record → high.
        let widthRatio = band80.map { ($0.upperBound - $0.lowerBound) / max(point, 0.01) } ?? .infinity
        let confidence: Estimate.Confidence
        if support < 10 || widthRatio > 2.5 { confidence = .low }
        else if widthRatio > 1.0 { confidence = .medium }
        else { confidence = .high }

        let note = fraction < 0.5 ? "early in the day — lean on the range" : nil
        let pooled = Estimate(value: point, interval80: band80, interval50: band50,
                              method: memberIds.count == 1 ? "eod-\(memberIds[0])" : "eod-pool",
                              confidence: confidence, support: support, note: note)
        return idleGate(pooled, input: input, features: f)
    }

    // MARK: - Rate-limit outlook

    static func rateLimitOutlook(_ f: EngineFeatures, _ fit: Fit, windowKey key: String) -> Estimate {
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
        // Live-value anchoring, matching burnOutlook/trajectories (shift up
        // only — smoothed fits can sit under a spiking last sample).
        let anchor = max(0, current.usedNow - projection(f.now))
        let raw = projection(current.resetsAt) + anchor
        let point = min(100, max(current.usedNow, raw))
        // Band from the stratum matching where we are in this cycle (early/
        // late × weekday/weekend), pooled fallback when the stratum was thin.
        let cutFraction = current.durationHours > 0 ? current.nowHours / current.durationHours : 1
        let calibrator = Self.rlCalibrator(rf, cutFraction: cutFraction, cycleStart: current.cycleStart, calendar: f.calendar)
        let minResiduals = EngineParams.current.conformalMinResiduals
        let band80 = calibrator?.interval(around: raw, level: 0.8, minResiduals: minResiduals).map { clampPct($0) }
        let band50 = calibrator?.interval(around: raw, level: 0.5, minResiduals: minResiduals).map { clampPct($0) }

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

    // MARK: - Burn outlook + trajectories (the chart / hero-tile / warning surface)

    /// "Will I hit the cap, and when" for one rate-limit window — the answer
    /// behind the hero tiles, the burn-rate notification, and the chart
    /// overlay's crossing marker. Unlike the old per-view math (a 90-minute
    /// linear slope for 5h, a recency-weighted slope for 7d), the crossing here
    /// comes from the engine's *selected* model for the window — for 7d that's
    /// typically the diurnal shape, which knows an overnight/weekend lull is
    /// coming and stops projecting "limit tonight" from one busy afternoon.
    public struct BurnOutlook: Sendable, Equatable {
        /// Descriptive recent slope (pp/hour) — "what just happened", so the
        /// user can sanity-check the number against their own activity.
        /// First-to-last over a per-window lookback (90 min for 5h, 24 h for 7d).
        public let slopePercentPerHour: Double
        /// First instant the selected model's projection crosses 100%, strictly
        /// before the reset. nil = the window resets first (or no signal).
        public let projectedFullAt: Date?
        public let etaSeconds: TimeInterval?
        /// Earliest-plausible crossing (the upper conformal band's crossing —
        /// "could hit as early as") and latest-plausible (lower band's). Nil
        /// when the shifted curve never crosses before reset, and BOTH nil
        /// when the calibrator lacks the residuals for an honest band
        /// (`gatedQuantile` declined) — detail surfaces then show the point
        /// alone instead of a saturated worst-case range.
        public let projectedFullAtEarliest: Date?
        public let projectedFullAtLatest: Date?
        public let usedPct: Double
        public let resetsAt: Date
        /// Upward shift that pinned the model curve to the live reading —
        /// recorded into prediction snapshots so a replay can separate model
        /// error from anchoring.
        public let anchorShift: Double
        /// Stable id of the model that produced the crossing (for affordances).
        public let method: String
        /// Natural-frequency facts over completed cycles, for honest risk
        /// copy: "topped 90% in N of M cycles — hit the cap H times".
        public let cyclesObserved: Int
        public let cyclesPeakOver90: Int
        public let cyclesHit100: Int
        public var willHitLimitBeforeReset: Bool { projectedFullAt != nil }
    }

    public func burnOutlook(window: RateLimitWindowKind) -> BurnOutlook? {
        guard let f = features else { return nil }
        return Self.burnOutlook(f, fit, windowKey: window.rawValue)
    }

    /// Generic sibling keyed by window identity — for scoped per-model windows.
    public func burnOutlook(windowKey key: String) -> BurnOutlook? {
        guard let f = features else { return nil }
        return Self.burnOutlook(f, fit, windowKey: key)
    }

    static func burnOutlook(_ f: EngineFeatures, _ fit: Fit, windowKey key: String) -> BurnOutlook? {
        guard let samples = f.rateLimit[key], let rf = fit.rl[key] else { return nil }
        let (currentOpt, _) = BurnTrajectory.segment(samples: samples, duration: rf.duration, now: f.now)
        guard let current = currentOpt, current.resetsAt > f.now else { return nil }

        // Descriptive slope over the recent lookback (clamped to this cycle so
        // a reset boundary can't produce a bogus negative). Session-cadence
        // windows read a 90-min lookback, weekly-cadence ones 24 h — derived
        // from the window's duration so it's identical for the fixed 5h/7d
        // blocks and correct for any scoped window.
        let lookback: TimeInterval = WindowSpec.isWeeklyScale(duration: rf.duration) ? 24 * 3600 : 90 * 60
        let cutoff = max(current.cycleStart, f.now.addingTimeInterval(-lookback))
        let recent = current.samples.filter { $0.at >= cutoff }
        var slope = 0.0
        if let first = recent.first, let last = recent.last,
           last.at.timeIntervalSince(first.at) >= 5 * 60 {
            slope = (last.usedPercentage - first.usedPercentage)
                / (last.at.timeIntervalSince(first.at) / 3600)
        }

        let model = rf.roster.first { $0.id == rf.selectedId } ?? rf.roster.first
        guard let model, let projection = model.fit(current) else {
            return BurnOutlook(slopePercentPerHour: slope, projectedFullAt: nil, etaSeconds: nil,
                               projectedFullAtEarliest: nil, projectedFullAtLatest: nil,
                               usedPct: current.usedNow, resetsAt: current.resetsAt,
                               anchorShift: 0, method: "none",
                               cyclesObserved: rf.cyclesObserved,
                               cyclesPeakOver90: rf.cyclesPeakOver90, cyclesHit100: rf.cyclesHit100)
        }
        // Anchor the curve to the live value: the smoothed fits (recency-
        // weighted, saturating) deliberately sit under a spiking last sample,
        // so the raw projection can start BELOW where the user currently is —
        // which on the chart reads as the forecast dipping under the dot.
        // Shift up only, never down.
        let anchor = max(0, current.usedNow - projection(f.now))

        // Crossings before the reset, walked in 5-minute steps (the sampling
        // cadence — finer adds nothing). The point crossing comes from the
        // model curve; the earliest/latest plausible from the curve shifted by
        // the stratified conformal band (monotone inversion: P(hit by t) =
        // P(U(t) ≥ 100), so the band's crossings ARE the hit-time range).
        // Already-at-100% suppresses the ETA: the tile shows the state directly.
        var crossing: Date?, earliest: Date?, latest: Date?
        if current.usedNow < 100 {
            let cutFraction = current.durationHours > 0 ? current.nowHours / current.durationHours : 1
            let calibrator = Self.rlCalibrator(rf, cutFraction: cutFraction, cycleStart: current.cycleStart, calendar: f.calendar)
            // Band shifts are GATED on residual count (mirrors `interval()`):
            // a 7-day calibrator built from ~5 completed cycles saturates to
            // its most extreme residual and the "range" degenerates to
            // "5 min – 32 hr". No honest band ⇒ earliest/latest stay nil and
            // the surfaces show the point crossing alone.
            let minResiduals = EngineParams.current.conformalMinResiduals
            let hiShift = calibrator?.gatedQuantile(0.9, minResiduals: minResiduals)   // upper band → earliest plausible
            let loShift = calibrator?.gatedQuantile(0.1, minResiduals: minResiduals)   // lower band → latest plausible
            var t = f.now.addingTimeInterval(5 * 60)
            while t <= current.resetsAt {
                let p = projection(t) + anchor
                if let hiShift, earliest == nil, p + max(hiShift, 0) >= 100 { earliest = t }
                if crossing == nil, p >= 100 { crossing = t }
                if let loShift, latest == nil, p + min(loShift, 0) >= 100 { latest = t }
                if earliest != nil || hiShift == nil, crossing != nil, latest != nil || loShift == nil { break }
                t = t.addingTimeInterval(5 * 60)
            }
        }
        return BurnOutlook(
            slopePercentPerHour: slope,
            projectedFullAt: crossing,
            etaSeconds: crossing.map { $0.timeIntervalSince(f.now) },
            projectedFullAtEarliest: earliest,
            projectedFullAtLatest: latest,
            usedPct: current.usedNow,
            resetsAt: current.resetsAt,
            anchorShift: anchor,
            method: model.id,
            cyclesObserved: rf.cyclesObserved,
            cyclesPeakOver90: rf.cyclesPeakOver90,
            cyclesHit100: rf.cyclesHit100)
    }

    /// The calibrator for a cycle position: its stratum's, else pooled.
    static func rlCalibrator(_ rf: RateLimitFit, cutFraction: Double, cycleStart: Date, calendar: Calendar) -> ConformalCalibrator? {
        let key = rlStratum(cutFraction: cutFraction, cycleStart: cycleStart, calendar: calendar)
        return rf.calibrators[key] ?? rf.calibrators["pooled"]
    }

    /// The compact outlook export the widgets read (they can't reach this
    /// actor from their process). Trajectories downsampled to ≤24 points and
    /// already truncated at the crossing.
    public func snapshot() -> EngineSnapshot {
        func windowOutlook(_ window: RateLimitWindowKind) -> EngineSnapshot.WindowOutlook? {
            let key = window.rawValue
            guard let f = features, let o = Self.burnOutlook(f, fit, windowKey: key) else { return nil }
            let end = Self.rateLimitOutlook(f, fit, windowKey: key)
            let selected = Self.rateLimitTrajectories(f, fit, windowKey: key, accuracy: nil, sampleCount: 24)
                .first { $0.isSelected }
            return EngineSnapshot.WindowOutlook(
                usedPct: o.usedPct,
                endPct: end.isInsufficient ? nil : end.value,
                endLoPct: end.interval80?.lowerBound,
                endHiPct: end.interval80?.upperBound,
                crossingUnix: o.projectedFullAt?.timeIntervalSince1970,
                resetsUnix: o.resetsAt.timeIntervalSince1970,
                trajectory: (selected?.trajectory.points ?? []).map {
                    .init(t: $0.at.timeIntervalSince1970, v: $0.usedPercentage)
                })
        }
        func costOutlook() -> EngineSnapshot.CostOutlook? {
            guard let f = features else { return nil }
            let today = Self.projectedCostToday(f, fit)
            let month = MonthlyProjector.project(dailyCosts: f.dailyCosts, now: f.now, calendar: f.calendar)
            let pace = Self.pace(f, fit)
            return EngineSnapshot.CostOutlook(
                projectedTodayUSD: today.isInsufficient ? nil : today.value,
                projectedTodayLoUSD: today.interval80?.lowerBound,
                projectedTodayHiUSD: today.interval80?.upperBound,
                projectedMonthUSD: month.isInsufficient ? nil : month.value,
                projectedMonthLoUSD: month.interval80?.lowerBound,
                projectedMonthHiUSD: month.interval80?.upperBound,
                pacePercentile: pace.isInsufficient ? nil : pace.value,
                paceNote: pace.isInsufficient ? nil : pace.note)
        }
        return EngineSnapshot(
            generatedUnix: Date().timeIntervalSince1970,
            fiveHour: windowOutlook(.fiveHour),
            sevenDay: windowOutlook(.sevenDay),
            cost: costOutlook())
    }

    /// Every candidate model's forward trajectory for a window's current cycle,
    /// paired with its realized accuracy from the persisted per-user record and
    /// flagged with the engine's selection — one source of truth for the pace
    /// chart's overlay (take the selected one) and the compare-models sheet
    /// (show them all).
    public func rateLimitTrajectories(window: RateLimitWindowKind) -> [BurnTrajectory.ScoredTrajectory] {
        rateLimitTrajectories(windowKey: window.rawValue)
    }

    /// Generic sibling keyed by window identity — for scoped per-model windows.
    public func rateLimitTrajectories(windowKey key: String) -> [BurnTrajectory.ScoredTrajectory] {
        guard let f = features else { return [] }
        let accuracy = accuracyBySurface[EngineSelfEval.rlSurface(key)]
        return Self.rateLimitTrajectories(f, fit, windowKey: key, accuracy: accuracy)
    }

    static func rateLimitTrajectories(
        _ f: EngineFeatures, _ fit: Fit, windowKey key: String,
        accuracy: EngineSelfEval.Accuracy?, sampleCount: Int = 48
    ) -> [BurnTrajectory.ScoredTrajectory] {
        guard let samples = f.rateLimit[key], let rf = fit.rl[key] else { return [] }
        let (currentOpt, _) = BurnTrajectory.segment(samples: samples, duration: rf.duration, now: f.now)
        guard let current = currentOpt else { return [] }
        let span = current.resetsAt.timeIntervalSince(f.now)
        guard span > 0 else { return [] }

        let statFor = { (id: String) -> EngineSelfEval.Accuracy.MethodStat? in
            accuracy?.methods.first { $0.method == id }
        }
        return rf.roster.compactMap { model -> BurnTrajectory.ScoredTrajectory? in
            guard let projection = model.fit(current) else { return nil }
            // Anchor to the live value (same rule as `burnOutlook`): smoothed
            // fits sit under a spiking last sample, and an un-anchored curve
            // starts BELOW the user's current dot on the chart. Shift up only.
            let anchor = max(0, current.usedNow - projection(f.now))
            // Crossing walked at the 5-minute sampling cadence — same walk as
            // `burnOutlook`, so the chart's marker and the tile's ETA agree.
            var crossing: Date?
            if current.usedNow < 100 {
                var t = f.now.addingTimeInterval(5 * 60)
                while t <= current.resetsAt {
                    if projection(t) + anchor >= 100 { crossing = t; break }
                    t = t.addingTimeInterval(5 * 60)
                }
            }
            // The trajectory ENDS at the crossing: a dashed line pinned at
            // 100% for the rest of the window is noise — the curve already
            // said everything at the moment it touched the cap. The first
            // point is pinned to the live value so the dashed line continues
            // the solid one without a step.
            var points: [BurnTrajectory.Sample] = [.init(at: f.now, usedPercentage: current.usedNow)]
            for i in 1...sampleCount {
                let date = f.now.addingTimeInterval(span * Double(i) / Double(sampleCount))
                if let crossing, date >= crossing {
                    points.append(.init(at: crossing, usedPercentage: 100))
                    break
                }
                points.append(.init(at: date, usedPercentage: min(100, max(0, projection(date) + anchor))))
            }
            let stat = statFor(model.id)
            return BurnTrajectory.ScoredTrajectory(
                modelId: model.id, complexity: model.complexity,
                trajectory: .init(modelId: model.id, points: points, crossesFullAt: crossing),
                medianAbsError: stat?.medianAbsError ?? .infinity,
                coverage: stat == nil ? 0 : 1,
                isSelected: model.id == rf.selectedId)
        }
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

    /// Spend-so-far ÷ the median historical spend **by this hour** on this
    /// day-regime. Regime-matched with a pooled fallback (same rule as the
    /// pickup forecaster); insufficient when the typical-by-now figure is too
    /// small to divide by honestly (pre-dawn — everyone's at ~$0, so any
    /// spend would read as an absurd multiple).
    static func paceVsNow(_ f: EngineFeatures) -> Estimate {
        let hour = min(23, max(0, f.calendar.component(.hour, from: f.now)))
        let regime = DayRegime.of(f.now, calendar: f.calendar)
        var regimeCums: [Double] = []
        var pooledCums: [Double] = []
        for p in f.dailyPeriods {
            guard let costs = p.cachedHourlyCosts else { continue }
            let cum = costs[0...hour].reduce(0, +)
            pooledCums.append(cum)
            if DayRegime.of(p.start, calendar: f.calendar) == regime { regimeCums.append(cum) }
        }
        let cums = regimeCums.count >= 5 ? regimeCums : pooledCums
        guard cums.count >= 7 else {
            return .insufficient(method: "pace-vs-now", note: "not enough history yet", support: cums.count)
        }
        let typicalByNow = EngineSelfEval.median(cums)
        let typicalDay = EngineSelfEval.median(cums.isEmpty ? [0] : f.dailyPeriods.map { $0.total })
        // Below ~2% of a typical day (or under a dollar) the denominator is
        // noise — a $3 pre-dawn spend shouldn't render as "40× usual".
        guard typicalByNow >= max(1.0, typicalDay * 0.02) else {
            return .insufficient(method: "pace-vs-now",
                                 note: "too early on this kind of day to compare", support: cums.count)
        }
        let soFar = f.todayElapsed.last?.cumulative ?? 0
        let ratio = soFar / typicalByNow
        return Estimate(value: ratio, method: "pace-vs-now",
                        confidence: cums.count >= 14 ? .medium : .low,
                        support: cums.count,
                        note: regime == .weekend ? "vs your usual weekend by now" : "vs your usual weekday by now")
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

    /// Build the per-user fit. `eodPools` are the per-cut trimmed pools
    /// resolved by `recompute` from the persisted self-eval scoreboard
    /// (empty = median-of-all-candidates, the safe cold-start prior).
    static func makeFit(_ f: EngineFeatures, eodPools: [Int: [String]] = [:], rlSelection: [String: String] = [:]) -> Fit {
        var fit = Fit()
        fit.eodPools = eodPools
        fit.eodRemainder = eodRemainderCalibrator(periods: f.dailyPeriods, calendar: f.calendar, pools: eodPools)

        // Norm bands + baselines from zero-filled prior complete days.
        let prior = priorDays(f)
        fit.dailyBaseline = prior.map { $0.cost }
        fit.normBands = normBands(prior)
        fit.anomaly = anomalyEstimate(prior)

        // Rate-limit fits per window — the generic window SET (fixed 5h/7d plus
        // any scoped per-model windows). Each spec carries its own `(key,
        // duration)`; the pure math below is identical across windows.
        for window in f.windows {
            let key = window.key
            let duration = window.duration
            guard let samples = f.rateLimit[key], !samples.isEmpty else { continue }
            let (_, history) = BurnTrajectory.segment(samples: samples, duration: duration, now: f.now)

            // The diurnal model competes on every window: established on
            // weekly-cadence windows (where the idle structure lives), a
            // promotion-gated SHADOW on session-cadence ones — the 2026-06
            // "measured null" on the 5h block gets re-tested by the accumulating
            // record instead of trusted forever.
            var roster = BurnTrajectory.defaultModels
            let table = DiurnalBurnModel.rateTable(cycles: history, calendar: f.calendar, prior: f.activityGrid)
            roster.append(DiurnalBurnModel(rate: table, calendar: f.calendar))

            // Prefer the accumulated per-user track record (`rlSelection`);
            // fall back to a cold on-the-fly backtest, then a hardcoded default
            // (diurnal for weekly-cadence windows — it works off the activity
            // prior even with no completed cycles — recency-weighted for
            // session-cadence ones). The cold backtest runs ONLY when the record
            // can't pick: it scores every model over every cycle (for the
            // diurnal model that's a forward integration per scored point),
            // which is most of a refit's cost — paying it each tick when the
            // record already decided was the 1.4s refit.
            let selectedId: String
            if let learned = rlSelection[key] {
                selectedId = learned
            } else {
                // Cold start never displays a shadow candidate — the whole
                // point of the promotion floor is that new models earn
                // display from the persisted record, not a cold backtest.
                let shadowIds = Set(Self.rlShadowFloors(duration: duration).keys)
                let scores = BurnTrajectory.score(models: roster.filter { !shadowIds.contains($0.id) },
                                                  cycles: history)
                selectedId = ForecastSelector.select(
                    scores: scores, policy: .init(minScoredCases: 6, minCoverage: 0.5)).id
                    ?? (WindowSpec.isWeeklyScale(duration: duration) ? "diurnal-rate" : "recency-weighted")
            }
            let model = roster.first { $0.id == selectedId } ?? roster.first

            // Cap-hit frequency facts over completed cycles (for honest
            // natural-frequency risk phrasing in the UI).
            var over90 = 0, hit100 = 0
            for c in history {
                let peak = c.samples.map { $0.usedPercentage }.max() ?? 0
                if peak >= 90 { over90 += 1 }
                if peak >= 100 { hit100 += 1 }
            }

            fit.rl[key] = RateLimitFit(
                roster: roster, selectedId: selectedId,
                calibrators: model.map { stratifiedRLCalibrators(model: $0, history: history, duration: duration, calendar: f.calendar) } ?? [:],
                duration: duration, historyCount: history.count,
                cyclesObserved: history.count, cyclesPeakOver90: over90, cyclesHit100: hit100)
        }
        return fit
    }

    /// Remainder-ratio conformal calibration: walk-forward of the SAME pooled
    /// pipeline the live answer uses (per-cut members, median of projections),
    /// one nonnegative score per (day, cut). Leak-free — each day's pipeline
    /// is fit only on earlier days.
    static func eodRemainderCalibrator(
        periods: [ForecastInput.PriorPeriod],
        calendar: Calendar,
        pools: [Int: [String]]
    ) -> RemainderConformal {
        let sorted = periods.sorted { $0.start < $1.start }
        let candidates = EngineSelfEval.eodCandidates
        let cuts = EngineSelfEval.cutFractions
        return RemainderConformal.calibrate(
            dayCount: sorted.count,
            cutFractions: cuts,
            truth: { sorted[$0].total },
            pointAndSpend: { di, cf in
                let p = sorted[di]
                let priors = Array(sorted[0..<di])
                guard !priors.isEmpty else { return nil }
                let now = p.start.addingTimeInterval(86400 * cf)
                let elapsed = p.points.filter { $0.at <= now }
                let input = ForecastInput(now: now, periodStart: p.start,
                                          periodEnd: p.start.addingTimeInterval(86400),
                                          calendar: calendar, elapsed: elapsed, priorPeriods: priors)
                let ci = cuts.enumerated().min { abs($0.element - cf) < abs($1.element - cf) }?.offset
                let memberIds = ci.flatMap { pools[$0] } ?? candidates.map { $0.id }
                let pts = memberIds.compactMap { id -> Double? in
                    guard let cand = candidates.first(where: { $0.id == id }),
                          let v = cand.projectTotal(input), v.isFinite, v > 0 else { return nil }
                    return v
                }
                guard !pts.isEmpty else { return nil }
                return (EngineSelfEval.median(pts), input.soFar)
            })
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
    /// Stratum key for a rate-limit cut: window phase (early/late at half the
    /// cycle) × day regime of the cycle's start. Validated on the real store:
    /// early-weekday coverage moved 0.64 → 0.80 with stratification while thin
    /// weekend strata correctly fall back to pooled.
    static func rlStratum(cutFraction: Double, cycleStart: Date, calendar: Calendar) -> String {
        let phase = cutFraction < 0.5 ? "early" : "late"
        let regime = DayRegime.of(cycleStart, calendar: calendar)
        return "\(phase)|\(regime.rawValue)"
    }
    /// A stratum needs this many scores to stand alone; thinner ones pool.
    /// Lives in `EngineParams` (the versioned, harness-sweepable set).
    static var rlStratumMinScores: Int { EngineParams.current.rlStratumMinScores }

    /// Stratified additive conformal calibrators for a rate-limit model:
    /// walk-forward over completed cycles, residual = truth − projection
    /// (percentage points), bucketed by `rlStratum` with a `"pooled"` fallback
    /// always present.
    ///
    /// **Per-cycle blocks below `conformalBlockMinCycles`:** residuals from
    /// one cycle's eight cuts are strongly correlated (a heavy week blows all
    /// of them at once), so counting them separately overstates the effective
    /// sample — on the 7d window's thin history that produced 80% bands with
    /// 12% realized coverage. With few cycles each cycle therefore
    /// contributes its MEDIAN residual per bucket (effective n = cycles,
    /// honest); with plentiful cycles the within-cycle spread is real tail
    /// information and per-cut counting resumes (5h holds 0.785 coverage).
    /// Validated fold-robust in research/harness (2026-07-06).
    static func stratifiedRLCalibrators(
        model: any BurnTrajectory.Model,
        history: [BurnTrajectory.Cycle],
        duration: TimeInterval,
        calendar: Calendar,
        cutFractions: [Double] = [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]
    ) -> [String: ConformalCalibrator] {
        // (cycle index, residual) pairs per bucket, then grouped per the rule.
        var byStratum: [String: [(cycle: Int, residual: Double)]] = [:]
        var pooled: [(cycle: Int, residual: Double)] = []
        for (ci, cycle) in history.enumerated() {
            let trueFinal = cycle.samples.map { $0.usedPercentage }.max() ?? 0
            guard trueFinal > 0 else { continue }
            for cf in cutFractions {
                let cutNow = cycle.cycleStart.addingTimeInterval(duration * cf)
                let seen = cycle.samples.filter { $0.at <= cutNow }
                guard seen.count >= 3 else { continue }
                let partial = BurnTrajectory.PartialCycle(
                    samples: seen, now: cutNow, cycleStart: cycle.cycleStart, resetsAt: cycle.resetsAt)
                guard let projection = model.fit(partial) else { continue }
                let residual = trueFinal - projection(cycle.resetsAt)
                pooled.append((ci, residual))
                byStratum[rlStratum(cutFraction: cf, cycleStart: cycle.cycleStart, calendar: calendar), default: []].append((ci, residual))
            }
        }
        let blocks = history.count < EngineParams.current.conformalBlockMinCycles
        func residuals(_ pairs: [(cycle: Int, residual: Double)]) -> [Double] {
            guard blocks else { return pairs.map { $0.residual } }
            let byCycle = Dictionary(grouping: pairs, by: { $0.cycle })
            return byCycle.values.map { EngineSelfEval.median($0.map { $0.residual }) }
        }
        var out: [String: ConformalCalibrator] = ["pooled": ConformalCalibrator(mode: .additive, residuals: residuals(pooled))]
        for (key, pairs) in byStratum {
            let rs = residuals(pairs)
            if rs.count >= rlStratumMinScores {
                out[key] = ConformalCalibrator(mode: .additive, residuals: rs)
            }
        }
        return out
    }

    static func clampPct(_ r: ClosedRange<Double>) -> ClosedRange<Double> {
        let lo = min(100, max(0, r.lowerBound))
        let hi = min(100, max(0, r.upperBound))
        return lo...max(lo, hi)
    }

    // MARK: - Prediction snapshot trail

    /// A not-yet-persisted `PredictionSnapshot` — pure output of
    /// `snapshotDrafts`, so the whole surface tests without a container.
    struct SnapshotDraft {
        let surface: String
        let method: String
        let periodKey: String
        let periodEnd: Date?
        let value: Double?
        let lo80: Double?, hi80: Double?
        let lo50: Double?, hi50: Double?
        let confidence: String
        let support: Int
        let note: String?
        var crossingAt: Date?
        var crossingEarliest: Date?
        var crossingLatest: Date?
        var usedPct: Double?
        var anchorShift: Double?
        var slopePercentPerHour: Double?
        var bandStratum: String?
        var residualCount: Int?
        var spendSoFar: Double?

        /// The row's identity at DISPLAY precision: a new row is worth writing
        /// exactly when the user-visible facts would change (utilisation to
        /// the whole point, dollars to 2 significant figures, crossings to
        /// the 15-minute bucket). Everything else re-records on the heartbeat.
        var signature: String {
            func pp(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "-" }
            func sig2(_ v: Double?) -> String {
                guard let v, v.isFinite else { return "-" }
                guard v > 0 else { return String(v) }
                let mag = pow(10, floor(log10(v)) - 1)
                return String(Int((v / mag).rounded() * mag))
            }
            func t(_ d: Date?) -> String { d.map { String(Int($0.timeIntervalSince1970 / 900)) } ?? "-" }
            let isCost = surface == EngineSelfEval.surfaceEOD || surface == "month"
            let v = isCost ? sig2 : pp
            return [surface, method, confidence, periodKey,
                    v(value), v(lo80), v(hi80),
                    t(crossingAt), t(crossingEarliest), t(crossingLatest)].joined(separator: "|")
        }
    }

    /// Even an unchanged prediction re-records this often, so the trail shows
    /// "still saying X" rather than a gap.
    static let snapshotHeartbeat: TimeInterval = 30 * 60

    /// One draft per live surface — the same answers the views ask for, with
    /// the band-evidence facts (stratum, residual count) the views don't show.
    static func snapshotDrafts(_ f: EngineFeatures, _ fit: Fit) -> [SnapshotDraft] {
        var out: [SnapshotDraft] = []
        for window in f.windows {
            let key = window.key
            guard let o = burnOutlook(f, fit, windowKey: key) else { continue }
            let est = rateLimitOutlook(f, fit, windowKey: key)
            var stratum: String?
            var residuals: Int?
            if let samples = f.rateLimit[key], let rf = fit.rl[key],
               case let (currentOpt, _) = BurnTrajectory.segment(samples: samples, duration: rf.duration, now: f.now),
               let current = currentOpt {
                let cutFraction = current.durationHours > 0 ? current.nowHours / current.durationHours : 1
                let stratumKey = rlStratum(cutFraction: cutFraction, cycleStart: current.cycleStart, calendar: f.calendar)
                if let cal = rf.calibrators[stratumKey] { stratum = stratumKey; residuals = cal.count }
                else if let pooled = rf.calibrators["pooled"] { stratum = "pooled"; residuals = pooled.count }
            }
            out.append(SnapshotDraft(
                surface: EngineSelfEval.rlSurface(key), method: o.method,
                periodKey: EngineSelfEval.periodKeyRL(o.resetsAt), periodEnd: o.resetsAt,
                value: est.isInsufficient ? nil : est.value,
                lo80: est.interval80?.lowerBound, hi80: est.interval80?.upperBound,
                lo50: est.interval50?.lowerBound, hi50: est.interval50?.upperBound,
                confidence: est.confidence.rawValue, support: est.support, note: est.note,
                crossingAt: o.projectedFullAt,
                crossingEarliest: o.projectedFullAtEarliest,
                crossingLatest: o.projectedFullAtLatest,
                usedPct: o.usedPct, anchorShift: o.anchorShift,
                slopePercentPerHour: o.slopePercentPerHour,
                bandStratum: stratum, residualCount: residuals))
        }

        let todayKey = TokenSample.formatDate(f.now, timeZone: f.calendar.timeZone)
        let eod = projectedCostToday(f, fit)
        out.append(SnapshotDraft(
            surface: EngineSelfEval.surfaceEOD, method: eod.method,
            periodKey: todayKey, periodEnd: f.todayStart.addingTimeInterval(86400),
            value: eod.isInsufficient ? nil : eod.value,
            lo80: eod.interval80?.lowerBound, hi80: eod.interval80?.upperBound,
            lo50: eod.interval50?.lowerBound, hi50: eod.interval50?.upperBound,
            confidence: eod.confidence.rawValue, support: eod.support, note: eod.note,
            spendSoFar: f.todayElapsed.last?.cumulative ?? 0))

        let month = MonthlyProjector.project(dailyCosts: f.dailyCosts, now: f.now, calendar: f.calendar)
        out.append(SnapshotDraft(
            surface: "month", method: month.method,
            periodKey: String(todayKey.prefix(7)),
            periodEnd: f.calendar.dateInterval(of: .month, for: f.now)?.end,
            value: month.isInsufficient ? nil : month.value,
            lo80: month.interval80?.lowerBound, hi80: month.interval80?.upperBound,
            lo50: month.interval50?.lowerBound, hi50: month.interval50?.upperBound,
            confidence: month.confidence.rawValue, support: month.support, note: month.note))
        return out
    }

    /// Change/heartbeat write policy — pure, so the policy tests directly.
    static func shouldRecordSnapshot(prev: (at: Date, sig: String)?, now: Date, signature: String) -> Bool {
        guard let prev else { return true }
        return prev.sig != signature || now.timeIntervalSince(prev.at) >= snapshotHeartbeat
    }

    private func recordPredictionSnapshots(_ f: EngineFeatures, now: Date) {
        let engineVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        var dirty = false
        for d in Self.snapshotDrafts(f, fit) {
            let sig = d.signature
            guard Self.shouldRecordSnapshot(prev: lastSnapshotSig[d.surface], now: now, signature: sig) else { continue }
            modelContext.insert(PredictionSnapshot(
                recordedAt: now, surface: d.surface, method: d.method,
                paramsVersion: EngineParams.version, engineVersion: engineVersion,
                periodKey: d.periodKey, periodEnd: d.periodEnd,
                value: d.value, lo80: d.lo80, hi80: d.hi80, lo50: d.lo50, hi50: d.hi50,
                confidence: d.confidence, support: d.support, note: d.note,
                crossingAt: d.crossingAt, crossingEarliest: d.crossingEarliest,
                crossingLatest: d.crossingLatest, usedPct: d.usedPct,
                anchorShift: d.anchorShift, slopePercentPerHour: d.slopePercentPerHour,
                bandStratum: d.bandStratum, residualCount: d.residualCount,
                spendSoFar: d.spendSoFar))
            lastSnapshotSig[d.surface] = (now, sig)
            dirty = true
        }

        // Retention: once per local day, drop rows past the horizon. The
        // eval table keeps the accuracy record forever; this is the
        // high-resolution trail and 180 days of it is plenty for replay.
        let dayKey = TokenSample.formatDate(now, timeZone: f.calendar.timeZone)
        if lastSnapshotPruneDay != dayKey {
            lastSnapshotPruneDay = dayKey
            let cutoff = now.addingTimeInterval(-Double(PredictionSnapshot.retentionDays) * 86400)
            try? modelContext.delete(model: PredictionSnapshot.self,
                                     where: #Predicate { $0.recordedAt < cutoff })
            dirty = true
        }
        if dirty { try? modelContext.save() }
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

    /// One pass over the whole eval table — `recompute` slices it in memory.
    private func fetchAllEvalRows() -> [(key: String, surface: String, record: EngineSelfEval.Record)] {
        let rows = (try? modelContext.fetch(FetchDescriptor<EngineEvalOutcome>())) ?? []
        return rows.map {
            ($0.key, $0.surface,
             EngineSelfEval.Record(method: $0.method, bucket: $0.bucket, periodKey: $0.periodKey,
                                   predicted: $0.predicted, truth: $0.truth))
        }
    }

    private func persist(_ news: [EngineSelfEval.NewOutcome], now: Date) {
        guard !news.isEmpty else { return }
        for n in news {
            modelContext.insert(EngineEvalOutcome(
                surface: n.surface, method: n.method, bucket: n.bucket, periodKey: n.periodKey,
                predicted: n.predicted, truth: n.truth, recordedAt: now))
        }
        try? modelContext.save()
    }

    /// Score each rate-limit window's roster over its newly-completed cycles —
    /// the standing re-score that grows the per-user track record. Pure apart
    /// from segmenting; the caller persists.
    private func newRLOutcomes(features f: EngineFeatures, calendar: Calendar, now: Date,
                               existingKeys: Set<String>) -> [EngineSelfEval.NewOutcome] {
        var out: [EngineSelfEval.NewOutcome] = []
        for window in f.windows {
            guard let samples = f.rateLimit[window.key], !samples.isEmpty else { continue }
            let (_, history) = BurnTrajectory.segment(samples: samples, duration: window.duration, now: now)
            let completed = history.filter { $0.resetsAt <= now }
            guard !completed.isEmpty else { continue }
            out += EngineSelfEval.newOutcomesRL(
                window: window.key, cycles: completed, activityGrid: f.activityGrid, calendar: calendar,
                existingKeys: existingKeys,
                includeDiurnal: true)
        }
        return out
    }
}
