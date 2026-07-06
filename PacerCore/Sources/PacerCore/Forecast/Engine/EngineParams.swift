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
