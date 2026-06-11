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
    /// Candidate ids compared on the end-of-day surface.
    static let clockId = "average-rate"
    static let shapeId = "regime-gated-eod"
    /// Cut fractions (early morning → late evening) the experts are scored at.
    public static let cutFractions = [0.25, 0.375, 0.5, 0.625, 0.75, 0.875]
    /// Selection bar — applied to each user's *own* accumulated record.
    static let minShared = 10
    static let minCoverage = 0.6
    static let minWinFraction = 0.6

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
        candidates: [any Forecaster] = [AverageRateForecaster(), RegimeGatedEOD()]
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

    // MARK: - Selection (from the persisted scoreboard)

    private struct BucketStat { let cf: Double; let coverage: Double; let winFraction: Double; let medianDelta: Double; let n: Int }

    /// The learned fraction-of-day from which the shape beats clock, computed
    /// from the accumulated per-user record. `.infinity` when the shape never
    /// robustly wins (so clock all day) — also the safe answer on thin data.
    public static func crossover(from records: [Record]) -> Double {
        crossoverFromTail(cutFractions.map { stat(at: $0, records: records) })
    }

    /// Per-bucket paired stats from the persisted records: pair clock vs shape
    /// on the days where *both* predicted, and measure how often (and by how
    /// much) the shape was closer.
    private static func stat(at cf: Double, records: [Record]) -> BucketStat {
        let bucket = "cut=\(String(format: "%.2f", cf))|all"
        let inBucket = records.filter { $0.bucket == bucket }
        let byPeriod = Dictionary(grouping: inBucket, by: { $0.periodKey })
        var clockDays = 0, shared = 0, wins = 0
        var deltas: [Double] = []
        for (_, rows) in byPeriod {
            guard let clock = rows.first(where: { $0.method == clockId }) else { continue }
            clockDays += 1
            guard let shape = rows.first(where: { $0.method == shapeId }) else { continue }
            shared += 1
            deltas.append(shape.absPctError - clock.absPctError)
            if shape.absPctError < clock.absPctError { wins += 1 }
        }
        let coverage = clockDays > 0 ? Double(shared) / Double(clockDays) : 0
        let winFraction = shared > 0 ? Double(wins) / Double(shared) : 0
        return BucketStat(cf: cf, coverage: coverage, winFraction: winFraction,
                          medianDelta: median(deltas), n: shared)
    }

    /// Take only the contiguous *evening* tail of robust shape wins — the
    /// shape's advantage is monotone in fraction-observed, so an isolated midday
    /// bucket clearing the bar is an artifact, not a real crossover.
    private static func crossoverFromTail(_ stats: [BucketStat]) -> Double {
        func robust(_ s: BucketStat) -> Bool {
            s.n >= minShared && s.coverage >= minCoverage
                && s.winFraction >= minWinFraction && s.medianDelta < 0
        }
        var crossover = Double.infinity
        for s in stats.sorted(by: { $0.cf > $1.cf }) {
            if robust(s) { crossover = s.cf } else { break }
        }
        return crossover
    }

    // MARK: - Accuracy report (transparency)

    /// How each method is doing on this user's data — median absolute % error
    /// and how many completed periods back it. Sorted best-first.
    public struct Accuracy: Sendable, Equatable {
        public struct MethodStat: Sendable, Equatable {
            public let method: String
            public let medianAbsPctError: Double
            public let periods: Int
        }
        public let surface: String
        public let methods: [MethodStat]
    }

    public static func accuracy(surface: String = surfaceEOD, from records: [Record]) -> Accuracy {
        let byMethod = Dictionary(grouping: records, by: { $0.method })
        let methods = byMethod.map { method, rows -> Accuracy.MethodStat in
            let periods = Set(rows.map { $0.periodKey }).count
            return .init(method: method, medianAbsPctError: median(rows.map { $0.absPctError }), periods: periods)
        }.sorted { $0.medianAbsPctError < $1.medianAbsPctError }
        return Accuracy(surface: surface, methods: methods)
    }

    // MARK: - Stats

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return .infinity }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
