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
            public let medianAbsError: Double
            public let periods: Int
        }
        public let surface: String
        public let methods: [MethodStat]
    }

    public static func accuracy(surface: String = surfaceEOD, from records: [Record]) -> Accuracy {
        let byMethod = Dictionary(grouping: records, by: { $0.method })
        let methods = byMethod.map { method, rows -> Accuracy.MethodStat in
            let periods = Set(rows.map { $0.periodKey }).count
            return .init(method: method,
                         medianAbsPctError: median(rows.map { $0.absPctError }),
                         medianAbsError: median(rows.map { abs($0.predicted - $0.truth) }),
                         periods: periods)
        }.sorted { $0.medianAbsPctError < $1.medianAbsPctError }
        return Accuracy(surface: surface, methods: methods)
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
        includeDiurnal: Bool
    ) -> [NewOutcome] {
        let surface = rlSurface(window)
        let sorted = cycles.sorted { $0.cycleStart < $1.cycleStart }
        var out: [NewOutcome] = []
        for (i, cycle) in sorted.enumerated() {
            let trueFinal = cycle.samples.map { $0.usedPercentage }.max() ?? 0
            guard trueFinal > 0 else { continue }
            let periodKey = periodKeyRL(cycle.resetsAt)
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
                let bucket = "cut=\(String(format: "%.2f", cf))"
                for m in roster {
                    let key = EngineEvalOutcome.makeKey(surface: surface, method: m.id, bucket: bucket, periodKey: periodKey)
                    guard !existingKeys.contains(key) else { continue }
                    guard let proj = m.fit(partial) else { continue }
                    out.append(NewOutcome(surface: surface, method: m.id, bucket: bucket,
                                          periodKey: periodKey, predicted: proj(cycle.resetsAt), truth: trueFinal))
                }
            }
        }
        return out
    }

    /// Pick the best method from an accumulated record: lowest median absolute
    /// error in the surface's native units (percentage points for rate-limit
    /// windows), breaking near-ties within 1.5 percentage points toward the
    /// simpler model. This keeps selection consistent with the accuracy the UI
    /// displays (`medianAbsError`) — the two can never contradict each other.
    /// Returns `nil` until at least `minPeriods` completed periods back a
    /// method — the engine then falls back to its cold on-the-fly backtest.
    ///
    /// `provisionalMinPeriods` is the SHADOW promotion gate: methods listed
    /// there need their own (much higher) floor of scored periods before they
    /// can be selected at all. They accumulate record from day one like
    /// everyone else — the gate only bounds what a thin early record can put
    /// on screen, so a new candidate earns display instead of getting it on a
    /// lucky week.
    public static func bestMethod(
        from records: [Record],
        minPeriods: Int = 2,
        complexity: [String: Int] = [:],
        provisionalMinPeriods: [String: Int] = [:]
    ) -> String? {
        let byMethod = Dictionary(grouping: records, by: { $0.method })
        let scored = byMethod.compactMap { id, rows -> (id: String, err: Double, cx: Int)? in
            let floor = provisionalMinPeriods[id] ?? minPeriods
            guard Set(rows.map { $0.periodKey }).count >= floor else { return nil }
            return (id, median(rows.map { abs($0.predicted - $0.truth) }), complexity[id] ?? 3)
        }
        guard let best = scored.min(by: { $0.err < $1.err }) else { return nil }
        return scored.filter { $0.err <= best.err + 1.5 }
            .min { ($0.cx, $0.err) < ($1.cx, $1.err) }?.id
    }

    /// Cycle identity, rounded to the minute so reset jitter doesn't split a
    /// cycle across scans (matches `BurnTrajectory.segment`).
    static func periodKeyRL(_ reset: Date) -> String {
        let rounded = Date(timeIntervalSince1970: (reset.timeIntervalSince1970 / 60).rounded() * 60)
        return ISO8601DateFormatter().string(from: rounded)
    }

    // MARK: - Stats

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return .infinity }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
