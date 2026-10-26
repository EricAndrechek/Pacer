import Foundation

// Pooled and combined meters over other models (g2-05-sonnet-final, g1-05-opus-ens-meter-big, g1-01-sonnet-calibrate123), on kit/ml/combine.
//
// Each entry transcribes `research/arena/models/<name>/model.toml`. A model
// whose child needs pinned weights lists them too (as `struct-timestral-*`
// does), so the runner never runs it before they are on the Mac: without
// them the Python would run a different model (g1-05 without its foundation
// child, g1-01 not at all).
extension ArenaRegistry {
    static var ensembleModels: [ArenaModelSpec] {
        let meters: Set<ArenaTarget> = [.meterFiveHour, .meterSevenDay, .meterScoped]
        let windows: (Double, Double) -> ArenaValue = { five, weekly in
            ["five_hour": .double(five), "seven_day": .double(weekly), "weekly_scoped": .double(weekly)]
        }
        let g105Children = [
            "fm-timestral-123m-meter", "spend-decay-1d", "spend-decay-6h", "spend-decay-1h",
            "port-engine-recent-rate", "port-engine-kalman-trend",
        ]
        return [
            // models/g2-05-sonnet-final/model.toml: Timestral-123M + the 6 h
            // burn-decay (a fixed mixture for the weekly meters), then the
            // zero-mass layer. Everything in one model; no children.
            ArenaModelSpec(
                name: "g2-05-sonnet-final", targets: meters,
                config: [
                    "w_decay": 0.5, "tau_d": 14.0, "h_since": 0.8, "h_rate": 0.8, "tod_h": 0.0, "n0": 3.0,
                    "max_samples": 6000, "delta": 0.5, "stale_min": 120,
                    // 5 h: no pinning (pinning at 0.6 doubled next_reading_ae and tilted the PIT).
                    "pi_scale": windows(0.0, 1.0),
                    "fm": [
                        "backend": "timestral", "weights": .string(FMWeights.timestral123M), "threads": 2,
                        "stale_min": 120,
                        "step_min": ["five_hour": 5, "seven_day": 15, "weekly_scoped": 15],
                        "context_steps": ["five_hour": 144, "seven_day": 288, "weekly_scoped": 288],
                    ],
                    "decay": [
                        "lookback_min": 360, "case_days": 120, "phase_band": 0.10,
                        "default_tau_h": windows(2.0, 16.0),
                    ],
                    "up_k": windows(1.4, 1.2),
                ],
                weights: [FMWeights.timestral123M], complexity: 5
            ) { try SonnetFinalModel(context: $0) },
            // models/g1-05-opus-ens-meter-big/model.toml: a lead-banded,
            // spread-calibrated mixture of six diverse children.
            ArenaModelSpec(
                name: "g1-05-opus-ens-meter-big", targets: meters, children: g105Children,
                config: [
                    "children": .array(g105Children.map { .string($0) }),
                    "pool": "mixture", "bands": [0.15, 0.5], "shrink": 0.05, "recal": "scale",
                    "rises": [0.0, 0.25, 0.5, 0.75, 1.0, 1.25], "rise_shrink": 0.15, "scale_shrink": 0.25,
                    "scales": [0.3, 0.4, 0.5, 0.6, 0.75, 0.9, 1.0, 1.2, 1.5], "beta_n0": 40.0, "min_points": 12,
                    "m_fit": 40, "max_evals": 16,
                    "half_life_n": ["five_hour": 24, "seven_day": 48, "weekly_scoped": 48],
                    "monotone": true, "floor_live": true, "direct_extras": true,
                    "anchor_tau_min": ["five_hour": 8, "seven_day": 25, "weekly_scoped": 25],
                    "backtest_every_h": ["five_hour": 3, "seven_day": 12, "weekly_scoped": 12],
                    "backtest_n": 6,
                ],
                weights: [FMWeights.timestral123M], complexity: 5
            ) { try BandedEnsemble(context: $0) },
            // models/g1-01-sonnet-calibrate123/model.toml: Timestral-123M's
            // paths pulled toward its median by a fixed 0.6.
            ArenaModelSpec(
                name: "g1-01-sonnet-calibrate123", targets: meters, children: ["fm-timestral-123m-meter"],
                config: [
                    "child": "fm-timestral-123m-meter",
                    "backtest_every_h": ["five_hour": 3, "seven_day": 12, "weekly_scoped": 12],
                    "scale": 0.60,
                ],
                weights: [FMWeights.timestral123M], complexity: 4
            ) { Calibrate123Model(context: $0) },
        ]
    }
}
