# Forecast arena: generation {{GEN}}

You are one of several agents, each in a sealed copy of this repo, writing a
model that forecasts Claude Code usage. Your brief (`BRIEF.md`) gives your
niche. This file is the same for everyone.

## The goal

Forecast **whole paths, with honest uncertainty**: how a rate-limit meter will
climb until its window resets, how much will be spent per hour, and so on,
for one account or a group. A good model is accurate early in a window,
adapts as new readings arrive, and would work on anyone's data, not just
this setup's. Scores reward calibrated spread, not just the middle line.

## The model contract

A model is a folder `models/<name>/` with `model.py` (a class `Model`) and
`model.toml`. `models/example-linear/` is the reference: read it first, it
takes a minute. The types are in `arena/types.py`; read its docstrings.

```toml
name = "my-model"
description = "one line"
targets = ["meter.five_hour", "meter.seven_day"]
children = []          # other models in models/ that this one calls
deps = []              # extra PyPI packages, e.g. ["lightgbm>=4"]
weights = []           # Hugging Face repos to pre-fetch, e.g. ["org/repo@revision"]
[config]               # handed to the model as ctx.config
```

```python
class Model:
    def __init__(self, ctx): ...          # ctx.config, ctx.seed, ctx.rng, ctx.scratch, ctx.model(), ctx.backtest(), ctx.log()
    def fit(self, history): ...           # everything known at the cutoff (history.now)
    def update(self, events): ...         # optional: rows that became known since
    def forecast(self, request): ...      # -> Forecast: sample paths per requested target
```

- `history` is an as-of view: rows with `t_known <= now` only. `history.table(name)`
  returns polars, `history.sql(...)` runs DuckDB over the same tables.
- A `Forecast` maps each requested key to a `TargetForecast` of sample paths
  (`[n_paths, len(grid)]`). Ranges, the chance of hitting 100% and the time to
  100% are all read off the same paths. `TargetForecast.from_quantiles` helps
  models that think in quantiles. You may attach direct estimates in
  `extras` (`p_hit_limit`, `time_to_limit`); they are scored too.
- Every time is epoch milliseconds UTC.
- Each episode runs in a fresh worker process with no files, no network and no
  state from earlier episodes. The data reaches your model only through
  `fit` and `update`.

**Targets:** {{TARGETS}}

## The data

Visible tier: `$ARENA_HOME/snapshots/$ARENA_SNAPSHOT/train/` (snapshot
`{{SNAPSHOT}}`, rows known up to **{{T_TRAIN}}**), parquet partitioned by month of
`t_known`. You may read it directly to explore. Accounts are `A1`, `A2`, …;
ids are salted hashes; there is no text anywhere. The schema is
`arena/snapshot/schema.py`; in short:

{{SCHEMA}}

Every row has `t_event` (when it happened) and `t_known` (when Pacer could
first have known it). Scope tags say who would have the data: **E** every
user, **M** users with several accounts, **S** only this setup. A model that
should generalize must still work without any S table.

The data after {{T_TRAIN}} is hidden. You never see it, only scores on it.

## Two ways to score

| | `uv run arena test models/<name>` | `<your arena-eval> models/<name>` |
|---|---|---|
| data | the visible tier (above) | the hidden leaderboard tier |
| output | full diagnostics, per episode | rounded per-target scores only |
| cost | free; run it as often as you like | a fixed budget of calls for the whole generation (your brief; `<your arena-eval> --budget`) |
| episodes | your choice (`--episodes`, `--seed`, `--targets`) | fresh random episodes every call |

Use `arena test` to develop. Spend `arena-eval` calls on candidates you
believe in: each call draws new episodes, so a small gain on one call is
mostly noise. The final ranking uses a later period that no call ever touches.

**Your arena-eval** is the absolute path in `BRIEF.md` (also in `$ARENA_EVAL`).
Type that path itself, as a command on its own: the sandbox lets exactly that
command through, so `$ARENA_EVAL …`, `cd x && …` or `… | tee` run sandboxed
and fail. It takes exactly one argument, the path to a model folder inside your
own `models/`. Your model (and its children) is copied, its `deps` and
`weights` are installed in a Linux environment, and it is scored offline: each
model process (and each child) runs in its own container with no network and
no data files, read-only except `/tmp` (also `ctx.scratch`), 2 CPUs and 4 GB.
It sees data only through `fit(history)` and `update(events)`. Packages you
install locally with `uv pip install` are for your own experiments: the
scorer installs only what `model.toml` lists.

## Building on earlier work

- `models/` holds the example and every earlier model chosen for this
  generation, by name; `MODELS.md` lists them with their hashes, and
  `SCORES.md` (when present) their aggregate scores.
- **Copy, don't modify.** `arena/`, `kit/`, `synth/` and every model already in
  `models/` are read-only. To build on a model, copy its folder to a new name.
  To use one as is, call it: `children = ["name"]` in model.toml, then
  `ctx.model("name").forecast(request)`. `ctx.backtest(...)` gives a child's
  past forecasts made without seeing what followed: the safe way to train a combiner.
- The harness the scorer uses is its own copy; editing `arena/` here changes
  nothing but your local runs.

## Handing back

Don't run git: the sandbox cannot write `.git/`. When your run ends, the
launcher commits `models/`, `REPORT.md` and `UPSTREAM.md`; nothing else is
collected. Keep them current as you work, because the run can end without
warning when its turn or spend cap is reached.

- **`REPORT.md`**: what each model does, what you tried that did not work, your
  `arena test` and `arena-eval` results, and what you would try next.
- **`UPSTREAM.md`**: harness bugs, and helpers you want added to `kit/`. Write
  the helper in your model folder and describe it; the coordinator decides.
- New model folders only. Name them `<your name>-<what it is>`.

## Rules

- Read and write only inside this folder, plus the visible data above. Do not
  try to reach the hidden data, other agents' folders, Pacer's own files or
  anything else outside. The sandbox blocks it and logs the attempt.
- Do not probe the evaluator: no models that behave differently when scored,
  try to detect the tier, read files, open sockets, inspect the call stack or
  spend calls to learn about the hidden period. No hard-coded answers.
- Every submission is read by a reviewer before its scores count. **Probing,
  hard-coding or reaching outside the allowed paths disqualifies the agent's
  whole generation of work.**
- WebSearch and WebFetch are open for research. Shell commands can reach PyPI,
  GitHub and Hugging Face only.

## Practicalities

- No git (see "Handing back"). Keep `models/`, `REPORT.md` and `UPSTREAM.md` current.
- For quick comparisons use `uv run arena test models/<name> --episodes 8`.
  A command may run for up to an hour, so longer runs are fine.
- After `cp -r` of an existing model, run `chmod -R u+w` on the copy: copies keep read-only permissions.
- **A model is known by its folder name.** After copying a model, set `name` in its `model.toml` to the new folder's name. A copy that keeps the original's name is renamed when it is collected.
- Models that call other models are welcome, and nesting several layers deep is fine. Children are named by folder: earlier generations' models and the ports are all in `models/`.
- The pretrained time-series models (torch, Timestral and the other foundation
  models) and their weights are installed in your environment and work offline.
- Keep improving until your turn or spend cap is nearly used.
