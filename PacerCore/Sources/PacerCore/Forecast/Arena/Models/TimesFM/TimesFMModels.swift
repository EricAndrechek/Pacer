import Foundation

// TimesFM meter models (fm-timesfm*), on the native TimesFM network in Kit/FM/TimesFM.
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
        ]
    }
}
