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
        public init(method: String, bucket: String, periodKey: String, predicted: Double, truth: Double) {
            self.method = method; self.bucket = bucket; self.periodKey = periodKey
            self.predicted = predicted; self.truth = truth
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
        var out: [NewOutcome] = []
        for c in cases {
            guard c.truth > 0 else { continue }
            let periodKey = TokenSample.formatDate(c.input.periodStart, timeZone: calendar.timeZone)
            for cand in candidates {
                let key = EngineEvalOutcome.makeKey(
                    surface: surfaceEOD, method: cand.id, bucket: c.bucket, periodKey: periodKey)
                guard !existingKeys.contains(key) else { continue }
                guard let pred = cand.projectTotal(c.input), pred.isFinite, pred > 0 else { continue }
                out.append(NewOutcome(surface: surfaceEOD, method: cand.id, bucket: c.bucket,
                                      periodKey: periodKey, predicted: pred, truth: c.truth))
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
            public let periods: Int
            /// The same statistic split by how far through the window the
            /// call was made: the compare sheet's per-model record. Empty on
            /// surfaces whose buckets carry no cut.
            public var byStage: [StageStat] = []
        }
        /// Early, middle or late in the window: cuts 0.2–0.4, 0.5–0.7 and
        /// 0.8–0.9 of the rate-limit grid (`rlCutFractions`).
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
    }

    /// `weekly` picks the statistic `typicalAbsError` reports — the same one
    /// `bestMethod` ranks by, so the accuracy shown and the model chosen can't
    /// disagree (see `typicalError`). `phase` narrows `typicalAbsError` to that
    /// half of the window's cuts, as `bestMethod(phase:)` does (#305); the
    /// period count and `byStage` always cover every cut.
    public static func accuracy(surface: String = surfaceEOD, from records: [Record],
                                weekly: Bool = false, phase: SelectionPhase? = nil) -> Accuracy {
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
            return .init(method: method,
                         medianAbsPctError: median(rows.map { $0.absPctError }),
                         typicalAbsError: typicalError(phaseErrors(rows, phase), weekly: weekly),
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
    static func typicalError(_ errors: [Double], weekly: Bool) -> Double {
        weekly ? mean(errors) : median(errors)
    }

    /// Version suffix of the rate-limit record's bucket keys. v1 rows scored the
    /// raw extrapolation and stay in the table unread: every reader takes only
    /// the current version, and the engine re-scores full history into it once
    /// per launch (`backfillRateLimitRecord`).
    static let rlBucketVersion = "v2"
    static func rlBucket(_ cutFraction: Double) -> String {
        "cut=\(String(format: "%.2f", cutFraction))|\(rlBucketVersion)"
    }
    static func isCurrentRLBucket(_ bucket: String) -> Bool {
        bucket.hasSuffix("|\(rlBucketVersion)")
    }
    /// The cut fraction of an RL bucket (`cut=0.20|v2` → 0.2).
    static func rlCutFraction(_ bucket: String) -> Double? {
        guard bucket.hasPrefix("cut=") else { return nil }
        return Double(bucket.dropFirst(4).prefix { $0 != "|" })
    }

    // MARK: - Rate-limit outlook self-eval

    /// Surface id for a rate-limit window's outlook track record.
    public static func rlSurface(_ window: String) -> String { "rl-\(window)" }
    /// Cut grid for scoring completed cycles (mirrors `scoreCompletedCycle`).
    static let rlCutFractions = [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]

    /// Score the rate-limit roster over *completed* cycles and emit the
    /// outcomes not already persisted — the rate-limit analogue of
    /// `newOutcomesEOD`, and how the diurnal model finally earns a persistent
    /// per-user track record instead of being re-picked cold each scan.
    ///
    /// Leak-free by walk-forward: the diurnal model scored against cycle *i* is
    /// fit only on cycles *before* it (plus the activity-grid prior, which is a
    /// cost-activity shape, not the rate-limit data being scored).
    public static func newOutcomesRL(
        window: String,
        cycles: [BurnTrajectory.Cycle],
        activityGrid: [[Double]],
        calendar: Calendar,
        existingKeys: Set<String>,
        includeDiurnal: Bool,
        indices: Range<Int>? = nil
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
            let scored = rlCutFractions.allSatisfy { cf in
                rosterIds.allSatisfy { id in
                    existingKeys.contains(EngineEvalOutcome.makeKey(
                        surface: surface, method: id, bucket: rlBucket(cf), periodKey: periodKey))
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
            for cf in rlCutFractions {
                let now = cycle.cycleStart.addingTimeInterval(duration * cf)
                let seen = cycle.samples.filter { $0.at <= now }
                guard seen.count >= 3 else { continue }
                let partial = BurnTrajectory.PartialCycle(
                    samples: seen, now: now, cycleStart: cycle.cycleStart, resetsAt: cycle.resetsAt)
                let bucket = rlBucket(cf)
                for m in roster {
                    let key = EngineEvalOutcome.makeKey(surface: surface, method: m.id, bucket: bucket, periodKey: periodKey)
                    guard !existingKeys.contains(key) else { continue }
                    guard let proj = m.fit(partial) else { continue }
                    out.append(NewOutcome(surface: surface, method: m.id, bucket: bucket, periodKey: periodKey,
                                          predicted: BurnTrajectory.displayedAtReset(proj, partial: partial),
                                          truth: trueFinal))
                }
            }
        }
        return out
    }

    /// The first or second half of a rate-limit window, for selection (#305):
    /// cuts 0.2–0.4 and 0.5–0.9 of the grid, and the live cycle's elapsed
    /// fraction on either side of 0.5. A model that reads the early, sparse
    /// part of a window well is often not the one that reads its late part
    /// well, and one all-cuts number picked the same model for both.
    public enum SelectionPhase: Sendable, Equatable {
        case early, late
        public init(cut: Double) { self = cut < 0.5 ? .early : .late }
    }

    /// A method's absolute errors on `phase`'s cuts, or on every cut when nil.
    static func phaseErrors(_ rows: [Record], _ phase: SelectionPhase?) -> [Double] {
        rows.compactMap { r in
            if let phase {
                guard let cut = rlCutFraction(r.bucket), SelectionPhase(cut: cut) == phase else { return nil }
            }
            return abs(r.predicted - r.truth)
        }
    }

    /// Pick the best method from an accumulated record: lowest typical
    /// absolute error (`typicalError`: the median, the mean when `weekly`) in
    /// the surface's native units (percentage points for rate-limit windows),
    /// breaking near-ties toward the simpler model. This keeps selection
    /// consistent with the accuracy the UI displays (`typicalAbsError`, for
    /// the same `phase`) — the two can never contradict each other.
    ///
    /// The near-tie band is 1.5 points, or `tieRelative` of the best error
    /// when given. Rate-limit windows pass `EngineParams.rlTieRelative` (5%):
    /// at a ~3 pp typical miss, 1.5 points tied most of the roster, so the
    /// simplest model won whatever the record said. With `phase`, errors come
    /// from that half of the window's cuts only (#305).
    /// Returns `nil` until at least `minPeriods` completed periods back a
    /// method — the engine then falls back to its cold on-the-fly backtest.
    ///
    /// Every model clears the same floor. A new model used to need 15 scored
    /// periods first (a "shadow"), back when its record could only grow one
    /// live cycle at a time. The record backfill now scores every model over
    /// every cycle the store holds, archive included, on the first refit after
    /// install, so a new model arrives with the same depth of record as the
    /// ones it competes with, and a separate floor only kept it off the screen.
    public static func bestMethod(
        from records: [Record],
        minPeriods: Int = 2,
        complexity: [String: Int] = [:],
        weekly: Bool = false,
        phase: SelectionPhase? = nil,
        tieRelative: Double? = nil
    ) -> String? {
        let byMethod = Dictionary(grouping: records, by: { $0.method })
        let scored = byMethod.compactMap { id, rows -> (id: String, err: Double, cx: Int)? in
            guard Set(rows.map { $0.periodKey }).count >= minPeriods else { return nil }
            let errs = phaseErrors(rows, phase)
            guard !errs.isEmpty else { return nil }
            return (id, typicalError(errs, weekly: weekly), complexity[id] ?? 3)
        }
        guard let best = scored.min(by: { $0.err < $1.err }) else { return nil }
        let band = tieRelative.map { best.err * $0 } ?? 1.5
        return scored.filter { $0.err <= best.err + band }
            .min { ($0.cx, $0.err) < ($1.cx, $1.err) }?.id
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
