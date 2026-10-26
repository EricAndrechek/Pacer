# Vendored: Moirai 2.0 inference path

Source: `uni2ts` 2.0.0 wheel from PyPI (Salesforce, Apache-2.0; see `LICENSE`).

Files taken (imports rewritten to relative, Apache headers kept):
- `moirai2_module.py` from `model/moirai2/module.py` (`Moirai2Module`; the `PyTorchModelHubMixin` base is dropped)
- `forecast.py` from `model/moirai2/forecast.py` (`Moirai2Forecast.forward/predict/_convert/_generate_time_id/_patched_seq_pad/_format_preds`, rewritten as plain functions for univariate, no covariates) and `transform/imputation.py` (`CausalMeanImputation` as a function, quirks kept so numbers match)
- `common/torch_util.py`, `module/{norm,packed_scaler,transformer,attention,ffn,ts_embed}.py`, `module/position/*` unchanged apart from imports
- `__init__.py`: new; `Moirai2.load_local(path)` and `predict_quantiles`

Why: uni2ts pins numpy~=1.26, torch<2.5, scipy~=1.11 and drags in jax, lightning, hydra and gluonts; the arena needs numpy 2 and torch 2.10. Removed: Lightning, gluonts, hub mixin, training paths, covariate handling.

Verified against `uni2ts==2.0.0` on numpy 1.26 / torch 2.4.1: relative error about 1e-7 (horizon 48) to 4e-5 (autoregressive, horizon 700) on float32 values up to ~5e4.
Note: upstream `predict` imputes NaN in place on the caller's arrays; this port does not.
