import Foundation

/// Picks the current winning forecaster per surface from backtest scores,
/// with the guardrails that keep the choice from chasing noise.
///
/// Three defenses, learned the hard way (the naive baseline is *strong*, and
/// with limited per-user history the backtest itself is noisy):
///
/// 1. **Eligibility** — a candidate needs enough scored cases and enough
///    coverage to be trusted at all.
/// 2. **Prefer-simpler** — among candidates within `preferSimplerWithin` of
///    the best error, take the *simplest* (lowest `complexity`). A 0.3-point
///    edge isn't worth a more complex, more overfit-prone model.
/// 3. **Hysteresis** — don't switch away from the incumbent unless a
///    challenger beats it by `switchMargin`. Stops the selection flapping
///    week to week.
public enum ForecastSelector {

    public struct Selection: Sendable, Equatable {
        /// Chosen forecaster id, or nil when nothing is eligible (caller
        /// should fall back to its hardcoded default).
        public let id: String?
        /// Human-readable rationale (for logging / a "projection method: …"
        /// affordance in the UI).
        public let reason: String
    }

    public struct Policy: Sendable {
        public var minScoredCases: Int
        public var minCoverage: Double
        /// Error gap (percentage points) within which a simpler model is
        /// preferred over a more accurate-but-complex one.
        public var preferSimplerWithin: Double
        /// Error gap a challenger must beat the incumbent by to switch.
        public var switchMargin: Double

        public init(
            minScoredCases: Int = 8,
            minCoverage: Double = 0.6,
            preferSimplerWithin: Double = 2.0,
            switchMargin: Double = 2.0
        ) {
            self.minScoredCases = minScoredCases
            self.minCoverage = minCoverage
            self.preferSimplerWithin = preferSimplerWithin
            self.switchMargin = switchMargin
        }
    }

    public static func select(
        scores: [Backtester.Score],
        incumbentId: String? = nil,
        policy: Policy = Policy()
    ) -> Selection {
        let eligible = scores.filter {
            $0.scoredCount >= policy.minScoredCases
                && $0.coverage >= policy.minCoverage
                && $0.medianAbsPctError.isFinite
        }
        guard let best = eligible.min(by: { $0.medianAbsPctError < $1.medianAbsPctError }) else {
            return Selection(id: nil, reason: "no eligible forecaster (insufficient backtest data)")
        }

        // Prefer-simpler: cheapest model within the error margin of the best.
        let nearBest = eligible.filter { $0.medianAbsPctError <= best.medianAbsPctError + policy.preferSimplerWithin }
        let candidate = nearBest.min {
            ($0.complexity, $0.medianAbsPctError) < ($1.complexity, $1.medianAbsPctError)
        } ?? best

        // Hysteresis: keep the incumbent unless the candidate clears it by the
        // switch margin.
        if let incumbentId,
           let incumbent = eligible.first(where: { $0.id == incumbentId }),
           candidate.id != incumbent.id,
           candidate.medianAbsPctError > incumbent.medianAbsPctError - policy.switchMargin {
            return Selection(
                id: incumbent.id,
                reason: String(format: "kept %@ (%.1f%%); %@ (%.1f%%) didn't beat it by %.0f pts",
                               incumbent.id, incumbent.medianAbsPctError,
                               candidate.id, candidate.medianAbsPctError, policy.switchMargin)
            )
        }

        let simplerNote = candidate.id == best.id ? "" : String(format: " over %@ (%.1f%%)", best.id, best.medianAbsPctError)
        return Selection(
            id: candidate.id,
            reason: String(format: "%@ (%.1f%% median err, %.0f%% coverage)%@",
                           candidate.id, candidate.medianAbsPctError, candidate.coverage * 100, simplerNote)
        )
    }
}
