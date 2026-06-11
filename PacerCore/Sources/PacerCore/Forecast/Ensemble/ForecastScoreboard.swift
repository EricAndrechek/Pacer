import Foundation

/// Aggregates the per-completed-cycle `ForecastModelOutcome` records into
/// per-model scores the shared `ForecastSelector` can rank — turning
/// accumulated real-world verdicts into the model the dashboard picks.
///
/// The key twist over a plain accuracy average: a model that *converges early*
/// is worth more than one that's only right at the very end. So the effective
/// error folds in the convergence fraction:
///
///   effectiveError = median(meanAbsError) + convergenceWeight · median(convergenceFraction)
///
/// A model that nails the final by 30% into cycles beats one that only nails it
/// at 90%, even at equal raw accuracy. As cycles accumulate this scoreboard
/// gradually overrides the cold-start on-the-fly backtest — and because the ML
/// candidate is recorded here too, it earns its slot from real outcomes.
public enum ForecastScoreboard {

    /// A decoupled view of a `ForecastModelOutcome` row (so this stays pure
    /// and testable without SwiftData).
    public struct Record: Sendable, Equatable {
        public let window: String
        public let modelId: String
        public let meanAbsError: Double
        public let convergenceFraction: Double
        public init(window: String, modelId: String, meanAbsError: Double, convergenceFraction: Double) {
            self.window = window
            self.modelId = modelId
            self.meanAbsError = meanAbsError
            self.convergenceFraction = convergenceFraction
        }
    }

    /// Percentage-point penalty per unit of convergence fraction. Converging
    /// only at the very end (1.0) rather than immediately (0) adds this many
    /// effective pp — the lever that makes selection prefer models that get it
    /// right *early*.
    public static let convergenceWeight: Double = 15

    /// Aggregate the records for one window into `Backtester.Score`s. The
    /// `medianAbsPctError` field carries the *effective* error (accuracy +
    /// earliness penalty); `meanAbsPctError` carries the raw accuracy for
    /// display. `scoredCount` is how many completed cycles backed each model.
    public static func scores(
        for window: String,
        records: [Record],
        models: [any BurnTrajectory.Model] = BurnTrajectory.defaultModels
    ) -> [Backtester.Score] {
        let complexity = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0.complexity) })
        let byModel = Dictionary(grouping: records.filter { $0.window == window }, by: { $0.modelId })
        return byModel.map { id, recs in
            let rawError = median(recs.map { $0.meanAbsError })
            let convergence = median(recs.map { $0.convergenceFraction })
            return Backtester.Score(
                id: id,
                complexity: complexity[id] ?? 3,
                medianAbsPctError: rawError + convergenceWeight * convergence,
                meanAbsPctError: rawError,
                coverage: 1,
                scoredCount: recs.count
            )
        }
    }

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return .infinity }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
