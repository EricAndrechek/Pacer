import Foundation
import SwiftData

/// How one engine prediction method actually did on one *completed* period —
/// the persisted memory that turns the engine's selection into a self-improving,
/// per-user loop. The cost-surface analogue of `ForecastModelOutcome` (which
/// does this for rate-limit cycles); generalising the feedback loop to "all
/// surfaces" is the whole point of this layer.
///
/// One row = one (surface, method, bucket, period): what a candidate predicted
/// for that period at that cut bucket, and the realized truth. `EngineSelfEval`
/// scores newly-completed periods into these rows on each scan (idempotent), and
/// reads the accumulated rows back to pick the per-user winner and to report
/// "method X is right to Y% on your data". Because it persists, the track record
/// survives restarts and keeps growing — the engine learns continuously from the
/// user's own outcomes rather than re-deriving from scratch each launch.
///
/// Cost-surface rows are dollars computed from priced history, so they are
/// only right while that history is. When a day is repriced the refit replays
/// it and every later day over the stored rows (`EngineSelfEval.staleEODDays`,
/// #329). Rate-limit rows are percentages and never move.
@Model
public final class EngineEvalOutcome {
    #Index<EngineEvalOutcome>([\.surface], [\.surface, \.bucket])

    /// `"\(surface)|\(method)|\(bucket)|\(periodKey)"` — unique so a completed
    /// period is scored exactly once per method/bucket.
    @Attribute(.unique) public var key: String
    /// Which engine surface this scores, e.g. `"eod"` (extensible: monthly, …).
    public var surface: String
    /// The candidate's stable id (a `Forecaster.id`, e.g. `"average-rate"` or
    /// `"regime-gated-eod"`).
    public var method: String
    /// The walk-forward bucket the prediction was made in, e.g. `"cut=0.75|all"`.
    public var bucket: String
    /// The completed period's identity — `yyyy-MM-dd` for the end-of-day surface.
    public var periodKey: String
    /// What the candidate projected for the period total at this cut.
    public var predicted: Double
    /// The realized period total (the truth the candidates aimed at).
    public var truth: Double
    /// Absolute percentage error, stored so the scoreboard aggregates without
    /// recomputing.
    public var absPctError: Double
    public var recordedAt: Date
    /// What produced a rate-limit grade (`EngineSelfEval.NewOutcome.inputs`):
    /// the model's version, and for a model that reads spend the pricing and
    /// history generations. A grade whose inputs no longer match is graded
    /// again. Nil on rows from before it was recorded, and on end-of-day rows.
    public var inputs: String?

    public init(
        surface: String,
        method: String,
        bucket: String,
        periodKey: String,
        predicted: Double,
        truth: Double,
        recordedAt: Date = Date(),
        inputs: String? = nil
    ) {
        self.key = Self.makeKey(surface: surface, method: method, bucket: bucket, periodKey: periodKey)
        self.surface = surface
        self.method = method
        self.bucket = bucket
        self.periodKey = periodKey
        self.predicted = predicted
        self.truth = truth
        self.absPctError = Self.absPctError(predicted: predicted, truth: truth)
        self.recordedAt = recordedAt
        self.inputs = inputs
    }

    /// Replace the scored values after the history they were computed from
    /// changed (#329). `recordedAt` becomes the rescore time.
    public func rescore(predicted: Double, truth: Double, at date: Date) {
        self.predicted = predicted
        self.truth = truth
        self.absPctError = Self.absPctError(predicted: predicted, truth: truth)
        self.recordedAt = date
    }

    static func absPctError(predicted: Double, truth: Double) -> Double {
        truth > 0 ? abs(predicted - truth) / truth * 100 : .infinity
    }

    public static func makeKey(surface: String, method: String, bucket: String, periodKey: String) -> String {
        "\(surface)|\(method)|\(bucket)|\(periodKey)"
    }
}
