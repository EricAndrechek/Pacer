# Zero-shot foundation models as rate-limit forecasters

Benchmarks on the lab snapshot (`../data`, 4,205 cases: 3,929 five-hour, 276 seven-day) scored by `../score.py`.
Formulation is issue #271's: per-account CUMULATIVE BURN (positive meter increments summed across cycles, never reset)
on a regular grid (5h: 5 min steps; 7d: 15 min steps); an idle gap > 2 h is NaN, not flat. Context = last N steps ending
exactly at `t_cut` (no look-ahead). Forecast horizon = steps to `resets_at`; the model's quantile trajectory at the reset
step (linear interpolation between steps) minus the last cumulative value = burn-to-reset quantiles.
`pred = used_now + median burn`, `q10/q90` likewise, clamped to `[used_now, 100]`. Cases whose context ends in a gap
(no reading for 2 h before the cut) get `pred = used_now`. Models that cannot take NaN (TimesFM, Toto) get inner gaps
linearly interpolated and leading gaps back-filled (`common.fill_gaps`); Timestral, Chronos, TiRex, Moirai receive NaN.

Output names: `fm-<family>-<size>-<ctx>`; `<ctx>` is `<5h context>_<7d context>`:
`1d_1w`, `2d_2w`, `1w_4w` (all models); `6h_3d`, `12h_3d` (Timestral only; the 7d context is 3 days in both).
Context is truncated to each model's maximum (Chronos-Bolt 2048 steps, TimesFM 16384, Toto 4096).

## What ran (versions)
| family | sizes | package / weights | notes |
|---|---|---|---|
| Timestral | 5M 28M 123M 209M | `timestral` @ a534bdb, HF `mistralai/Timestral-*` | CPU (MPS fails: float64 scaler), 21 quantiles, native quantile path |
| Chronos-Bolt | tiny mini small base | `chronos-forecasting` 2.3.2, `amazon/chronos-bolt-*` | 9 quantiles; horizons > 64 steps are autoregressive (the library warns): applies to every 7d case and 5h cases > 64 steps (none; 5h max is 48) |
| Chronos-2 | 120M | same package, `amazon/chronos-2` | 21 quantiles, native long horizon |
| TimesFM 2.5 | 200M | `timesfm` 3.0.2, `google/timesfm-2.5-200m-pytorch` | continuous quantile head, quantile-crossing fix, input normalisation |
| TiRex | 35M | `tirex-ts` 1.4.2, `NX-AI/TiRex` | |
| Moirai 2.0 | small (11M, the only 2.0 size on HF) | `uni2ts` (Moirai2), `Salesforce/moirai-2.0-R-small` | autoregressive quantile-of-quantiles for long horizons |
| Toto | Open-Base-1.0 (151M) | `toto-ts` 0.2.0, `Datadog/Toto-Open-Base-1.0` | 64 sample paths, quantiles of the sampled cumulative |

Torch 2.14.1 (2.7.0 for Toto), Python 3.12, CPU only, 6 threads per job, at most 2 jobs at a time.

## Dependency trouble worth knowing
* `uni2ts` and `toto-ts` pin `numpy<2`; pyarrow >= 20 needs numpy 2, so those venvs pin `pyarrow<20`.
* scipy < 1.16 wheels fail to dlopen on this macOS (`__thread_bss` loader error in `_propack`/`_cobyla`), so Toto's venv pins `scipy>=1.16` (works with numpy 1.26). `lightning` needs `setuptools<81` (pkg_resources).
* Not run: Chronos (T5 original, not requested), Moirai 2.0 base (not released on HF), TimesFM covariate variants.

## Layout / rerun
Separate uv projects: `.` (Timestral), `chronos/`, `timesfm/`, `tirex/`, `moirai/`, `toto/`. Each has `run_<family>.py`;
all share `common.py` (cumulative burn, contexts, quantile -> pred). Examples:
```
cd foundation        && uv run python run_timestral.py 28M 1d_1w     # size, then ctx labels (default: 1d_1w 2d_2w 1w_4w)
cd foundation/chronos&& uv run python run_chronos.py bolt-small       # bolt-tiny|bolt-mini|bolt-small|bolt-base|2
cd foundation/timesfm&& uv run python run_timesfm.py
cd foundation/tirex  && uv run python run_tirex.py
cd foundation/moirai && uv run python run_moirai.py
cd foundation/toto   && TOTO_SAMPLES=64 uv run python run_toto.py
cd ..                && uv run score.py --match fm-
```
Predictions land in `../preds/fm-*.parquet`. Logs in `logs/`.

## Timings (wall clock per name, both windows, 6 threads, other jobs running)
Timestral 5M 4-23 s, 28M 28-70 s, 123M 61-118 s, 209M 119-141 s+; Chronos-Bolt 22-200 s (tiny to base), Chronos-2 18-87 s;
TimesFM ~110 s each; Moirai-2 30-70 s; TiRex 12-14 min each; Toto 8 min (1d_1w), ~15 min (2d_2w), about an hour for 1w_4w.

## Results
See the leaderboard in the hand-off message / re-run `score.py --match fm-`. Summary: several Timestral variants beat the
shipping rule on the 5-hour median (best 2.90 pp at 28M/6h context vs 3.56), on every fold for most; nothing beats
`rule-current` on the 7-day mean (8.18 pp) - the best foundation model is 9.3 pp. Only 276 seven-day cases from ~18 cycles: noisy.
Observed: the 5h gain is on the 4,205-case lab table 10-18%, smaller than issue #271's 29% on the harness's own case set.
