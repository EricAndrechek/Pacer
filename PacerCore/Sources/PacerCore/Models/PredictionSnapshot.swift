import Foundation
import SwiftData

/// One displayed-prediction snapshot — what the engine was telling the user at
/// a moment in time, together with everything needed to reconstruct *why*:
/// the chosen method, the band and the residual evidence behind it, the state
/// of the window, and the parameter/engine versions that produced it.
///
/// `EngineEvalOutcome` records how candidates did on *completed* periods; this
/// table records the live answers as they were shown. The pair closes the
/// debugging loop the eval table can't: "at 14:03 the badge said limit in
/// 5 min–32 hr — which inputs did that, and what actually happened?" Rows are
/// written by the engine on recompute behind a change/heartbeat policy (not
/// per tick), and pruned after `PredictionSnapshot.retentionDays`.
///
/// `periodKey` matches the eval table's key for the same period (`yyyy-MM-dd`
/// for cost surfaces, the rounded reset ISO-stamp for rate-limit cycles), so
/// snapshot → realized-truth joins are a plain equality — the replay harness
/// leans on this.
@Model
public final class PredictionSnapshot {
    #Index<PredictionSnapshot>([\.surface], [\.surface, \.recordedAt], [\.recordedAt])

    public var recordedAt: Date
    /// `"rl-five_hour"` / `"rl-seven_day"` / `"eod"` / `"month"` — same ids the
    /// self-eval scoreboard uses, so the two tables join on (surface, periodKey).
    public var surface: String
    /// Stable id of the method behind the point (`"diurnal-rate"`, `"eod-pool"`).
    public var method: String
    /// Version tag of the engine's tuning constants (see `EngineParams`).
    public var paramsVersion: String
    /// App marketing version that wrote the row (code changes move predictions
    /// too, not just parameter changes).
    public var engineVersion: String
    /// The period this prediction is *about* — joins to `EngineEvalOutcome`.
    public var periodKey: String
    /// When the period resolves (window reset / local midnight / month end).
    public var periodEnd: Date?

    /// Point estimate — end-of-period utilisation (pp) for rate-limit
    /// surfaces, dollars for cost surfaces. Nil = the engine answered
    /// "insufficient" (that refusal is itself worth recording).
    public var value: Double?
    public var lo80: Double?
    public var hi80: Double?
    public var lo50: Double?
    public var hi50: Double?
    /// `Estimate.Confidence` raw value.
    public var confidence: String
    /// Historical cases backing the estimate (days / cycles).
    public var support: Int
    public var note: String?

    // Rate-limit specifics (nil on cost surfaces).
    /// The point crossing ("limit in 2 hr") and the calibrated band's
    /// earliest/latest crossings — the exact facts the chips render.
    public var crossingAt: Date?
    public var crossingEarliest: Date?
    public var crossingLatest: Date?
    /// Live utilisation at prediction time.
    public var usedPct: Double?
    /// Upward shift applied to pin the model curve to the live reading.
    public var anchorShift: Double?
    /// Descriptive recent slope (pp/hour) at prediction time.
    public var slopePercentPerHour: Double?
    /// Which conformal stratum served the band (`"late|weekday"`, `"pooled"`)
    /// and how many residuals it held — the "was this band honest" evidence.
    public var bandStratum: String?
    public var residualCount: Int?

    // Cost specifics (nil on rate-limit surfaces).
    /// Spend already realized within the period at prediction time.
    public var spendSoFar: Double?

    /// Snapshots older than this are pruned (the eval table keeps the
    /// predicted-vs-truth accuracy record forever; this table is the
    /// high-resolution debugging trail).
    public static let retentionDays = 180

    public init(
        recordedAt: Date,
        surface: String,
        method: String,
        paramsVersion: String,
        engineVersion: String,
        periodKey: String,
        periodEnd: Date?,
        value: Double?,
        lo80: Double? = nil,
        hi80: Double? = nil,
        lo50: Double? = nil,
        hi50: Double? = nil,
        confidence: String,
        support: Int,
        note: String? = nil,
        crossingAt: Date? = nil,
        crossingEarliest: Date? = nil,
        crossingLatest: Date? = nil,
        usedPct: Double? = nil,
        anchorShift: Double? = nil,
        slopePercentPerHour: Double? = nil,
        bandStratum: String? = nil,
        residualCount: Int? = nil,
        spendSoFar: Double? = nil
    ) {
        self.recordedAt = recordedAt
        self.surface = surface
        self.method = method
        self.paramsVersion = paramsVersion
        self.engineVersion = engineVersion
        self.periodKey = periodKey
        self.periodEnd = periodEnd
        self.value = value
        self.lo80 = lo80
        self.hi80 = hi80
        self.lo50 = lo50
        self.hi50 = hi50
        self.confidence = confidence
        self.support = support
        self.note = note
        self.crossingAt = crossingAt
        self.crossingEarliest = crossingEarliest
        self.crossingLatest = crossingLatest
        self.usedPct = usedPct
        self.anchorShift = anchorShift
        self.slopePercentPerHour = slopePercentPerHour
        self.bandStratum = bandStratum
        self.residualCount = residualCount
        self.spendSoFar = spendSoFar
    }
}
