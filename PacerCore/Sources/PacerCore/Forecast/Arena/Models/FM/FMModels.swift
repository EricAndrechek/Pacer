import Foundation

// Timestral meter/spend/structural models (fm-timestral-*, struct-timestral-*, g2-01-haiku-weekly-209m-extended).
//
// Each entry transcribes `research/arena/models/<name>/model.toml`; every
// model folder there only names its forecaster and settings, and the code is
// `kit/fm` (here `Kit/FM`). Weights ids are `"<org>/<name>@<revision>"`, as
// the model.toml pins them; `ArenaWeightStore` knows each one's files and
// hashes.
public enum FMWeights {
    public static let timestral5M = "mistralai/Timestral-5M@bdd20cfc15a3fea0e4cb5ccef37f8d3ca7aa335f"
    public static let timestral28M = "mistralai/Timestral-28M@49b26409ac87b5935539a5d8ffe7f397b720db47"
    public static let timestral123M = "mistralai/Timestral-123M@5a147287addda85f6acd8da3fb8858fe9af7e8f7"
    public static let timestral209M = "mistralai/Timestral-209M@9874d252ab0aae16f7f7c999f98f98d6ad7d8365"
    /// The sizes Pacer ships inside the app bundle (`make fetch-weights`);
    /// the others are downloaded on first use (`ArenaWeightStore.ensureAvailable`).
    public static let bundled = [timestral5M, timestral28M]
}

extension ArenaRegistry {
    static var fmModels: [ArenaModelSpec] {
        let sizes: [(tag: String, weights: String, complexity: Int)] = [
            ("5m", FMWeights.timestral5M, 4),
            ("28m", FMWeights.timestral28M, 4),
            ("123m", FMWeights.timestral123M, 5),
            ("209m", FMWeights.timestral209M, 5),
        ]
        var specs: [ArenaModelSpec] = []
        for s in sizes {
            // models/fm-timestral-<size>-meter/model.toml
            specs.append(ArenaModelSpec(
                name: "fm-timestral-\(s.tag)-meter",
                targets: [.meterFiveHour, .meterSevenDay, .meterScoped],
                config: [
                    "backend": "timestral", "weights": .string(s.weights), "threads": 4, "stale_min": 120,
                    "step_min": ["five_hour": 5, "seven_day": 15, "weekly_scoped": 15],
                    // Timestral-28M on the visible tier: 12 h (5-min steps) beat 3 h and 6 h for the
                    // 5-hour meter, matched 1 day; 3 days (15-min steps) matched 1 week for the weekly.
                    "context_steps": ["five_hour": 144, "seven_day": 288, "weekly_scoped": 288],
                ],
                weights: [s.weights], complexity: s.complexity
            ) { try FMMeterModel(context: $0) })
            // models/fm-timestral-<size>-spend/model.toml: hourly spend, the
            // structural models' child. Its arena targets (spend.hourly,
            // tokens.hourly) are not meters, so it registers none: only
            // `struct-timestral-<size>` asks it, through `FMSpendModel.hourly`.
            specs.append(ArenaModelSpec(
                name: "fm-timestral-\(s.tag)-spend",
                targets: [],
                config: [
                    "backend": "timestral", "weights": .string(s.weights), "threads": 4, "context_hours": 336,
                    // Visible tier: all four covariates beat none and calendar alone on the real
                    // snapshot; companion variates were within noise, so none by default.
                    "covariates": ["calendar", "meter", "sessions", "prompts"],
                    "multivariate": "none", "max_variates": 5, "rho": 0.8, "transform": "none", "cap_factor": 1.5,
                ],
                weights: [s.weights], complexity: s.complexity
            ) { try FMSpendModel(context: $0) })
            // models/struct-timestral-<size>/model.toml: the child's spend paths
            // through the account's spend-to-meter conversion. It lists the
            // child's weights (the model.toml has none of its own) so the runner
            // never runs it before they are on the Mac.
            specs.append(ArenaModelSpec(
                name: "struct-timestral-\(s.tag)",
                targets: [.meterFiveHour, .meterSevenDay, .meterScoped],
                children: ["fm-timestral-\(s.tag)-spend"],
                config: [
                    "child": .string("fm-timestral-\(s.tag)-spend"), "child_paths": 200, "start": "live",
                    "spend_by": "total", "weak": "ratio", "family_dependence": "comonotone",
                ],
                weights: [s.weights], complexity: 5
            ) { try FMStructModel(context: $0) })
        }
        // models/g2-01-haiku-weekly-209m-extended/model.toml: Timestral-209M
        // with 14 days of context (1344 steps of 15 min) for the weekly meter.
        specs.append(ArenaModelSpec(
            name: "g2-01-haiku-weekly-209m-extended",
            targets: [.meterSevenDay],
            config: [
                "backend": "timestral", "weights": .string(FMWeights.timestral209M), "threads": 4, "stale_min": 120,
                "step_min": ["seven_day": 15],
                "context_steps": ["seven_day": 1344],
            ],
            weights: [FMWeights.timestral209M], complexity: 5
        ) { try FMMeterModel(context: $0) })
        return specs
    }
}
