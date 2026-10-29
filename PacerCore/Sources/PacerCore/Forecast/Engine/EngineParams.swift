import Foundation

/// The engine's tunable constants, pulled into one explicit, versioned set —
/// the single source of truth the estimators read and the replay harness
/// sweeps.
///
/// Every `PredictionSnapshot` row records `versionTag`, which is derived from
/// the VALUES (not hand-bumped): change any knob and every subsequent row
/// carries a new tag automatically, so historical predictions stay
/// interpretable across tunings.
///
/// **Adoption protocol (hysteresis lives in the harness, not the app):** the
/// Python replay harness (`research/harness`) sweeps these knobs walk-forward
/// over the real store and recommends a change only when the winner is robust
/// — better on the primary score in (almost) every fold, not just on average,
/// and never worse on interval coverage. Winners land here as a reviewed code
/// change; the app never mutates its own parameters at runtime, so selection
/// noise can't thrash live behavior.
public struct EngineParams: Sendable, Equatable, Codable {

    // MARK: Conformal bands (rate-limit crossing/outlook uncertainty)

    /// Minimum residuals before `ConformalCalibrator` will state a band or a
    /// quantile shift; below this the surfaces show the point alone.
    public var conformalMinResiduals: Int = 8
    /// Minimum scores for a conformal stratum (early/late × weekday/weekend)
    /// to stand alone; thinner strata fall back to the pooled calibrator.
    public var rlStratumMinScores: Int = 10

    // MARK: End-of-day pool selection (EngineSelfEval)

    /// A method joins a cut's pool when its per-cut median APE is within this
    /// relative factor of the best method's.
    public var poolTolerance: Double = 1.25
    /// Scored days a method needs at a cut before it can join that pool.
    public var poolMinPeriods: Int = 10
    /// Selection sees only the most recent N scored days per cut (drift
    /// insurance); the all-time record still powers the accuracy display.
    public var poolRecencyWindow: Int = 30

    // MARK: Burn-trajectory candidates

    /// `LinearRecent`: recent window as a fraction of the cycle duration.
    public var linearRecentLookbackFraction: Double = 0.3
    /// `RecencyWeighted` / `DampedAcceleration`: recency half-life as a
    /// fraction of the cycle duration.
    public var recencyHalfLifeFraction: Double = 0.15

    // MARK: Conformal residual grouping

    /// Below this many completed cycles, the rate-limit calibrator collapses
    /// each cycle's cut-residuals to ONE per (cycle, stratum) — per-cycle
    /// blocks. Residuals from one cycle are strongly correlated (a heavy week
    /// blows all 8 cuts at once), so counting them separately overstates the
    /// effective sample and yields confidently-too-narrow bands: measured
    /// 0.12 coverage on an 80% band in the 7d window's first fold. With
    /// plentiful cycles the within-cycle spread is real tail information
    /// (5h holds 0.785 with per-cut residuals), so past the threshold the
    /// grouping switches back. Validated in research/harness (2026-07-06).
    public var conformalBlockMinCycles: Int = 40

    // MARK: Rate-limit model selection (#305)

    /// Rank each window's models at the point of the window the live cycle is
    /// at: an error graded at a cut counts `1 − |cut − now| / width`
    /// (`EngineSelfEval.cutWeight`). Replaced selecting by half of the window
    /// (#305, `rlSelectByPhase`) on 2026-10-27, from a walk-forward replay of
    /// the owner's record; 0 counts every cut the same.
    public var rlCutKernelHalfWidth: Double = 0.2
    /// The selection near-tie band as a fraction of the best model's typical
    /// error. 0 restores the absolute 1.5 pp band.
    public var rlTieRelative: Double = 0.05
    /// Rank on the moments where the models' forecasts spread at least this
    /// many points (`EngineSelfEval.rankRL`'s `disagreement`); 0 counts every
    /// moment. Where every model said the same, the outcome tells nothing
    /// about which is better, and on quiet accounts those moments put every
    /// model at ±0, so the simplest won whatever the record said. Chosen
    /// from a walk-forward replay of the owner's record through the shipping
    /// ranking (`RankingReplayProbe`) on 2026-10-29.
    public var rlDisagreementPoints: Double = 2

    public init() {}

    /// The values the shipping engine runs with.
    public static let current = EngineParams()

    /// Tag recorded into every prediction snapshot — a semantic prefix plus a
    /// hash of the values, e.g. `"v1-a41bcd12"`.
    public static var version: String { current.versionTag }

    public var versionTag: String { "v1-" + String(format: "%08x", UInt32(truncatingIfNeeded: fnv1a(canonical))) }

    /// Canonical `key=value` string over every knob, fixed order — the hash
    /// input. Extend when adding a knob (order matters; append, don't sort).
    var canonical: String {
        func g(_ v: Double) -> String { String(format: "%g", v) }
        return [
            "conformalMinResiduals=\(conformalMinResiduals)",
            "rlStratumMinScores=\(rlStratumMinScores)",
            "poolTolerance=\(g(poolTolerance))",
            "poolMinPeriods=\(poolMinPeriods)",
            "poolRecencyWindow=\(poolRecencyWindow)",
            "linearRecentLookbackFraction=\(g(linearRecentLookbackFraction))",
            "recencyHalfLifeFraction=\(g(recencyHalfLifeFraction))",
            "conformalBlockMinCycles=\(conformalBlockMinCycles)",
            "rlCutKernelHalfWidth=\(g(rlCutKernelHalfWidth))",
            "rlTieRelative=\(g(rlTieRelative))",
            "rlDisagreementPoints=\(g(rlDisagreementPoints))",
        ].joined(separator: ";")
    }

    /// FNV-1a 64-bit — tiny, dependency-free, stable across runs/platforms
    /// (unlike `Hasher`, which is seeded per process).
    private func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
