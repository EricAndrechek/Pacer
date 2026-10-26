import Foundation

// Chronos meter models (fm-chronos*), on the native Chronos network in Kit/FM/Chronos.
//
// Each entry transcribes `research/arena/models/<name>/model.toml`; the
// model folder there only names its forecaster and settings, and the code is
// `kit/fm/meter_model.py` (here `FMMeterModel`) over the `chronos2` backend.
extension ArenaRegistry {
    static var chronosModels: [ArenaModelSpec] {
        [
            // models/fm-chronos2-meter/model.toml: Chronos-2 (120M), zero-shot, on
            // the meter's cumulative burn; round 1 had it 26.9 % ahead of the
            // shipping rule on the weekly meter. Downloaded on first use.
            ArenaModelSpec(
                name: "fm-chronos2-meter",
                targets: [.meterFiveHour, .meterSevenDay, .meterScoped],
                config: [
                    "backend": "chronos2", "weights": .string(ChronosWeights.chronos2), "threads": 4, "stale_min": 120,
                    "step_min": ["five_hour": 5, "seven_day": 15, "weekly_scoped": 15],
                    // The lab's default context, 1 day / 1 week (not tuned there).
                    "context_steps": ["five_hour": 288, "seven_day": 672, "weekly_scoped": 672],
                ],
                weights: [ChronosWeights.chronos2], complexity: 5
            ) { try FMMeterModel(context: $0) },
        ]
    }
}
