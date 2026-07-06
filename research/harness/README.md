# Pacer prediction replay harness

Python (uv) port of the rate-limit prediction pipeline, replayed **walk-forward**
over the real store: every prediction is made with only the data that existed
at prediction time, then scored against what actually happened. This is where
model/parameter changes earn their way into the app — research in Python,
ship in Swift.

```
uv run pacer_replay.py            # score the shipping configuration
uv run pacer_replay.py --conformal-mode cuts   # calibration experiments
uv run sweep.py                   # grid-sweep the EngineParams knobs
uv run sweep.py --full --json     # bigger grid, machine-readable
uv run weekly_check.py            # the standing check (drift/promotions/sweep)
uv run weekly_check.py --install-agent   # LaunchAgent: Mondays 09:23
```

`weekly_check.py` is the loop's heartbeat: replay vs `baselines.json`,
shadow-promotion progress from the app's own record, and the default sweep —
one line appended to `reports/log.jsonl` every run, a macOS notification only
when something is actionable. Deterministic, no LLM in the loop.

The store (`pacer.sqlite` in the app group) is copied to a temp dir and opened
read-only — the live app is never touched. A full-history replay takes ~1s,
which is why the sweep is a plain deterministic grid: no need for random
search, and every run is reproducible.

## Scores

| metric | meaning | healthy |
|---|---|---|
| `medianAbsErrorPP` | end-at-reset point error (pp) | lower |
| `coverage80` | how often truth landed inside the stated 80% band | ≈ 0.80 |
| `meanPinball` | q10/q90 quantile quality | lower |
| `brier` | "hits the limit before reset" probability quality | lower |
| `bandStatedShare` | how often the residual gate allowed a band at all | context |

`coverage80` is the one to watch: > 0.9 means the bands are wastefully wide
(the old "5 min–32 hr" failure mode), < 0.7 means they're overconfident.

## Adoption protocol (the hysteresis)

`sweep.py` recommends a parameter change **only** when the candidate beats the
shipping baseline in ≥ 3 of 4 contiguous time folds, improves the overall
median by ≥ 5%, and keeps coverage inside [0.70, 0.92]. A "no recommendation"
result is the hysteresis working — noise doesn't move parameters.

Winners land in Swift (`PacerCore/.../Forecast/Engine/EngineParams.swift`) as
a reviewed code change. The `Params` dataclass here mirrors `EngineParams`
exactly, including the canonical string and FNV version tag, so the tag the
sweep prints is the tag the app will record into its prediction snapshots
(`PredictionSnapshot.paramsVersion`, exported at `/v1/predictions/history`).
`EngineParamsTests.versionTagMatchesPythonHarness` pins the cross-language
parity — if either side drifts, CI fails.

## What it does / doesn't replay

Replayed: cycle segmentation, all six burn-trajectory models (including the
shadow Kalman + diurnal), record-driven selection with shadow promotion
floors, live-value anchoring, stratified additive conformal bands with the
gated quantiles. Not replayed (yet): the EOD/month cost surfaces and their
pool selection — extend `Params` + `replay_window` when those knobs need
sweeping.
