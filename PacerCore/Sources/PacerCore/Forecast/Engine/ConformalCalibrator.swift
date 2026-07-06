import Foundation

/// Split-conformal predictive intervals from a model's own past out-of-sample
/// residuals. The engine's source of honest uncertainty.
///
/// The idea (and why it's the round-2 "real win"): instead of trusting a model's
/// parametric error bars, collect how wrong it actually was on past walk-forward
/// cases, and read the band straight off that empirical residual distribution.
/// Two flavours, matching the surfaces:
/// - `.multiplicative` — residuals are ratios `truth / prediction` (for cost,
///   where error scales with magnitude). Band = `point × [q_lo, q_hi]`.
/// - `.additive` — residuals are differences `truth − prediction` (for rate-limit
///   utilisation in percentage points). Band = `point + [q_lo, q_hi]`.
///
/// Distribution-free and finite-sample honest: with `n` calibration residuals the
/// two-sided level-`L` interval uses the conformal `(n+1)` rank adjustment, so
/// coverage is ≥ `L` in expectation. When `n` is too small the band saturates to
/// the widest observed residual rather than pretending to precision it lacks —
/// exactly the "don't show a confident wrong number" posture.
public struct ConformalCalibrator: Sendable, Equatable {

    public enum Mode: Sendable, Equatable {
        /// Residuals are `truth / prediction` ratios (cost-like, scale-relative).
        case multiplicative
        /// Residuals are `truth − prediction` differences (percentage-point-like).
        case additive
    }

    public let mode: Mode
    /// Calibration residuals, sorted ascending.
    public let residuals: [Double]

    public init(mode: Mode, residuals: [Double]) {
        self.mode = mode
        self.residuals = residuals.filter { $0.isFinite }.sorted()
    }

    public var count: Int { residuals.count }

    /// Build a calibrator from paired out-of-sample (prediction, truth) cases.
    /// Multiplicative skips non-positive predictions (ratio undefined).
    public static func fromPairs(
        mode: Mode,
        predictions: [Double],
        truths: [Double]
    ) -> ConformalCalibrator {
        var rs: [Double] = []
        for (p, t) in zip(predictions, truths) where p.isFinite && t.isFinite {
            switch mode {
            case .multiplicative where p > 0: rs.append(t / p)
            case .additive: rs.append(t - p)
            default: break
            }
        }
        return ConformalCalibrator(mode: mode, residuals: rs)
    }

    /// Two-sided predictive interval at `level` coverage (e.g. 0.8) around a new
    /// point estimate. `nil` when there aren't at least `minResiduals` to form an
    /// honest band.
    public func interval(
        around point: Double,
        level: Double,
        minResiduals: Int = 8
    ) -> ClosedRange<Double>? {
        guard residuals.count >= minResiduals, level > 0, level < 1, point.isFinite else { return nil }
        let alpha = 1 - level
        let lo = quantile(alpha / 2)
        let hi = quantile(1 - alpha / 2)
        let lower: Double
        let upper: Double
        switch mode {
        case .multiplicative:
            lower = point * lo
            upper = point * hi
        case .additive:
            lower = point + lo
            upper = point + hi
        }
        guard lower.isFinite, upper.isFinite, upper >= lower else { return nil }
        return lower...upper
    }

    /// `quantile(_:)` gated the same way `interval(around:level:)` is: `nil`
    /// until at least `minResiduals` residuals exist. A tail read off a
    /// handful of cases is just the most extreme thing that ever happened —
    /// one bad week then stretches every band to "5 min to 32 hours" — so
    /// callers that shift a curve by a raw quantile must use this form and
    /// fall back to the unshifted point when it declines.
    public func gatedQuantile(_ p: Double, minResiduals: Int = 8) -> Double? {
        guard residuals.count >= minResiduals else { return nil }
        return quantile(p)
    }

    /// Empirical quantile of the residuals with the conformal `(n+1)` rank
    /// adjustment. `p` in [0,1]; saturates to the extreme residual past the range
    /// (the honest "can't be more precise than what we've seen").
    public func quantile(_ p: Double) -> Double {
        let n = residuals.count
        guard n > 0 else { return .nan }
        let rank = Int((Double(n + 1) * p).rounded(.up))
        let idx = min(max(rank, 1), n) - 1
        return residuals[idx]
    }
}
