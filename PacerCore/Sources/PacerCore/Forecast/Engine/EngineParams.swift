import Foundation

/// Version tag for the engine's tuning constants — recorded into every
/// `PredictionSnapshot` so a historical prediction stays interpretable after
/// the knobs move ("this row was produced under v1 parameters").
///
/// Today the constants themselves still live where they're used
/// (`EngineSelfEval`, `BurnTrajectoryModels`, `ConformalCalibrator`, …); this
/// tag versions that whole implicit set. Pulling the knobs into an explicit
/// parameter struct (so the replay harness can sweep them and winners ship as
/// a new version here) is the planned follow-up.
public enum EngineParams {
    /// Bump on ANY change to a forecasting constant or model roster — the
    /// snapshot trail's meaning depends on it.
    public static let version = "v1-2026.07-baseline"
}
