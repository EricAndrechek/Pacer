import Foundation

/// The engine's self-evaluation: score the prediction methods against the
/// user's own realized outcomes, persist the verdicts, and read them back to
/// pick the per-user winner. The cost-surface analogue of the rate-limit
/// `ForecastOutcomeRecorder` + `ForecastScoreboard`, and the layer that makes
/// the engine "learn constantly" — its selection is driven by an accumulating
/// per-user track record, not a value recomputed cold each launch.
///
/// All logic here is pure (operates on plain `Record`s, not `@Model`s), so it
/// tests without a container; the actor does the fetch/insert/save around it.
///
/// **End-of-day selection lives here too.** On real data the learned hour-of-day
/// shape only robustly beats the clock-linear baseline once most of the day is
/// observed (evening). `crossover` learns, per user, the fraction-of-day from
/// which to switch — and the bar it applies (a majority sign-test + coverage)
/// is a *generic statistical default applied to each user's own record*, so no
/// individual's data is baked into what ships. The bootstrap-CI width was
/// rejected for this: it flaps run-to-run because case ordering (dictionary/set
/// iteration) isn't stable, while the sign-test is deterministic at small n.
public enum EngineSelfEval {

    public static let surfaceEOD = "eod"
    /// The end-of-day candidate roster: clock-linear (the strong simple
    /// baseline), the learned hour-of-day shape, and the additive pickup.
    public static var eodCandidates: [any Forecaster] {
        [AverageRateForecaster(), RegimeGatedEOD(), PickupForecaster()]
    }
    /// Cut fractions (early morning → late evening) the experts are scored at.
    public static let cutFractions = [0.25, 0.375, 0.5, 0.625, 0.75, 0.875]
    /// Pool-trimming bar — applied to each user's *own* accumulated record.
    /// A method joins a cut's pool when its per-cut median APE is within
    /// `poolTolerance` (relative) of the best method's, with at least
    /// `poolMinPeriods` scored days behind it. Values live in `EngineParams`
    /// (the versioned, harness-sweepable set).
    static var poolTolerance: Double { EngineParams.current.poolTolerance }
    static var poolMinPeriods: Int { EngineParams.current.poolMinPeriods }
    /// Selection looks at only the most recent scored days per cut — drift
    /// insurance. Validated on the real store: with the all-time record the
    /// hour-of-day shape (strong in the first weeks, weak in the current
    /// month's regime) re-entered the morning pools and dragged the median;
    /// a trailing window keeps selection tracking the regime the user is IN,
    /// while the all-time record still powers the accuracy display.
    static var poolRecencyWindow: Int { EngineParams.current.poolRecencyWindow }

    // MARK: - Decoupled value types (SwiftData-free)

    /// A persisted outcome, decoupled from `EngineEvalOutcome`.
    public struct Record: Sendable, Equatable {
        public let method: String
        public let bucket: String
        public let periodKey: String
        public let predicted: Double
        public let truth: Double
        /// What produced the grade (`NewOutcome.inputs`); nil on end-of-day
        /// rows and on rate-limit rows from before it was recorded.
        public var inputs: String?
        public init(method: String, bucket: String, periodKey: String, predicted: Double, truth: Double,
                    inputs: String? = nil) {
            self.method = method; self.bucket = bucket; self.periodKey = periodKey
            self.predicted = predicted; self.truth = truth; self.inputs = inputs
        }
        var absPctError: Double { truth > 0 ? abs(predicted - truth) / truth * 100 : .infinity }
    }

    /// A not-yet-persisted outcome — pure output of `newOutcomesEOD`.
    public struct NewOutcome: Sendable, Equatable {
        public let surface: String
        public let method: String
        public let bucket: String
        public let periodKey: String
        public let predicted: Double
        public let truth: Double
        /// What produced a rate-limit grade: the model's version and, for a
        /// model that reads spend, the pricing and history generations
        /// (`ArenaGradeInputs`). A stored grade whose inputs differ from the
        /// model's now is graded again, in place (the key is the same).
        public var inputs: String? = nil
    }

    // MARK: - Scoring completed periods

    /// Replay each candidate over the prior complete days at each cut and emit
    /// the outcomes not already persisted (idempotent via `existingKeys`). Uses
    /// the shared walk-forward case builder so each prediction sees only earlier
    /// days — leak-free. Only records a candidate when it actually produced a
    /// projection, so coverage is honest (the shape declines early).
    public static func newOutcomesEOD(
        periods: [ForecastInput.PriorPeriod],
        calendar: Calendar,
        existingKeys: Set<String>,
        candidates: [any Forecaster] = eodCandidates
    ) -> [NewOutcome] {
        let cases = WalkForward.cases(
            periods: periods, periodEnd: { $0.start.addingTimeInterval(86400) },
            cutFractions: cutFractions, calendar: calendar)
        return cases.flatMap { outcomesEOD(for: $0, calendar: calendar, skipping: existingKeys, candidates: candidates) }
    }

    private static func outcomesEOD(for c: WalkForward.Case, calendar: Calendar, skipping existingKeys: Set<String>,
                                    candidates: [any Forecaster]) -> [NewOutcome] {
        guard c.truth > 0 else { return [] }
        let periodKey = TokenSample.formatDate(c.input.periodStart, timeZone: calendar.timeZone)
        var out: [NewOutcome] = []
        for cand in candidates {
            let key = EngineEvalOutcome.makeKey(
                surface: surfaceEOD, method: cand.id, bucket: c.bucket, periodKey: periodKey)
            guard !existingKeys.contains(key) else { continue }
            guard let pred = cand.projectTotal(c.input), pred.isFinite, pred > 0 else { continue }
            out.append(NewOutcome(surface: surfaceEOD, method: cand.id, bucket: c.bucket,
                                  periodKey: periodKey, predicted: pred, truth: c.truth))
        }
        return out
    }

    // MARK: - Rescoring after the history changes (#329)

    /// The scored days whose stored truth no longer matches the priced
    /// history, and the earliest of them, or nil when the scoreboard is
    /// current.
    ///
    /// The end-of-day scoreboard is a backtest over priced history, cached:
    /// `predicted` and `truth` are both dollars computed from it. A repriced
    /// day changes underneath its rows. That happens on a cost-recompute bump,
    /// a price-ledger correction, a late transcript, newly attributed usage or
    /// a dedup repair. Comparing against the history covers every cause, with
    /// no notice from any of them. `dayTotals` must be summed the way the
    /// backtest's truth is (hour by hour, `EngineFeatures.priorDayHourlyCosts`),
    /// or the two would never agree and every refit would replay.
    ///
    /// A day missing from `dayTotals` is stale only inside the span the totals
    /// cover. Before that there is nothing to check it against.
    static func staleEODDays(records: some Sequence<Record>, dayTotals: [String: Double],
                             tolerance: Double = 1e-6) -> (earliest: String, count: Int)? {
        guard let firstKnown = dayTotals.keys.min() else { return nil }
        var stale = Set<String>()
        for r in records where r.periodKey >= firstKnown && !stale.contains(r.periodKey) {
            if abs(r.truth - (dayTotals[r.periodKey] ?? 0)) > tolerance { stale.insert(r.periodKey) }
        }
        return stale.min().map { ($0, stale.count) }
    }

    /// The end-of-day outcomes for every day from `periodKey` on, recomputed on
    /// the history as it is now. Each day is scored against the
    /// `priorWindow - 1` days before it, which is what live scoring gave it
    /// when it was the newest complete day. A day before a changed one is
    /// unaffected; every day after it read it as a prior, so all of them
    /// replay. `days` is every complete day, oldest first.
    static func replayOutcomesEOD(
        days: [ForecastInput.PriorPeriod],
        from periodKey: String,
        calendar: Calendar,
        priorWindow: Int = EngineFeatures.eodPriorDays,
        candidates: [any Forecaster] = eodCandidates
    ) -> [NewOutcome] {
        var out: [NewOutcome] = []
        for (i, day) in days.enumerated()
        where TokenSample.formatDate(day.start, timeZone: calendar.timeZone) >= periodKey {
            let priors = Array(days[max(0, i - (priorWindow - 1))..<i])
            for c in WalkForward.cases(for: day, priors: priors, periodEnd: { $0.start.addingTimeInterval(86400) },
                                       cutFractions: cutFractions, calendar: calendar) {
                out += outcomesEOD(for: c, calendar: calendar, skipping: [], candidates: candidates)
            }
        }
        return out
    }

    // MARK: - Selection (pool-then-average, from the persisted scoreboard)

    /// Per-cut **trimmed pool**: the candidate methods whose accumulated
    /// per-cut record is within `poolTolerance` of the best, ordered
    /// best-first. The engine takes the *median* of the pool members' live
    /// projections — combination over selection, per the M4-competition
    /// evidence (12 of the 17 best M4 submissions were combinations; equal
    /// weights beat estimated weights at small N — the "forecast combination
    /// puzzle"). Trimming matters: on the real store an untrimmed pool let
    /// the midday-weak shape drag the median, while the trimmed pool tracked
    /// the per-cut best everywhere.
    ///
    /// Cold start (no method clears `poolMinPeriods` at this cut) returns all
    /// candidate ids — median-of-everything, the safest prior.
    public static func poolMembers(
        forCut cf: Double,
        records: [Record],
        candidateIds: [String] = eodCandidates.map { $0.id }
    ) -> [String] {
        let bucket = "cut=\(String(format: "%.2f", cf))|all"
        let inBucket = records.filter { $0.bucket == bucket }
        // Trailing selection window: the most recent `poolRecencyWindow`
        // scored days at this cut (periodKeys are yyyy-MM-dd — sortable).
        let recentKeys = Set(Set(inBucket.map { $0.periodKey }).sorted().suffix(poolRecencyWindow))
        let recent = inBucket.filter { recentKeys.contains($0.periodKey) }
        let byMethod = Dictionary(grouping: recent, by: { $0.method })
        let scored = candidateIds.compactMap { id -> (id: String, err: Double)? in
            guard let rows = byMethod[id], Set(rows.map { $0.periodKey }).count >= poolMinPeriods else { return nil }
            return (id, median(rows.map { $0.absPctError }))
        }
        guard let best = scored.min(by: { $0.err < $1.err }) else { return candidateIds }
        return scored.filter { $0.err <= best.err * poolTolerance }
            .sorted { $0.err < $1.err }
            .map { $0.id }
    }

    // MARK: - Accuracy report (transparency)

    /// How each method is doing on this user's data — median absolute error in
    /// both units (relative %, for cost surfaces; absolute points, for
    /// utilisation surfaces) and how many completed periods back it. Sorted
    /// best-first by relative error.
    public struct Accuracy: Sendable, Equatable {
        public struct MethodStat: Sendable, Equatable {
            public let method: String
            public let medianAbsPctError: Double
            /// Median |predicted − truth| in the surface's native units
            /// (percentage points for rate-limit surfaces) — what the
            /// compare-models sheet displays as "fit ±N pp".
            public let typicalAbsError: Double
            /// Completed periods in the method's whole record: what the
            /// sheet's list counts towards the selection floor, and the
            /// selected model's "earned on N" footer.
            public let periods: Int
            /// The same statistic split by how far through the window the
            /// call was made: the compare sheet's per-model record. Empty on
            /// surfaces whose buckets carry no cut.
            public var byStage: [StageStat] = []
            /// The cycles behind `typicalAbsError` and `byStage` when the
            /// accuracy is measured over a `span` (`RLRanking.accuracy`): its
            /// record inside the span. Nil: the whole record, `periods`.
            public var spanPeriods: Int? = nil
            /// The first cycle (`periodKey`) of its whole record, set with a
            /// span: a record that starts after the span does is shorter than
            /// the span (`Accuracy.partialCycles`).
            public var firstPeriod: String? = nil
            /// The cycles behind the numbers shown.
            public var shownPeriods: Int { spanPeriods ?? periods }
        }
        /// The cycles every number in an `RLRanking.accuracy` is measured
        /// over: the newest `cycles`, from `start` on.
        public struct Span: Sendable, Equatable {
            /// The span's first cycle (a `periodKey`).
            public let start: String
            /// Completed cycles in it.
            public let cycles: Int
            /// Whether it is every cycle the record holds: nothing narrowed
            /// it, and each number is the method's whole record.
            public let isWholeRecord: Bool
        }
        /// Early, middle or late in the window: cuts below 0.45, below 0.75,
        /// and the rest of the rate-limit grid (`rlGrading`).
        public enum Stage: String, Sendable, CaseIterable {
            case early, middle, late
            init(cut: Double) { self = cut < 0.45 ? .early : cut < 0.75 ? .middle : .late }
        }
        public struct StageStat: Sendable, Equatable {
            public let stage: Stage
            public let typicalAbsError: Double
            /// Scored calls behind the number (cycles × cuts in the stage).
            public let scores: Int
        }
        public let surface: String
        public let methods: [MethodStat]
        /// What the numbers are measured over, for an `RLRanking.accuracy`;
        /// nil: each method over its own whole record (`accuracy`).
        public var span: Span? = nil

        public func stat(_ method: String) -> MethodStat? { methods.first { $0.method == method } }

        /// The cycles behind `method`'s number when its record starts after
        /// the span does (a model still filling in, or one scored only on
        /// recent cycles), so its row can say it was measured on fewer. Nil
        /// when its record reaches back to the span's start, without a span,
        /// and for a method with no number.
        ///
        /// Judged by where the record starts, not by its count: a method
        /// that declined a cycle or two inside the span was still measured
        /// on the same stretch, and a count on every such row would bury
        /// the ones that were not.
        public func partialCycles(_ method: String) -> Int? {
            guard let span, let m = stat(method), m.typicalAbsError.isFinite,
                  let first = m.firstPeriod, first > span.start else { return nil }
            return m.shownPeriods
        }
    }

    /// `weekly` picks the statistic `typicalAbsError` reports — the same one
    /// selection ranks by, so the accuracy shown and the model chosen can't
    /// disagree (see `typicalError`). `at` weights each cut's errors by how
    /// close it is to that point of the window (`cutWeight`), as ranking does;
    /// the period count and `byStage` always cover every cut equally.
    public static func accuracy(surface: String = surfaceEOD, from records: [Record],
                                weekly: Bool = false, at x: Double? = nil) -> Accuracy {
        let byMethod = Dictionary(grouping: records, by: { $0.method })
        let methods = byMethod.map { method, rows -> Accuracy.MethodStat in
            let periods = Set(rows.map { $0.periodKey }).count
            var stageErrors: [Accuracy.Stage: [Double]] = [:]
            for r in rows {
                guard let cut = rlCutFraction(r.bucket) else { continue }
                stageErrors[Accuracy.Stage(cut: cut), default: []].append(abs(r.predicted - r.truth))
            }
            let byStage = Accuracy.Stage.allCases.compactMap { stage -> Accuracy.StageStat? in
                guard let errs = stageErrors[stage], !errs.isEmpty else { return nil }
                return .init(stage: stage, typicalAbsError: typicalError(errs, weekly: weekly), scores: errs.count)
            }
            let weighted = rows.map { r in
                (error: abs(r.predicted - r.truth), weight: rlCutFraction(r.bucket).map { cutWeight($0, at: x) } ?? 1)
            }
            return .init(method: method,
                         medianAbsPctError: median(rows.map { $0.absPctError }),
                         typicalAbsError: typicalError(weighted, weekly: weekly),
                         periods: periods, byStage: byStage)
        }.sorted { $0.medianAbsPctError < $1.medianAbsPctError }
        return Accuracy(surface: surface, methods: methods)
    }

    /// The error a rate-limit model is judged by: the median, or on a
    /// weekly-scale window the mean. Most weekly cycles end at the cap, where
    /// the displayed (clamped) value is exactly right, so their median error
    /// is 0 for every model and every pick falls to the simplest one through
    /// the tie band: scoring the displayed value with the median moved 7-day
    /// selection from saturating to linear-recent and raised its mean error
    /// from 6.7 to 8.8 pp in the harness. The mean keeps the misses that
    /// matter, an early cut undershooting a capped cycle. Mirrors the harness's
    /// `headline_key`.
    ///
    /// Re-checked with the matched-point ranking (2026-10-27, walk-forward
    /// over the owner's record): on five-hour windows the median won on the
    /// longest replay and the mean on the two shorter ones, and the weekly
    /// record is a few dozen cycles; neither is a reason to change it.
    static func typicalError(_ errors: [Double], weekly: Bool) -> Double {
        weekly ? mean(errors) : median(errors)
    }

    /// `typicalError` with a weight on each error (`cutWeight`): the weighted
    /// median, or the weighted mean on a weekly-scale window. Equal weights
    /// give exactly the unweighted statistic.
    static func typicalError(_ errors: [(error: Double, weight: Double)], weekly: Bool) -> Double {
        weekly ? weightedMean(errors) : weightedMedian(errors)
    }

    static func weightedMean(_ xs: [(error: Double, weight: Double)]) -> Double {
        var w = 0.0, s = 0.0
        for x in xs where x.weight > 0 { w += x.weight; s += x.weight * x.error }
        return w > 0 ? s / w : .infinity
    }

    /// The error at which half the weight is below: with equal weights and an
    /// even count, the mean of the middle two, as `median` gives.
    static func weightedMedian(_ xs: [(error: Double, weight: Double)]) -> Double {
        let s = xs.filter { $0.weight > 0 }.sorted { $0.error < $1.error }
        let total = s.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return .infinity }
        let half = total / 2, eps = total * 1e-12
        var acc = 0.0
        for (i, x) in s.enumerated() {
            acc += x.weight
            if acc > half + eps { return x.error }
            if acc >= half - eps { return i + 1 < s.count ? (x.error + s[i + 1].error) / 2 : x.error }
        }
        return s[s.count - 1].error
    }

    // MARK: - Rate-limit grading

    /// One way of grading the rate-limit record: the cuts every model is
    /// graded at, and the bucket version their rows are stored under.
    ///
    /// Every model, the engine's curve fits and the arena's ports alike, is
    /// graded on the same cuts of the same completed cycles into the same
    /// rows: the engine grades its own methods on its actor
    /// (`newOutcomesRL`, cheap), `ArenaRecordScorer` the rest in the
    /// background, both reading this.
    public struct RLGrading: Sendable, Equatable {
        public let version: String
        public let cuts: [Double]
        /// Decimals in a bucket's cut: v2 wrote two (`cut=0.20|v2`); the
        /// current grid needs three (`cut=0.175|v3`).
        let decimals: Int

        public func bucket(_ cut: Double) -> String {
            "cut=\(String(format: "%.\(decimals)f", cut))|\(version)"
        }
        public func contains(bucket: String) -> Bool { bucket.hasSuffix("|\(version)") }
        /// The matched point clamped into the grid, so a cycle just started or
        /// about to reset still weighs its nearest cuts (`cutWeight`).
        func clamp(_ x: Double?) -> Double? {
            guard let x, let lo = cuts.first, let hi = cuts.last else { return x }
            return min(hi, max(lo, x))
        }
    }

    /// Twelve cuts, every 0.075 of the window from 0.1 to 0.925, so a live
    /// cycle at any point of its window has graded cuts near it to be ranked
    /// on (`cutWeight`). v3 replaced v2's eight cuts (0.2–0.9), which left the
    /// first fifth of a window, where the forecasts differ most, ungraded.
    public static let rlGrading = RLGrading(
        version: "v3", cuts: [0.1, 0.175, 0.25, 0.325, 0.4, 0.475, 0.55, 0.625, 0.7, 0.775, 0.85, 0.925],
        decimals: 3)
    /// The grading before `rlGrading`. Its rows keep driving a window's
    /// selection and sheet until the current grading can (`rlGradingInUse`),
    /// so the bump has no stretch where nothing can be picked. v1 rows (the
    /// raw extrapolation, before the shown value was graded) are not read.
    public static let previousRLGrading = RLGrading(
        version: "v2", cuts: [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9], decimals: 2)

    static var rlBucketVersion: String { rlGrading.version }
    static var rlCutFractions: [Double] { rlGrading.cuts }
    static func rlBucket(_ cutFraction: Double) -> String { rlGrading.bucket(cutFraction) }
    static func isCurrentRLBucket(_ bucket: String) -> Bool { rlGrading.contains(bucket: bucket) }
    /// A bucket either grading reads (current or previous).
    static func isReadRLBucket(_ bucket: String) -> Bool {
        rlGrading.contains(bucket: bucket) || previousRLGrading.contains(bucket: bucket)
    }
    /// The cut fraction of an RL bucket (`cut=0.175|v3` → 0.175).
    static func rlCutFraction(_ bucket: String) -> Double? {
        guard bucket.hasPrefix("cut=") else { return nil }
        return Double(bucket.dropFirst(4).prefix { $0 != "|" })
    }

    // MARK: - Rate-limit outlook self-eval

    /// Surface id for a rate-limit window's outlook track record.
    public static func rlSurface(_ window: String) -> String { "rl-\(window)" }

    /// Score the engine's own methods over *completed* cycles and emit the
    /// outcomes not already graded — the rate-limit analogue of
    /// `newOutcomesEOD`, on the same cuts (`rlGrading`) the arena models
    /// are graded at.
    ///
    /// `existingKeys` are the keys already graded with the inputs their
    /// method has now (`RateLimitRoster.engineInputs`): a key graded under
    /// an older version is missing from it, and is graded again.
    ///
    /// Leak-free by walk-forward: the diurnal model scored against cycle *i* is
    /// fit only on cycles *before* it (plus the activity-grid prior, which is a
    /// cost-activity shape, not the rate-limit data being scored).
    ///
    /// `grading` is the current one but for the parity test against the
    /// Python harness, which still grades v2's cuts.
    public static func newOutcomesRL(
        window: String,
        cycles: [BurnTrajectory.Cycle],
        activityGrid: [[Double]],
        calendar: Calendar,
        existingKeys: Set<String>,
        includeDiurnal: Bool,
        indices: Range<Int>? = nil,
        grading: RLGrading = rlGrading
    ) -> [NewOutcome] {
        let surface = rlSurface(window)
        let sorted = cycles.sorted { $0.cycleStart < $1.cycleStart }
        var out: [NewOutcome] = []
        let rosterIds = BurnTrajectory.defaultModels.map(\.id) + (includeDiurnal ? ["diurnal-rate"] : [])
        // `indices` scores a slice of the (sorted) cycles, for the batched
        // full-history pass; the diurnal table still learns from every cycle
        // before each one, so a slice scores exactly what the whole would.
        for (i, cycle) in sorted.enumerated() where indices?.contains(i) ?? true {
            let trueFinal = cycle.samples.map { $0.usedPercentage }.max() ?? 0
            guard trueFinal > 0 else { continue }
            let periodKey = periodKeyRL(cycle.resetsAt)
            // A cycle already scored in full costs nothing: skip it before the
            // diurnal table, which is built from every earlier cycle. This is
            // what keeps the once-per-launch full-history pass cheap after the
            // first one.
            let scored = grading.cuts.allSatisfy { cf in
                rosterIds.allSatisfy { id in
                    existingKeys.contains(EngineEvalOutcome.makeKey(
                        surface: surface, method: id, bucket: grading.bucket(cf), periodKey: periodKey))
                }
            }
            if scored { continue }
            var roster = BurnTrajectory.defaultModels
            if includeDiurnal {
                let table = DiurnalBurnModel.rateTable(cycles: Array(sorted[0..<i]), calendar: calendar, prior: activityGrid)
                roster.append(DiurnalBurnModel(rate: table, calendar: calendar))
            }
            let duration = cycle.resetsAt.timeIntervalSince(cycle.cycleStart)
            guard duration > 0 else { continue }
            for cf in grading.cuts {
                let now = cycle.cycleStart.addingTimeInterval(duration * cf)
                let seen = cycle.samples.filter { $0.at <= now }
                guard seen.count >= 3 else { continue }
                let partial = BurnTrajectory.PartialCycle(
                    samples: seen, now: now, cycleStart: cycle.cycleStart, resetsAt: cycle.resetsAt)
                let bucket = grading.bucket(cf)
                for m in roster {
                    let key = EngineEvalOutcome.makeKey(surface: surface, method: m.id, bucket: bucket, periodKey: periodKey)
                    guard !existingKeys.contains(key) else { continue }
                    guard let proj = m.fit(partial) else { continue }
                    out.append(NewOutcome(surface: surface, method: m.id, bucket: bucket, periodKey: periodKey,
                                          predicted: BurnTrajectory.displayedAtReset(proj, partial: partial),
                                          truth: trueFinal, inputs: RateLimitRoster.engineInputs(m.id)))
                }
            }
        }
        return out
    }

    // MARK: - Matching the live point

    /// How much an error graded at `cut` counts when ranking for a cycle `x`
    /// of the way through its window: 1 at `x`, falling linearly to 0 at
    /// `rlCutKernelHalfWidth` away. No live cycle (`x` nil): every cut the
    /// same.
    ///
    /// Replaced the early/late halves (#305), which ranked a cycle 0.49 of
    /// the way through on cuts 0.2–0.4 and one at 0.51 on 0.5–0.9. Chosen by
    /// a walk-forward replay over the owner's record (at each past cycle,
    /// pick from the earlier ones, score the pick's own miss): on five-hour
    /// windows a triangle 0.2 wide was no worse than the halves on any of
    /// three candidate sets and better on the two with the ported models in
    /// them; narrower and wider kernels, Gaussians and "every cut" each lost
    /// on at least one.
    static func cutWeight(_ cut: Double, at x: Double?) -> Double {
        guard let x else { return 1 }
        let h = EngineParams.current.rlCutKernelHalfWidth
        guard h > 0 else { return 1 }
        // A cut exactly the width away weighs nothing, whatever the last bit
        // of `cut - x` says (0.6 − 0.4 is a hair under 0.2).
        let w = 1 - abs(cut - x) / h
        return w > 1e-9 ? w : 0
    }

    /// Pick the best method from an accumulated record: lowest typical
    /// absolute error (`typicalError`: the median, the mean when `weekly`) in
    /// the surface's native units (percentage points for rate-limit windows),
    /// each cut weighted by its closeness to `at` (`cutWeight`), breaking
    /// near-ties toward the simpler model. Selection on a rate-limit window
    /// goes through `rankRL`, which calls this on the shared span.
    ///
    /// The near-tie band is 1.5 points, or `tieRelative` of the best error
    /// when given. Rate-limit windows pass `EngineParams.rlTieRelative` (5%):
    /// at a ~3 pp typical miss, 1.5 points tied most of the roster, so the
    /// simplest model won whatever the record said.
    /// Returns `nil` until at least `minPeriods` completed periods back a
    /// method — the engine then falls back to its cold on-the-fly backtest.
    public static func bestMethod(
        from records: [Record],
        minPeriods: Int = 2,
        complexity: [String: Int] = [:],
        weekly: Bool = false,
        at x: Double? = nil,
        tieRelative: Double? = nil
    ) -> String? {
        let byMethod = Dictionary(grouping: records, by: { $0.method })
        let scored = byMethod.compactMap { id, rows -> (id: String, err: Double)? in
            guard Set(rows.map { $0.periodKey }).count >= minPeriods else { return nil }
            let errs = rows.map { r in
                (error: abs(r.predicted - r.truth), weight: rlCutFraction(r.bucket).map { cutWeight($0, at: x) } ?? 1)
            }
            let err = typicalError(errs, weekly: weekly)
            return err.isFinite ? (id, err) : nil
        }
        return pickWithinTie(scored, complexity: complexity, tieRelative: tieRelative)
    }

    /// The simplest of the methods within the near-tie band of the best
    /// (`bestMethod`), then the lower error, then the id, so the pick holds
    /// still between refits.
    static func pickWithinTie(_ scored: [(id: String, err: Double)], complexity: [String: Int],
                              tieRelative: Double?) -> String? {
        guard let best = scored.map(\.err).min() else { return nil }
        let band = tieRelative.map { best * $0 } ?? 1.5
        return scored.filter { $0.err <= best + band }
            .min { (complexity[$0.id] ?? 3, $0.err, $0.id) < (complexity[$1.id] ?? 3, $1.err, $1.id) }?.id
    }

    /// Cycle identity, rounded to the minute so reset jitter doesn't split a
    /// cycle across scans (matches `BurnTrajectory.segment`).
    static func periodKeyRL(_ reset: Date) -> String {
        let rounded = Date(timeIntervalSince1970: (reset.timeIntervalSince1970 / 60).rounded() * 60)
        return periodFormatter.string(from: rounded)
    }

    /// The reset instant a `periodKeyRL` names.
    static func periodDateRL(_ key: String) -> Date? { periodFormatter.date(from: key) }

    /// Thread-safe for formatting and parsing (Apple documents it); see
    /// AGENTS.md on `ISO8601DateFormatter` and Sendable.
    nonisolated(unsafe) private static let periodFormatter = ISO8601DateFormatter()

    // MARK: - Stats

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return .infinity }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    static func mean(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return .infinity }
        return xs.reduce(0, +) / Double(xs.count)
    }
}

// MARK: - One ranking for every model

extension EngineSelfEval {

    /// Cycles a method needs graded before it can be picked or ranked: the
    /// same for every method, the engine's curve fits and the arena's ports
    /// alike. Before a window has them, the engine's cold backtest picks.
    public static func rlMinPeriods(weekly: Bool) -> Int { weekly ? 3 : 8 }

    /// How many completed cycles of a window every model is graded on, newest
    /// first: the shared depth, and the span ranking compares over once every
    /// model has been graded that deep.
    ///
    /// Chosen from cost and storage (see `ArenaRecordScorer.Config`): a
    /// five-hour cycle costs about 11 s of CPU to grade every model at every
    /// cut on an M-series Mac, a weekly one about 18 s, and each graded cycle
    /// is about 500 rows. 120 five-hour cycles is a month or more of
    /// steady use, enough that a 5% tie band separates models (the replay saw
    /// no gain from a deeper span); 17 weekly cycles is what the 120 days of
    /// history the arena reads can hold.
    public static func rlDepth(weekly: Bool) -> Int { weekly ? 17 : 120 }

    /// A ranked model is "well behind" when it is clearly worse than the best
    /// over the same cycles: its typical miss more than half again the
    /// best's plus a point, measured over (nearly) the whole span; or it
    /// loses to the best cycle by cycle beyond chance (a one-sided sign test
    /// at p < 0.001 over at least 20 cycles where they differ) while a fifth
    /// or more behind. The first is the margin no near-tie band (5%) comes
    /// near; the second catches a model that is consistently, not just on
    /// average, worse. Neither is judged over fewer than twice the floor of
    /// cycles (`wellBehindMinSpan`): on the owner's record a weekly span of
    /// four cycles put thirty of thirty-five models "well behind" on noise.
    /// Display only: it is still graded on every cycle, and can climb back.
    static let wellBehindRatio = 1.5
    static let wellBehindMargin = 1.0
    static let wellBehindCoverage = 0.9
    static let wellBehindSignTestP = 0.001
    static let wellBehindSignTestMinCycles = 20
    static let wellBehindSignTestRatio = 1.2
    static func wellBehindMinSpan(weekly: Bool) -> Int { 2 * rlMinPeriods(weekly: weekly) }

    /// One window's record ranked the way selection and the compare sheet
    /// read it: every method over the same cycles (`span`), at the same point
    /// of the window (`at`, `cutWeight`), by the same statistic.
    public struct RLRanking: Sendable, Equatable {
        public struct Standing: Sendable, Equatable {
            public let method: String
            /// Completed cycles graded within the shared depth.
            public let cycles: Int
            /// Of the span's cycles, the ones it is graded on.
            public let spanCycles: Int
            /// Its oldest graded cycle within the depth.
            public let firstPeriod: String?
            /// Its typical miss at the matched point over the span; nil when
            /// it is not ranked (fewer than `rlMinPeriods` cycles graded).
            public let typicalAbsError: Double?
            /// Clearly behind the best (`wellBehindRatio`).
            public let wellBehind: Bool
            /// Which test put it there, for its row; nil when not well behind.
            public var behind: WellBehind? = nil
            public let complexity: Int
            /// Over the span, every cut counted the same: what the old
            /// accuracy rows showed (`Accuracy`).
            public let medianAbsPctError: Double
            public let byStage: [Accuracy.StageStat]

            public var isRanked: Bool { typicalAbsError != nil }
        }

        /// Why a ranked model is well behind the best.
        public enum WellBehind: Sendable, Equatable {
            /// Its typical miss is more than half again the best's plus a
            /// point (`wellBehindRatio`); the best's typical miss.
            case missesMore(thanBest: Double)
            /// It did worse than the best on `worse` of the `of` cycles where
            /// the two differed: consistently, not just on average.
            case losesMostCycles(worse: Int, of: Int)
        }

        public let grading: RLGrading
        /// The matched point, clamped into the grid; nil with no live cycle.
        public let at: Double?
        /// The cycles every ranked number covers; nil with no record.
        public let span: Accuracy.Span?
        /// Ranked models by typical miss (the well-behind ones after them),
        /// then the unranked by how far their grading has come.
        public let standings: [Standing]
        public let pick: String?
        /// Completed cycles in the shared depth: every cycle any method is
        /// graded on there.
        public let depthCycles: Int
        /// The oldest cycle in the shared depth; nil with no record. Nothing
        /// older is ranked.
        public var depthStart: String? = nil
        /// A weekly-scale window's ranking (`rlDepth`, `rlMinPeriods`).
        public var weekly = false

        public func standing(_ method: String) -> Standing? { standings.first { $0.method == method } }
        public var ranked: [Standing] { standings.filter(\.isRanked) }

        static func empty(_ grading: RLGrading, at: Double?) -> RLRanking {
            RLRanking(grading: grading, at: at, span: nil, standings: [], pick: nil, depthCycles: 0, depthStart: nil)
        }

        /// The sheet's accuracy rows, from the ranking: each over the span,
        /// `periods` its graded cycles within the depth.
        public func accuracy(surface: String) -> Accuracy {
            Accuracy(surface: surface, methods: standings.map { s in
                .init(method: s.method, medianAbsPctError: s.medianAbsPctError,
                      typicalAbsError: s.typicalAbsError ?? .infinity, periods: s.cycles, byStage: s.byStage,
                      spanPeriods: s.spanCycles, firstPeriod: s.firstPeriod)
            }, span: span)
        }
    }

    /// Rank `records` (one window's) under `grading`.
    ///
    /// - The depth: the newest `depth` cycles any method is graded on.
    /// - Eligible: a method with `rlMinPeriods` cycles graded there.
    /// - The span: from the latest first cycle of the eligible methods to the
    ///   newest. While the background grader catches up (newest first) that
    ///   is the cycles every eligible model has; once it has caught up, the
    ///   whole depth. No method is pruned from it, and none shortens it
    ///   without being eligible.
    /// - Each eligible method's typical miss over the span, each cut's
    ///   errors weighted by its closeness to `at` (`cutWeight`); the pick is
    ///   the simplest within the near-tie band of the best (`bestMethod`).
    /// - With `disagreement` (points), only the moments where the models'
    ///   forecasts spread at least that far count. Where every model said
    ///   the same, the meter's outcome tells nothing about which is better,
    ///   and on an account with quiet cycles those moments outnumber the
    ///   rest: every miss read ±0 and the simplest model won whatever the
    ///   record said. A method with no such moment near `at` is ranked on
    ///   all of its moments, so a window where everyone always agreed ranks
    ///   as it would without the filter.
    ///
    /// `candidates` limits the methods ranked (the ones that can run on this
    /// window); nil ranks every method in the record. `pickable` limits the
    /// pick further (nil: any ranked method).
    public static func rankRL(_ records: [Record], grading: RLGrading = rlGrading, candidates: Set<String>? = nil,
                              pickable: Set<String>? = nil, complexity: [String: Int] = [:], weekly: Bool,
                              at x: Double?, depth: Int? = nil, tieRelative: Double? = nil,
                              disagreement: Double? = nil) -> RLRanking {
        let x = grading.clamp(x)
        struct Graded { let cut: Double; let error: Double; let pct: Double }
        struct Moment: Hashable { let period: String; let cut: Double }
        var cutOf: [String: Double] = [:]
        var byMethod: [String: [String: [Graded]]] = [:]
        var allPeriods = Set<String>()
        // The lowest and highest forecast at each moment, over the methods
        // ranked: how far the models disagreed there.
        var spread: [Moment: (lo: Double, hi: Double)] = [:]
        for r in records where r.truth > 0 && grading.contains(bucket: r.bucket) {
            if let candidates, !candidates.contains(r.method) { continue }
            let cut: Double
            if let c = cutOf[r.bucket] { cut = c } else {
                guard let c = rlCutFraction(r.bucket) else { continue }
                cutOf[r.bucket] = c
                cut = c
            }
            allPeriods.insert(r.periodKey)
            byMethod[r.method, default: [:]][r.periodKey, default: []]
                .append(Graded(cut: cut, error: abs(r.predicted - r.truth), pct: r.absPctError))
            if disagreement != nil {
                let m = Moment(period: r.periodKey, cut: cut)
                spread[m] = spread[m].map { (min($0.lo, r.predicted), max($0.hi, r.predicted)) }
                    ?? (r.predicted, r.predicted)
            }
        }
        func disagreed(_ period: String, _ cut: Double) -> Bool {
            guard let disagreement, let s = spread[Moment(period: period, cut: cut)] else { return true }
            return s.hi - s.lo >= disagreement
        }
        // periodKeys are ISO 8601 instants, so their order is time order.
        var periods = allPeriods.sorted()
        if let depth, periods.count > depth { periods = Array(periods.suffix(depth)) }
        guard let depthStart = periods.first else { return .empty(grading, at: x) }

        let minPeriods = rlMinPeriods(weekly: weekly)
        var cycles: [String: Int] = [:], first: [String: String] = [:]
        for (m, byPeriod) in byMethod {
            for p in byPeriod.keys where p >= depthStart {
                cycles[m, default: 0] += 1
                if first[m].map({ p < $0 }) ?? true { first[m] = p }
            }
        }
        let eligible = Set(cycles.filter { $0.value >= minPeriods }.keys)
        let start = eligible.compactMap { first[$0] }.max() ?? depthStart
        let span = periods.filter { $0 >= start }

        struct Row { let method: String; let spanCycles: Int; let typical: Double?; let pct: Double
                     let byStage: [Accuracy.StageStat] }
        var rows: [Row] = []
        for (m, byPeriod) in byMethod where cycles[m] != nil {
            // Every moment, and the ones where the models disagreed (the
            // same lists without `disagreement`); the numbers come from the
            // second wherever it has any.
            var pairs: [(error: Double, weight: Double)] = [], keptPairs: [(error: Double, weight: Double)] = []
            var pcts: [Double] = [], keptPcts: [Double] = []
            var stages: [Accuracy.Stage: [Double]] = [:], keptStages: [Accuracy.Stage: [Double]] = [:]
            var inSpan = 0
            for p in span {
                guard let gs = byPeriod[p] else { continue }
                inSpan += 1
                for g in gs {
                    let pair = (error: g.error, weight: cutWeight(g.cut, at: x))
                    let stage = Accuracy.Stage(cut: g.cut)
                    pairs.append(pair)
                    pcts.append(g.pct)
                    stages[stage, default: []].append(g.error)
                    guard disagreed(p, g.cut) else { continue }
                    keptPairs.append(pair)
                    keptPcts.append(g.pct)
                    keptStages[stage, default: []].append(g.error)
                }
            }
            var typical: Double?
            if eligible.contains(m), inSpan > 0 {
                // Infinite when no kept moment weighs anything near `at`.
                let kept = typicalError(keptPairs, weekly: weekly)
                let t = kept.isFinite ? kept : typicalError(pairs, weekly: weekly)
                typical = t.isFinite ? t : nil
            }
            let byStage = Accuracy.Stage.allCases.compactMap { stage -> Accuracy.StageStat? in
                guard let errs = keptStages[stage].flatMap({ $0.isEmpty ? nil : $0 }) ?? stages[stage],
                      !errs.isEmpty else { return nil }
                return .init(stage: stage, typicalAbsError: typicalError(errs, weekly: weekly), scores: errs.count)
            }
            rows.append(Row(method: m, spanCycles: inSpan, typical: typical,
                            pct: median(keptPcts.isEmpty ? pcts : keptPcts), byStage: byStage))
        }

        let ranked = rows.compactMap { r in r.typical.map { (id: r.method, err: $0) } }
        let pick = pickWithinTie(ranked.filter { pickable?.contains($0.id) ?? true }, complexity: complexity,
                                 tieRelative: tieRelative)
        let best = ranked.min { ($0.err, $0.id) < ($1.err, $1.id) }

        // A cycle's score is over its moments where the models disagreed; a
        // cycle with none is left out (everyone said the same there).
        func cycleScores(_ m: String) -> [String: Double] {
            var out: [String: Double] = [:]
            guard let byPeriod = byMethod[m] else { return out }
            for p in span {
                guard let all = byPeriod[p] else { continue }
                let gs = all.filter { disagreed(p, $0.cut) }
                guard !gs.isEmpty else { continue }
                var w = 0.0, s = 0.0
                for g in gs { let k = cutWeight(g.cut, at: x); w += k; s += k * g.error }
                out[p] = w > 0 ? s / w : gs.reduce(0) { $0 + $1.error } / Double(gs.count)
            }
            return out
        }
        let bestScores = best.map { cycleScores($0.id) } ?? [:]
        func wellBehind(_ r: Row) -> RLRanking.WellBehind? {
            guard let t = r.typical, let best, r.method != best.id,
                  span.count >= wellBehindMinSpan(weekly: weekly) else { return nil }
            if t > best.err * wellBehindRatio + wellBehindMargin,
               Double(r.spanCycles) >= wellBehindCoverage * Double(span.count) { return .missesMore(thanBest: best.err) }
            guard t >= best.err * wellBehindSignTestRatio else { return nil }
            var worse = 0, better = 0
            for (p, s) in cycleScores(r.method) {
                guard let b = bestScores[p] else { continue }
                if s > b { worse += 1 } else if s < b { better += 1 }
            }
            let n = worse + better
            guard n >= wellBehindSignTestMinCycles, binomialUpperTail(n: n, k: worse) < wellBehindSignTestP
            else { return nil }
            return .losesMostCycles(worse: worse, of: n)
        }

        let standings = rows.map { r in
            let behind = wellBehind(r)
            return RLRanking.Standing(method: r.method, cycles: cycles[r.method] ?? 0, spanCycles: r.spanCycles,
                                      firstPeriod: first[r.method], typicalAbsError: r.typical,
                                      wellBehind: behind != nil, behind: behind,
                                      complexity: complexity[r.method] ?? 3, medianAbsPctError: r.pct,
                                      byStage: r.byStage)
        }.sorted { a, b in
            func group(_ s: RLRanking.Standing) -> Int { s.isRanked ? (s.wellBehind ? 1 : 0) : 2 }
            if group(a) != group(b) { return group(a) < group(b) }
            if let ta = a.typicalAbsError, let tb = b.typicalAbsError, ta != tb { return ta < tb }
            if !a.isRanked, a.cycles != b.cycles { return a.cycles > b.cycles }
            if a.complexity != b.complexity { return a.complexity < b.complexity }
            return a.method < b.method
        }
        return RLRanking(grading: grading, at: x,
                         span: .init(start: start, cycles: span.count,
                                     isWholeRecord: start == depthStart && periods.count == allPeriods.count),
                         standings: standings, pick: pick, depthCycles: periods.count, depthStart: depthStart,
                         weekly: weekly)
    }

    /// P(X ≥ k) for X ~ Binomial(n, ½): the sign test's one-sided p-value.
    static func binomialUpperTail(n: Int, k: Int) -> Double {
        guard k > 0 else { return 1 }
        guard k <= n else { return 0 }
        let logHalfN = Double(n) * log(0.5)
        var total = 0.0
        for i in k...n {
            total += exp(lgamma(Double(n + 1)) - lgamma(Double(i + 1)) - lgamma(Double(n - i + 1)) + logHalfN)
        }
        return min(1, total)
    }

    /// Which grading drives a window while the record moves from the previous
    /// one to the current (a bucket version bump): the current one as soon as
    /// it can pick and ranks every model the previous one ranked that can
    /// still run, or once the grader has been through the whole depth under
    /// it (`currentComplete`: a model that no longer forecasts must not hold
    /// the switch forever). Until then the previous grading picks and fills
    /// the sheet, so a bump never leaves a window with nothing to pick, nor
    /// one picked from the few models graded first.
    public static func rlGradingInUse(current: RLRanking, previous: RLRanking, runnable: Set<String>? = nil,
                                      currentComplete: Bool = false) -> RLRanking {
        guard current.pick != nil else {
            // Neither picks: show whichever has a record.
            let showPrevious = previous.pick != nil || (current.standings.isEmpty && !previous.standings.isEmpty)
            return showPrevious ? previous : current
        }
        guard previous.pick != nil, !currentComplete else { return current }
        var wanted = Set(previous.ranked.map(\.method))
        if let runnable { wanted.formIntersection(runnable) }
        return wanted.isSubset(of: Set(current.ranked.map(\.method))) ? current : previous
    }
}
