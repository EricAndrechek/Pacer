import Foundation

// Recalibrated foundation-model meters (g1-08-opus-fm, g2-06-opus-fmgate2).
//
// Each entry transcribes the meter part of `research/arena/models/<name>/
// model.toml`; the code is `MeterFM` / `FMCal` (g1-08's `meters.py` and
// `fmcal.py`, which g2-06 carries verbatim) and `Gate` (g2-06's `gate.py`).
// Only Timestral-123M is listed under `weights`: the 28M network in both
// model.tomls serves their spend targets, which are not ported.
//
// The offline PIT prior (`[config.meter.prior]`, "how Timestral-123M is
// typically miscalibrated on cumulative-burn series") is NOT transcribed:
// it was fitted on the arena's visible tier, which is real usage
// (`research/arena/docs/known-issues.md`, "Tuned priors"). Without it a
// lead with too few PITs of its own takes the nearest shorter lead's map,
// else the identity (fmcal's no-prior path). The parity tests read the
// prior from the in-repo model.toml and check the with-prior path too.
extension ArenaRegistry {
    /// `[config.meter]` of g1-08-opus-fm (and `[config.g108.meter]` of
    /// g2-06-opus-fmgate2), without the prior.
    static var g108MeterConfig: ArenaValue {
        [
            "backend": "timestral", "weights": .string(FMWeights.timestral123M), "threads": 2, "stale_min": 120,
            "calibrate": true, "cal_n0": 30, "cal_refresh_h": 24, "prior_strength": 0.5, "cal_age_tau_d": 45,
            // Widening around the calibrated median: weekly crps -0.11/-0.14 at 1.3, five-hour
            // cover80 0.77 -> 0.86 at 1.15 (the agent's note, 70 paired cuts).
            "spread_k": ["five_hour": 1.15, "seven_day": 1.3, "weekly_scoped": 1.3],
            "step_min": ["five_hour": 5, "seven_day": 15, "weekly_scoped": 15],
            // Five-hour: 2 days of 5-min steps beat 12 h and 1 day (the agent's note).
            "context_steps": ["five_hour": 576, "seven_day": 288, "weekly_scoped": 288],
            "cal_every_min": ["five_hour": 60, "seven_day": 180, "weekly_scoped": 180],
            // Weekly: 360 cuts (60 days) with age tau 45 d beat 240 / 30 d on 7d limit calls.
            "cal_cuts": ["five_hour": 200, "seven_day": 360, "weekly_scoped": 360],
        ]
    }

    static var combinedModels: [ArenaModelSpec] {
        [
            // models/g1-08-opus-fm/model.toml
            ArenaModelSpec(
                name: "g1-08-opus-fm",
                targets: [.meterFiveHour, .meterSevenDay, .meterScoped],
                config: ["meter": g108MeterConfig],
                weights: [FMWeights.timestral123M], complexity: 5
            ) { try G108OpusFM(context: $0) },
            // models/g2-06-opus-fmgate2/model.toml
            ArenaModelSpec(
                name: "g2-06-opus-fmgate2",
                targets: [.meterFiveHour, .meterSevenDay, .meterScoped],
                config: [
                    // Per window: shrink the meter paths' spread around their median, gate, round.
                    "gate": [
                        "five_hour": ["shrink": 0.8, "on": true, "min_idle_min": 15, "keep": 0.1, "mode": "shift",
                                      "recency_days": 30, "bw_hour": 2.5, "other_weight": 3.0],
                        "seven_day": ["shrink": 0.8, "on": false, "min_idle_min": 5, "keep": 0.2, "mode": "shift",
                                      "recency_days": 30, "bw_hour": 2.5, "other_weight": 3.0],
                        "weekly_scoped": ["shrink": 0.8, "on": true, "min_idle_min": 2, "keep": 0.05, "mode": "cut",
                                          "recency_days": 30, "bw_hour": 2.5, "other_weight": 3.0],
                    ],
                    "g108": ["meter": g108MeterConfig],
                ],
                weights: [FMWeights.timestral123M], complexity: 5
            ) { try G206OpusFMGate2(context: $0) },
        ]
    }
}
