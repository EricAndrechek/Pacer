"""Learned models and combiners: as-of features, walk-forward training
sets, quantile and path helpers, and the loss ledger combiners weight
children with.

- `data`: `AsOfData`, a history as arrays; every lookup takes its own `asof`.
- `features`: `FeatureBuilder`, the as-of meter features (`FEATURE_NAMES`).
- `walkforward`: `build_trainset`, past cutoffs labelled only with outcomes
  known at `now`.
- `paths`: quantile tables to paths, sorted-sample CRPS.
- `meter_model`: `LearnedMeterModel`, the shared fit/update/forecast plumbing.
- `combine`: the children's forecasts, scored as truth arrives, and the
  weighting rules (EWA, stacking, FFORMA-style, median).
"""
