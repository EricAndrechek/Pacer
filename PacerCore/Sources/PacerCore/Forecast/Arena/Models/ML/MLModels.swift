import Foundation

// Learned meters trained walk-forward on the history's own past (ml-gbm-quantile), on kit/ml.
//
// `config` is the model's `model.toml` `[config]`, transcribed.
extension ArenaRegistry {
    static var mlModels: [ArenaModelSpec] {
        [
            ArenaModelSpec(
                name: "ml-gbm-quantile", targets: [.meterFiveHour, .meterSevenDay, .meterScoped],
                config: [
                    "levels": [0.03, 0.1, 0.25, 0.5, 0.75, 0.9, 0.97],
                    "max_rows": 3000,           // walk-forward cutoffs per window kind (each with up to 8 leads)
                    "min_rows": 60,             // fewer: the burn fallback
                    "retrain_h": 24,            // retrain once this much new data has arrived (long runs)
                    "n_estimators": 150,
                    "learning_rate": 0.05,
                    "num_leaves": 15,
                    "min_child_samples": 20,
                    "weekly_num_leaves": 7,     // seven-day and scoped meters have far fewer cycles
                    "weekly_min_child_samples": 10,
                    "calibrate_folds": 3,       // out-of-fold rescaling of each level's spread; 0 = off
                    "default_scale": [1.2, 1.2, 1.1, 1.0, 1.3, 1.7, 2.0],
                    "prior_cycles": 10,         // weight of the prior, in cycles
                    "min_cycles": 4,            // fewer cycles to learn from: the burn fallback
                    // Swift-only (see KitMLLearnedMeterModel): train at the start of
                    // each retrain_h bucket and reuse it for every cut in it, the
                    // Python's update rule as a function of the cut; 0 trains at the
                    // cut. Keep the last train_cache_buckets buckets per meter.
                    // Weekly meters take 72 h buckets: their cuts are ~19 h
                    // apart, so 24 h retrained at nearly every cut (211 CPU s
                    // per account on first launch); 72 h keeps a model at most
                    // three days behind for about a third of that.
                    "train_align_h": ["five_hour": 24, "seven_day": 72, "weekly_scoped": 72],
                    "train_cache_buckets": 8,
                ],
                complexity: 4
            ) { try MLGBMQuantileModel(context: $0) },
        ]
    }
}
