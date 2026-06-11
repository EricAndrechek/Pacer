import Foundation

/// Empirical-Bayes / James–Stein shrinkage of per-group means toward the pooled
/// mean. The engine's defence against the overfitting problem the user named:
/// *a complex model overfits the bulk so a simple one wins on deviations.*
///
/// The fix isn't "pick simple" — it's to estimate each regime cell (a weekday, an
/// hour-of-day, a weekday×hour bucket) but only *trust it as far as the data
/// supports*. A cell with many consistent samples keeps its own mean; a thin or
/// noisy cell is pulled toward the global mean. The shrinkage weight
/// `w = τ² / (τ² + σ²/n)` is derived, not hand-tuned: when the between-group
/// signal `τ²` is ~0 (this user's weekday cost carries almost none), every cell
/// collapses to flat automatically — so seasonal structure can ship from day one
/// without an eligibility cliff, and can't overfit when the signal isn't there.
///
/// `signalShare = τ² / (τ² + σ²)` is the one-number summary: 0 ⇒ no group signal
/// (use flat), 1 ⇒ groups are genuinely distinct.
public enum EmpiricalBayes {

    /// One group's sufficient statistics. `within` is the variance of the
    /// individual observations in the group (its noise), `count` their number.
    public struct Group: Sendable, Equatable {
        public let mean: Double
        public let count: Int
        public let within: Double
        public init(mean: Double, count: Int, within: Double) {
            self.mean = mean
            self.count = count
            self.within = within
        }
    }

    public struct Result: Sendable, Equatable {
        /// Shrunk group means, aligned to the input order.
        public let shrunkMeans: [Double]
        /// Per-group shrink weight toward the group's *own* mean (0 = full pool,
        /// 1 = no shrink).
        public let weights: [Double]
        /// Count-weighted pooled mean (the shrink target).
        public let grandMean: Double
        /// Estimated between-group variance τ² (the "signal").
        public let betweenVar: Double
        /// Estimated pooled within-group (per-observation) variance σ² (the "noise").
        public let withinVar: Double
        /// τ² / (τ² + σ²) ∈ [0,1]. 0 ⇒ shrink everything to flat.
        public let signalShare: Double
    }

    /// Shrink the given groups. Groups with `count < minCount` (default 1) are
    /// dropped from the τ²/σ² estimation but still returned, shrunk fully to the
    /// grand mean (we have no basis to trust them).
    public static func shrink(_ groups: [Group], minCount: Int = 1) -> Result {
        guard !groups.isEmpty else {
            return Result(shrunkMeans: [], weights: [], grandMean: 0,
                          betweenVar: 0, withinVar: 0, signalShare: 0)
        }

        let usable = groups.filter { $0.count >= max(1, minCount) }
        let totalCount = usable.reduce(0) { $0 + $1.count }
        // Count-weighted grand mean (the pooled center we shrink toward).
        let grand: Double = totalCount > 0
            ? usable.reduce(0.0) { $0 + Double($1.count) * $1.mean } / Double(totalCount)
            : groups.reduce(0.0) { $0 + $1.mean } / Double(groups.count)

        // Pooled within-group (per-observation) variance σ², weighted by (n−1).
        let dof = usable.reduce(0) { $0 + max(0, $1.count - 1) }
        let withinVar: Double = dof > 0
            ? usable.reduce(0.0) { $0 + Double(max(0, $1.count - 1)) * $1.within } / Double(dof)
            : (usable.map(\.within).reduce(0, +) / Double(max(1, usable.count)))

        // Method-of-moments τ²: the observed spread of group means around the
        // grand mean, minus the sampling variance that spread would have under
        // pure noise. Clamp at 0 (no negative signal).
        let k = usable.count
        var betweenObserved = 0.0
        var meanSamplingVar = 0.0
        if k > 0 {
            for g in usable {
                betweenObserved += (g.mean - grand) * (g.mean - grand)
                meanSamplingVar += withinVar / Double(max(1, g.count))
            }
            betweenObserved /= Double(k)        // variance of group means
            meanSamplingVar /= Double(k)        // avg sampling variance of a group mean
        }
        let betweenVar = max(0, betweenObserved - meanSamplingVar)

        // Per-group shrink weight and shrunk mean.
        var shrunk: [Double] = []
        var weights: [Double] = []
        shrunk.reserveCapacity(groups.count)
        weights.reserveCapacity(groups.count)
        for g in groups {
            let samplingVar = withinVar / Double(max(1, g.count))
            let denom = betweenVar + samplingVar
            // Untrusted (below minCount) or degenerate denom ⇒ full pool.
            let w = (g.count >= max(1, minCount) && denom > 0) ? betweenVar / denom : 0
            shrunk.append(grand + w * (g.mean - grand))
            weights.append(w)
        }

        let signalShare = (betweenVar + withinVar) > 0 ? betweenVar / (betweenVar + withinVar) : 0
        return Result(shrunkMeans: shrunk, weights: weights, grandMean: grand,
                      betweenVar: betweenVar, withinVar: withinVar, signalShare: signalShare)
    }
}
