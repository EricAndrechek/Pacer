import Foundation

// Spend-decay (spend-decay-30m/-1h/-6h/-1d), port-live-meter and the calibration layer's calib-* wrappers.
//
// `config` is each model's `model.toml` `[config]`, transcribed.
extension ArenaRegistry {
    static var spendModels: [ArenaModelSpec] {
        [
            spendDecay("spend-decay-30m", targets: [.meterFiveHour], lookbackMin: 30, caseDays: 60, complexity: 2),
            spendDecay("spend-decay-1h", targets: [.meterFiveHour], lookbackMin: 60, caseDays: 60, complexity: 2),
            spendDecay("spend-decay-6h", targets: [.meterSevenDay, .meterScoped], lookbackMin: 360, caseDays: 120,
                       complexity: 2),
            spendDecay("spend-decay-1d", targets: [.meterSevenDay, .meterScoped], lookbackMin: 1440, caseDays: 120,
                       complexity: 2),
            ArenaModelSpec(name: "port-live-meter", targets: [.meterFiveHour, .meterSevenDay, .meterScoped],
                           config: ["neighbours": 400], complexity: 1) { PortLiveMeterModel(context: $0) },
            // The calibration layer (kit/calib.py) over four children. The
            // last two children are other ports' (the analog model,
            // Timestral-5M); a wrapper runs only where its child can.
            calib("calib-spend-decay-30m", child: "spend-decay-30m", targets: [.meterFiveHour], complexity: 3),
            calib("calib-spend-decay-6h", child: "spend-decay-6h", targets: [.meterSevenDay, .meterScoped],
                  complexity: 3),
            calib("calib-g1-10-fable-analog", child: "g1-10-fable-analog",
                  targets: [.meterFiveHour, .meterSevenDay, .meterScoped], complexity: 4),
            calib("calib-fm-timestral-5m-meter", child: "fm-timestral-5m-meter",
                  targets: [.meterFiveHour, .meterSevenDay, .meterScoped], complexity: 5),
        ]
    }

    /// A `models/calib-<child>/` wrapper: `kit/calib.CalibModel` with the
    /// settings every calib-* `model.toml` carries.
    private static func calib(_ name: String, child: String, targets: Set<ArenaTarget>,
                              complexity: Int) -> ArenaModelSpec {
        ArenaModelSpec(
            name: name, targets: targets, children: [child],
            config: [
                "child": .string(child),
                "method": "scale",
                "n0": 8.0,
                "n0_bin": 8.0,
                "s_max": 3.0,
                "min_origins": 3,
                "per_bin": 8,
                "round": true,
                "backtest_every_h": ["five_hour": 2, "seven_day": 8, "weekly_scoped": 8],
                "backtest_n": ["five_hour": 24, "seven_day": 24, "weekly_scoped": 24],
            ],
            complexity: complexity
        ) { try CalibModel(context: $0) }
    }

    private static func spendDecay(_ name: String, targets: Set<ArenaTarget>, lookbackMin: Int, caseDays: Int,
                                   complexity: Int) -> ArenaModelSpec {
        ArenaModelSpec(
            name: name, targets: targets,
            config: [
                "lookback_min": .int(lookbackMin),
                "case_days": .int(caseDays),
                "phase_band": 0.10,
                "default_tau_h": ["five_hour": 2.0, "seven_day": 16.0, "weekly_scoped": 16.0],
            ],
            complexity: complexity
        ) { SpendDecayModel(context: $0) }
    }
}
