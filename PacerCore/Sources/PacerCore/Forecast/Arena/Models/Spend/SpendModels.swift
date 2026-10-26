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
        ]
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
