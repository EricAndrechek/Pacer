import Foundation
import SwiftData

/// How one forecast model actually did over one *completed* rate-limit cycle —
/// the persisted memory that turns the tournament into a self-improving loop.
///
/// The tournament re-backtests raw history each time it selects, but it never
/// remembered the verdict. This records, per `(window, cycle, model)`, two
/// things once a cycle finishes:
///   - **accuracy** (`meanAbsError`): how close the model's projected final
///     was to the realized final, averaged across cut points through the cycle;
///   - **convergence** (`convergenceFraction`): *how early* it locked onto the
///     right answer — the earliest fraction of the cycle from which its
///     projection stayed within tolerance. A model that's right by 30% in is
///     worth more than one that's only right at the very end.
///
/// `ForecastScoreboard` aggregates these into per-model weights that drive
/// selection, and the on-device ML candidate is scored here too — so it earns
/// (or loses) its place from real outcomes, not just an offline backtest.
@Model
public final class ForecastModelOutcome {
    #Index<ForecastModelOutcome>([\.window], [\.window, \.modelId])

    /// `"\(window)|\(resetsAtISO)|\(modelId)"` — unique so a completed cycle is
    /// scored exactly once per model.
    @Attribute(.unique) public var key: String
    public var window: String          // "five_hour" | "seven_day"
    public var modelId: String
    /// The cycle's reset boundary — its identity.
    public var resetsAt: Date
    /// Realized final utilization of the cycle (the truth the models aimed at).
    public var trueFinalPct: Double
    /// Mean absolute error (percentage points) of the model's projected final
    /// across the cut grid — overall accuracy through the cycle.
    public var meanAbsError: Double
    /// Earliest fraction of the cycle (0…1) from which the projection stayed
    /// within tolerance of the realized final. 1.0 = it never locked in.
    public var convergenceFraction: Double
    public var recordedAt: Date

    public init(
        window: String,
        modelId: String,
        resetsAt: Date,
        trueFinalPct: Double,
        meanAbsError: Double,
        convergenceFraction: Double,
        recordedAt: Date = Date()
    ) {
        self.key = Self.makeKey(window: window, resetsAt: resetsAt, modelId: modelId)
        self.window = window
        self.modelId = modelId
        self.resetsAt = resetsAt
        self.trueFinalPct = trueFinalPct
        self.meanAbsError = meanAbsError
        self.convergenceFraction = convergenceFraction
        self.recordedAt = recordedAt
    }

    public static func makeKey(window: String, resetsAt: Date, modelId: String) -> String {
        "\(window)|\(ISO8601DateFormatter().string(from: resetsAt))|\(modelId)"
    }
}
