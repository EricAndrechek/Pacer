import Foundation

/// Honest, per-regime, walk-forward evaluation — the engine's self-evaluation
/// core, and the fix for the single methodological flaw the round-2 audit
/// caught: *pooled-across-cut medians are flattered by trivially-late cuts*
/// (predicting the day total at 9pm when 100% of it is already observed is
/// arithmetic, not forecasting), and different model harnesses quietly scored
/// different case sets so their baselines disagreed.
///
/// `WalkForward` fixes both:
/// - every candidate is scored on ONE identical case set per *bucket* (a
///   cut-fraction × regime label like `cut=0.40|weekday`), so a baseline yields
///   the same number everywhere and comparisons are apples-to-apples;
/// - results are reported per bucket with a **bootstrap CI** on the median error
///   and a **paired** model-vs-baseline delta — never a single pooled headline.
///
/// It's deliberately pure and value-typed: the same harness backtests at build
/// time (synthetic), validates on the real store, and — once persisted outcomes
/// accumulate — is what the live engine uses to pick the per-user winner. Seeded
/// so every CI is reproducible.
public enum WalkForward {

    /// A walk-forward case: an input as it looked at a past cut-point, the
    /// realized truth, and the bucket (cut × regime) it belongs to.
    public struct Case: Sendable {
        public let input: ForecastInput
        public let truth: Double
        public let bucket: String
        public init(input: ForecastInput, truth: Double, bucket: String) {
            self.input = input
            self.truth = truth
            self.bucket = bucket
        }
    }

    /// One model's score within one bucket.
    public struct Score: Sendable, Equatable {
        public let modelId: String
        public let bucket: String
        public let medianAbsPctError: Double
        public let meanAbsPctError: Double
        /// Fraction of the bucket's cases the model produced a projection for.
        public let coverage: Double
        public let n: Int
        /// Bootstrap 95% CI on the median absolute percentage error.
        public let ciLow: Double
        public let ciHigh: Double
    }

    /// A paired model-vs-baseline comparison within a bucket: both scored on the
    /// identical cases each could project, so the delta is honest.
    public struct Paired: Sendable, Equatable {
        public let modelId: String
        public let baselineId: String
        public let bucket: String
        /// median(modelAPE − baselineAPE) over shared cases. Negative ⇒ the model
        /// beats the baseline.
        public let medianDelta: Double
        public let ciLow: Double
        public let ciHigh: Double
        /// Fraction of shared cases where the model was strictly closer to truth.
        public let winFraction: Double
        public let n: Int
    }

    // MARK: - Case construction

    /// Build walk-forward cases from complete prior periods: for each period, at
    /// each cut fraction, an input that has seen ONLY that period up to the cut
    /// (with the periods before it as priors, so seasonal methods have history),
    /// truth = the period's realized total. `regime` tags each case so the
    /// harness can break results out by weekday/weekend, active/quiet, etc.
    public static func cases(
        periods: [ForecastInput.PriorPeriod],
        periodEnd: (ForecastInput.PriorPeriod) -> Date,
        cutFractions: [Double],
        calendar: Calendar = .current,
        regime: (ForecastInput) -> String = { _ in "all" }
    ) -> [Case] {
        var out: [Case] = []
        for (i, period) in periods.enumerated() {
            let truth = period.total
            guard truth > 0 else { continue }
            let priors = Array(periods[0..<i])
            let end = periodEnd(period)
            let span = end.timeIntervalSince(period.start)
            guard span > 0 else { continue }
            for cf in cutFractions {
                let now = period.start.addingTimeInterval(span * cf)
                let elapsed = period.points.filter { $0.at <= now }
                guard !elapsed.isEmpty else { continue }
                let input = ForecastInput(
                    now: now, periodStart: period.start, periodEnd: end,
                    calendar: calendar, elapsed: elapsed, priorPeriods: priors)
                out.append(Case(input: input, truth: truth,
                                bucket: "cut=\(String(format: "%.2f", cf))|\(regime(input))"))
            }
        }
        return out
    }

    // MARK: - Scoring

    /// Score every model on every bucket, on the bucket's identical case set,
    /// with a bootstrap CI on each median error. Sorted by (bucket, error).
    public static func score(
        models: [any Forecaster],
        cases: [Case],
        bootstrap: Int = 1000,
        seed: UInt64 = 0x5EED
    ) -> [Score] {
        let byBucket = Dictionary(grouping: cases, by: { $0.bucket })
        var rng = SplitMix64(seed: seed)
        var scores: [Score] = []
        for (bucket, bucketCases) in byBucket {
            for model in models {
                var apes: [Double] = []
                for c in bucketCases {
                    guard c.truth > 0, let p = model.projectTotal(c.input) else { continue }
                    apes.append(abs(p - c.truth) / c.truth * 100)
                }
                let coverage = bucketCases.isEmpty ? 0 : Double(apes.count) / Double(bucketCases.count)
                let (lo, hi) = bootstrapMedianCI(apes, iterations: bootstrap, rng: &rng)
                scores.append(Score(
                    modelId: model.id, bucket: bucket,
                    medianAbsPctError: median(apes),
                    meanAbsPctError: apes.isEmpty ? .infinity : apes.reduce(0, +) / Double(apes.count),
                    coverage: coverage, n: apes.count, ciLow: lo, ciHigh: hi))
            }
        }
        return scores.sorted { ($0.bucket, $0.medianAbsPctError) < ($1.bucket, $1.medianAbsPctError) }
    }

    /// Paired model-vs-baseline comparison per bucket on shared cases.
    public static func paired(
        model: any Forecaster,
        baseline: any Forecaster,
        cases: [Case],
        bootstrap: Int = 1000,
        seed: UInt64 = 0x5EED
    ) -> [Paired] {
        let byBucket = Dictionary(grouping: cases, by: { $0.bucket })
        var rng = SplitMix64(seed: seed)
        var out: [Paired] = []
        for (bucket, bucketCases) in byBucket {
            var deltas: [Double] = []
            var wins = 0
            for c in bucketCases {
                guard c.truth > 0,
                      let pm = model.projectTotal(c.input),
                      let pb = baseline.projectTotal(c.input) else { continue }
                let am = abs(pm - c.truth) / c.truth * 100
                let ab = abs(pb - c.truth) / c.truth * 100
                deltas.append(am - ab)
                if am < ab { wins += 1 }
            }
            guard !deltas.isEmpty else { continue }
            let (lo, hi) = bootstrapMedianCI(deltas, iterations: bootstrap, rng: &rng)
            out.append(Paired(
                modelId: model.id, baselineId: baseline.id, bucket: bucket,
                medianDelta: median(deltas), ciLow: lo, ciHigh: hi,
                winFraction: Double(wins) / Double(deltas.count), n: deltas.count))
        }
        return out.sorted { $0.bucket < $1.bucket }
    }

    // MARK: - Stats

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return .infinity }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Percentile bootstrap 95% CI on the median. Returns (median, median) when
    /// there's too little data to resample meaningfully.
    static func bootstrapMedianCI(_ xs: [Double], iterations: Int, rng: inout SplitMix64) -> (Double, Double) {
        guard xs.count >= 2, iterations > 0 else {
            let m = median(xs); return (m, m)
        }
        var meds: [Double] = []
        meds.reserveCapacity(iterations)
        let n = xs.count
        for _ in 0..<iterations {
            var sample: [Double] = []
            sample.reserveCapacity(n)
            for _ in 0..<n {
                sample.append(xs[Int(rng.next() % UInt64(n))])
            }
            meds.append(median(sample))
        }
        meds.sort()
        let lo = meds[Int(0.025 * Double(iterations))]
        let hi = meds[min(iterations - 1, Int(0.975 * Double(iterations)))]
        return (lo, hi)
    }
}

/// Deterministic SplitMix64 — reproducible bootstraps (no global RNG, no
/// per-run drift). Internal to the engine.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
