import Foundation

// TimesFM meter models (fm-timesfm*), on the native TimesFM network in Kit/FM/TimesFM,
// and the stack that uses one (g1-01-sonnet-calstack).
extension ArenaRegistry {
    static var timesfmModels: [ArenaModelSpec] {
        [
            // models/fm-timesfm25-meter/model.toml: TimesFM 2.5 (200M), zero-shot,
            // on the meter's cumulative burn; the logic is kit.fm.meter_model.
            ArenaModelSpec(
                name: "fm-timesfm25-meter",
                targets: [.meterFiveHour, .meterSevenDay, .meterScoped],
                config: [
                    "backend": "timesfm25", "weights": .string(FMWeights.timesfm25), "threads": 4, "stale_min": 120,
                    "step_min": ["five_hour": 5, "seven_day": 15, "weekly_scoped": 15],
                    // The lab's default context, 1 day / 1 week (not tuned here).
                    "context_steps": ["five_hour": 288, "seven_day": 672, "weekly_scoped": 672],
                ],
                weights: [FMWeights.timesfm25], complexity: 5
            ) { try FMMeterModel(context: $0) },
            // models/g1-01-sonnet-calstack/model.toml: a CRPS stack of the
            // calibrated Timestral-123M and TimesFM 2.5. No weights of its own,
            // as in its model.toml: the runner waits for its children's
            // (`ArenaRunner.requiredWeights`).
            ArenaModelSpec(
                name: "g1-01-sonnet-calstack",
                targets: [.meterFiveHour, .meterSevenDay, .meterScoped],
                children: ["g1-01-sonnet-calibrate123", "fm-timesfm25-meter"],
                config: [
                    "children": ["g1-01-sonnet-calibrate123", "fm-timesfm25-meter"],
                    "pool": "mixture", "shrink": 0.15, "half_life_n": 24,
                    "backtest_every_h": ["five_hour": 3, "seven_day": 12, "weekly_scoped": 12],
                    "backtest_n": 4, "max_evals": 16,
                ],
                complexity: 5
            ) { try CalstackModel(context: $0) },
        ]
    }
}
