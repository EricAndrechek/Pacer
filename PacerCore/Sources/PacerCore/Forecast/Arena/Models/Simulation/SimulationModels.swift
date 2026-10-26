import Foundation

// Simulated meters (g2-08-fable-burst, g2-07-opus-limit) and their pools (g2-08-fable-burst-mix, g2-07-opus-pool).
extension ArenaRegistry {
    static var simulationModels: [ArenaModelSpec] {
        [
            ArenaModelSpec(name: G208FableBurst.name, targets: [.meterFiveHour], config: G208FableBurst.config,
                           complexity: 4) { G208FableBurst(context: $0) },
            // `model.toml`'s `[config]` is empty: `LimitSim.Config.defaults` are its settings.
            ArenaModelSpec(name: G207OpusLimit.name, targets: [.meterFiveHour, .meterSevenDay, .meterScoped],
                           complexity: 4) { G207OpusLimit(context: $0) },
            ArenaModelSpec(name: G208FableBurstMix.name, targets: [.meterFiveHour],
                           children: ["g2-08-fable-burst", "fm-timestral-123m-meter"],
                           config: [
                               "weights": ["g2-08-fable-burst": 0.5, "fm-timestral-123m-meter": 0.5],
                               "head_min": 3,
                           ],
                           complexity: 5) { G208FableBurstMix(context: $0) },
            ArenaModelSpec(name: G207OpusPool.name, targets: [.meterFiveHour, .meterSevenDay, .meterScoped],
                           children: ["g2-07-opus-limit", "fm-timestral-5m-meter"],
                           config: [
                               "sim": "g2-07-opus-limit",
                               "fm": "fm-timestral-5m-meter",
                               // Share of each target's paths taken from the pretrained model.
                               "fm_weight": ["five_hour": 0.5, "seven_day": 0.5, "weekly_scoped": 0.6],
                           ],
                           complexity: 5) { G207OpusPool(context: $0) },
        ]
    }
}
