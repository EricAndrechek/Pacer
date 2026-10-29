import Foundation

// The analog model and its mix (g1-10-fable-analog, g1-10-fable-mix).
extension ArenaRegistry {
    static var analogModels: [ArenaModelSpec] { [fableAnalog, fableMix] }

    /// `models/g1-10-fable-analog/model.toml`. Only the meter targets are
    /// ported; the hourly, split and next-start tables are transcribed too,
    /// so the config reads as the file does, and nothing reads them.
    static let fableAnalog = ArenaModelSpec(
        name: "g1-10-fable-analog",
        targets: [.meterFiveHour, .meterSevenDay, .meterScoped],
        config: [
            "hourly_history_days": 60,
            "verbose": false,
            "meter": [
                // cut step and trajectory resolution per window kind
                "five_hour": [
                    "step_min": 5, "M": 60, "use_turns": false, "shrink": 0.85,
                    "bw_phase_frac": 0.08, "bw_hour": 2.5, "bw_rate": 1.0, "recency_days": 120,
                    "other_account": 0.3, "weekend_mismatch": 0.5, "target_ess": 30,
                ],
                "seven_day": [
                    "step_min": 30, "M": 168, "use_turns": false,
                    "bw_phase_frac": 0.10, "bw_hour": 2.0, "bw_rate": 0.8,
                    "block_share": 1.0, "block_days": 60, "block_recency_days": 21, "block_bw_total": 1.0,
                    "recency_days": 60, "other_account": 0.3, "weekend_mismatch": 0.5, "target_ess": 30,
                ],
                "weekly_scoped": [
                    "step_min": 30, "M": 168, "use_turns": false,
                    "bw_phase_frac": 0.10, "bw_hour": 2.0, "bw_rate": 0.8,
                    "recency_days": 60, "other_account": 0.3, "weekend_mismatch": 0.5, "target_ess": 30,
                ],
            ],
            "hourly": [
                "bw_hour": 1.5, "bw_rate": 1.0, "bw_day": 1.0, "scale_alpha": 0.5, "recency_days": 30,
                "weekend_mismatch": 0.5, "target_ess": 25, "partial_weight": 0.5,
            ],
            "split": ["bw_share": 0.2, "recency_days": 30, "target_ess": 25],
            "next_start": ["bw_hour": 1.5, "bw_idle": 0.5, "recency_days": 30, "weekend_mismatch": 0.5, "target_ess": 30],
        ],
        // Arithmetic over the account's own cuts: kernels and a weighted
        // quantile, a simulation for the weekly meter.
        complexity: 3
    ) { FableAnalogModel(context: $0) }

    /// `models/g1-10-fable-mix/model.toml`: per target, child → share of the
    /// paths (renormalized over the children that answered). The children
    /// are listed in the shares tables' order, which decides who absorbs
    /// the rounding.
    static let fableMix = ArenaModelSpec(
        name: "g1-10-fable-mix",
        targets: [.meterFiveHour, .meterSevenDay, .meterScoped],
        children: ["g1-10-fable-analog", "port-engine-recent-rate", "spend-decay-1d"],
        config: [
            "shares": [
                "meter.five_hour": ["g1-10-fable-analog": 0.7, "port-engine-recent-rate": 0.3],
                "meter.seven_day": ["g1-10-fable-analog": 0.5, "spend-decay-1d": 0.5],
                "meter.scoped": ["g1-10-fable-analog": 0.5, "spend-decay-1d": 0.5],
            ],
        ],
        // A fixed blend of three models, one of them the analog itself.
        complexity: 4
    ) { FableMixModel(context: $0) }
}
