import Foundation

/// "What's normal for this user" — typical-range bands, anomaly flags, and a
/// pace-vs-norm signal. Greenfield (the app ships no norms today); the round-2
/// research made these the cleanest, best-calibrated wins.
///
/// Everything is computed in **log space**, because cost is heavy-right-tailed:
/// in dollars even a huge day is barely an outlier while the many quiet days look
/// extreme, so a naive z-score flags the wrong thing. In log space the tail
/// compresses, and the honest finding holds — for this user the anomalies are
/// *lulls, not spikes* (a dead Saturday stands out, a busy day doesn't).
///
/// Two anti-overfit defences carried from the research: bucket bands shrink their
/// spread toward the pooled spread by sample count (a 2-sample bucket can't show
/// a false-narrow band), and per-bucket *means* are empirical-Bayes-shrunk via
/// `EmpiricalBayes`. Robust statistics (median / MAD) throughout so a single
/// spike doesn't define "normal".
public enum UsageNorms {

    public enum Verdict: String, Sendable, Equatable { case lull, normal, spike }

    /// A typical-range for one bucket (a weekday, an hour-of-day, a weekday×hour
    /// cell): the central estimate plus the inner 50% and 80% ranges.
    public struct Band: Sendable, Equatable {
        public let typical: Double                 // robust central (median in log space)
        public let range50: ClosedRange<Double>
        public let range80: ClosedRange<Double>
        public let count: Int
    }

    /// Floor so `$0` days have a finite log (and become "very low", not −∞).
    static let logFloor = 0.01

    // MARK: - Typical-range bands

    /// EB-shrunk typical-range bands per bucket from labeled samples. Bucket means
    /// are James–Stein-shrunk toward the pooled mean; bucket spreads are shrunk
    /// toward the pooled spread by `(n−1)/((n−1)+varPseudocount)` so thin buckets
    /// inherit a sane width instead of a falsely-tight one.
    public static func bands(_ samples: [(key: String, value: Double)],
                             varPseudocount: Double = 3) -> [String: Band] {
        let groups = Dictionary(grouping: samples, by: { $0.key })
        guard !groups.isEmpty else { return [:] }

        var keys: [String] = []
        var ebGroups: [EmpiricalBayes.Group] = []
        var cellVar: [String: Double] = [:]
        var cellN: [String: Int] = [:]
        for (k, rows) in groups {
            let logs = rows.map { logCost($0.value) }
            keys.append(k)
            ebGroups.append(.init(mean: mean(logs), count: logs.count, within: variance(logs)))
            cellVar[k] = variance(logs)
            cellN[k] = logs.count
        }
        let shr = EmpiricalBayes.shrink(ebGroups)
        let pooledVar = shr.withinVar

        var out: [String: Band] = [:]
        for (i, k) in keys.enumerated() {
            let mu = shr.shrunkMeans[i]
            let n = cellN[k] ?? 0
            let wv = Double(max(0, n - 1)) / (Double(max(0, n - 1)) + varPseudocount)
            let sd = (wv * (cellVar[k] ?? 0) + (1 - wv) * pooledVar).squareRoot()
            func band(_ z: Double) -> ClosedRange<Double> { exp(mu - z * sd)...exp(mu + z * sd) }
            out[k] = Band(typical: exp(mu), range50: band(0.6745), range80: band(1.2816), count: n)
        }
        return out
    }

    // MARK: - Anomaly

    /// Robust z-score of `value` against a baseline, in log space: how many
    /// median-absolute-deviations from the baseline median. Negative = unusually
    /// low (a lull), positive = unusually high (a spike). 0 when the baseline is
    /// too small to judge (`< minBaseline`) — the engine's warm-up gate.
    public static func anomalyZ(value: Double, baseline: [Double], minBaseline: Int = 14) -> Double {
        guard baseline.count >= minBaseline else { return 0 }
        let logs = baseline.map { logCost($0) }
        let med = median(logs)
        let mad = median(logs.map { abs($0 - med) })
        let scale = mad > 0 ? 1.4826 * mad : standardDeviation(logs)
        guard scale > 0 else { return 0 }
        return (logCost(value) - med) / scale
    }

    public static func classify(z: Double, threshold: Double = 3) -> Verdict {
        if z <= -threshold { return .lull }
        if z >= threshold { return .spike }
        return .normal
    }

    // MARK: - Pace vs norm

    /// Where `value` sits in the baseline distribution, as a percentile rank in
    /// [0,1]. 0.5 = right at the personal median, 0.9 = higher than 90% of
    /// comparable periods ("running hot"). `nil` when the baseline is empty.
    public static func paceRank(value: Double, baseline: [Double]) -> Double? {
        guard !baseline.isEmpty else { return nil }
        let below = baseline.reduce(0) { $0 + ($1 < value ? 1 : 0) }
        return Double(below) / Double(baseline.count)
    }

    // MARK: - Stats

    static func logCost(_ v: Double) -> Double { Foundation.log(max(v, logFloor)) }
    static func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
    static func variance(_ xs: [Double]) -> Double {
        guard xs.count > 1 else { return 0 }
        let m = mean(xs)
        return xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1)
    }
    static func standardDeviation(_ xs: [Double]) -> Double { variance(xs).squareRoot() }
    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
