# Forecast arena

A research harness for Pacer's usage forecasts: a point-in-time snapshot of
the usage history, a runner that hands each model only what was known at each
moment and scores whole forecast paths against what happened, a results
database with leaderboards, and the tooling for a fleet of agents that write
models. Nothing here ships in the app.

- **Start here:** [`RUNBOOK.md`](RUNBOOK.md), every step from a fresh clone
  (your own data, the tournaments, an agent generation, the prospective
  re-run).
- **What happened:** [`docs/history.md`](docs/history.md); open problems in
  [`docs/known-issues.md`](docs/known-issues.md); the literature behind it in
  [`docs/research-prior-art.md`](docs/research-prior-art.md).
- **The design** is in [`DESIGN.md`](DESIGN.md), the pinned interfaces in
  [`CONTRACTS.md`](CONTRACTS.md), the snapshot format in
  [`docs/snapshot-spec.md`](docs/snapshot-spec.md) and the agent sandbox in
  [`docs/fleet-verification.md`](docs/fleet-verification.md).
- **The models:** `models/` holds the ports and baselines, the self-test
  controls and the 89 models two generations of agents wrote (`g1-*`, `g2-*`);
  [`models/PROVENANCE.toml`](models/PROVENANCE.toml) says who wrote each, and
  [`fleet/generations/`](fleet/generations) what each agent did.

No usage data is in git. Every snapshot, score and report is generated on
your machine from your own Pacer history (or from synthetic data), and the
pseudonymization salt is created locally, per person.

Everything runs through `uv` from this folder:

```sh
cd research/arena
uv sync --extra fm       # `fm`: torch and the pretrained forecasters (kit/fm, models/fm-*, struct-*)
uv run pytest            # the whole suite; Docker and weights tests skip without them
```

Without `--extra fm` everything but the pretrained models works (`uv sync`);
their tests and runs skip or fail cleanly. Host workers find Hugging Face
weights in the standard cache (`$HF_HUB_CACHE`, `$HF_HOME/hub` or
`~/.cache/huggingface/hub`), offline: nothing is downloaded while scoring.
Fetch them once with `uv run --extra fm arena weights fetch` (every model's
pinned `weights`, or `--models a,b`).

## Where data and results live

Never in git. Everything goes under `ARENA_HOME`, by default
`~/.local/share/pacer-arena/`:

```
salt                                  pseudonymization salt (never copied anywhere)
snapshots/<id>/manifest.json          tier boundaries (T_train, T_leaderboard_end, T_end), counts, hashes
snapshots/<id>/train/                 rows known by T_train: the visible tier
snapshots/<id>/holdout/               rows known after T_train: the leaderboard and lockbox tiers
snapshots/<id>/labels/                label tables (cycles, what the app predicted and scored)
snapshots/<id>/validation/report.json the exporter's nine gates
results/arena.duckdb                  runs, episodes, models, scores, failures
results/forecasts/<run_id>/           forecast archive (quantiles or paths) per run
cache/children/                       child-model forecasts, keyed by hash, snapshot, view, time, request
envs/<key>/                           model environments built by `arena build` (fleet)
visible/<id>/                         the agents' train-only copy of a snapshot (fleet)
```

`--snapshot` picks a snapshot by id; without it, `$ARENA_SNAPSHOT`, else the
newest.

## Make a snapshot

From Pacer's data (reads copies of the store and the Claude Code transcripts;
writes nothing anywhere else):

```sh
uv run arena export --id working-YYYY-MM-DD            # tiers: last 3 weeks lockbox, 3 before leaderboard
uv run arena export --id frozen-1 --freeze --t-end 2026-11-01T00:00:00Z
```

Nine validation gates run first (store vs transcripts, prices, readings,
point in time through the harness's own views, determinism, a leak scan…);
if one fails there is no snapshot, and the report lands in
`ARENA_HOME/export-failures/`.

Synthetic data in the same format, with the generating truth under `truth/`:

```sh
uv run arena synth --out synth-default --seed 1 [--users 6] [--days 120]
```

## Write and test a model

A model is a folder `models/<name>/` with `model.toml` (name, targets,
children, deps, weights, config) and `model.py` (a `Model` class with `fit`,
optional `update`, and `forecast` returning sample paths). Start from
[`models/example-linear`](models/example-linear), and see `arena/types.py` for
`History`, `Request` and `Forecast`. The shared helpers are in `kit/`:
`kit.spend` (spend priced as of now, the spend-to-meter conversion, the live
meter, the current cycle), `kit.baselines`, `kit.engine` (the app's engine),
`kit.ml` (features, walk-forward training, combiners) and `kit.fm` (the
pretrained forecasters).

Meter request grids are not evenly spaced: a dense head (five-hour +30 s,
+1, +2, +3, +5 min, then every 5 min; seven-day and scoped +1, +5, +15,
+30 min, then every 30 min) ending at the reset. A meter can fall inside a
cycle with the same reset (an allowance re-based): truth keeps every reading
as read, never a running maximum.

```sh
uv run arena test models/example-linear --snapshot synth-default        # visible tier, full diagnostics
uv run arena test models/my-model --episodes 20 --seed 3 --targets meter.five_hour --subprocess
```

`arena test` runs on the visible tier with in-process workers (or real
worker processes with `--subprocess`) and prints every episode, score and
failure, and the model's own `ctx.log` lines.

## Run a tournament and read the boards

```sh
uv run arena run --models all --tier visible --episodes 6 --seed 1 --jobs 6 --progress \
    --snapshot working-YYYY-MM-DD                     # every model but the self-test controls (agents' too)
uv run arena run --models example-linear,my-model --tier leaderboard --episodes 20 --seed 1 \
    --snapshot working-YYYY-MM-DD
uv run arena board                                    # one set of boards per snapshot
uv run arena board --snapshot synth-default --target meter.seven_day --baseline example-linear
```

Every model in a run gets exactly the same episodes. The episodes depend on
the tier, snapshot, seed, `--episodes` and the targets (`--targets`, else
what the models declare), so two runs that share those score identical
episodes and `arena runs merge` folds one into the other. The work is (model,
episode) units: `--jobs N` runs N at a time, each in its own job process
(which loads the tier from disk once), and merges their rows back in
(episode, model) order, so a run's scores are identical for any N. The
summary prints each model's seconds per episode.

**Host or Docker workers.** By default each model worker is a host process
(`python -m arena.worker`, a clean environment, its scratch folder as HOME).
A host worker can read anything this user can, so host workers are for
trusted models only: the ports and baselines committed here. `arena run`
refuses a model from the agent fleet's folders without `--docker`, and an
agent's model in `models/` (by `PROVENANCE.toml`) on a hidden tier
(leaderboard, lockbox, prospective) unless `--docker` or
`--trust-agent-models`.
`--docker` stages every model tree under `/tmp`, builds the scoring image if
it is missing (`pacer-arena-eval:<hash of pyproject, uv.lock, arena/, kit/,
the Dockerfile>`), finds or builds each tree's env (`arena build`: its
`deps` and pinned `weights`, network on, no data), and starts every worker
of that model, children included, in its own container: no network,
read-only root, the staged models and env mounted read-only, no data
mounted (`--docker-cpus`, `--docker-memory`, default 2 and 4g). Pre-build
the envs once per image so a run does not stop to download:

```sh
uv run python -c "from fleet.image import build_image; from arena.registry import ARENA_ROOT; print(build_image(ARENA_ROOT))"
uv run arena build models/fm-timestral-28m-meter --image pacer-arena-eval:<tag>   # each model with deps/weights
uv run arena run --models fm-timestral-28m-meter,ml-gbm-quantile --tier visible --episodes 4 --docker
```

Any edit to `kit/` or `arena/` changes the image tag, hence every env key:
build again.

**A model is its folder and the code it runs.** Its hash
(`arena.registry.content_hash`) covers the folder, `kit/`, the harness code
that serves and runs it (everything under `arena/` but scoring, the command
line, the results database and the self-tests) and `uv.lock`. An edit to
`kit/` is therefore a new model: new rows in `models`, a cold child cache,
and `name@<hash>` pins that no longer match. Stale cache entries are never
read again; delete `ARENA_HOME/cache/children` to reclaim the space.

`arena board` shows one
leaderboard per target: CRPS (and skill against `--baseline`), point error,
error at reset, next-reading error, Brier score for hitting the limit, 80 %
coverage, PIT-histogram flatness (`pit_tv`, 0 = calibrated) and whether the
model is tied for best (Model Confidence Set). The full metric set, including
`pit_b0`…`pit_b9`, is in the `scores` table.

## Score on a hidden tier

```sh
uv run arena eval models/my-model --tier leaderboard --episodes 20 --seed 7 --json
```

prints rounded per-target means only. Each worker is a separate process
(`python -m arena.worker`); `--worker-cmd` or `$ARENA_WORKER_CMD` replaces how
it starts. The fleet's `arena-eval` uses that to run the runner on the host
and every worker in its own Docker container with no data mounted and no
network (`fleet/evalgate.py`).

## The agent fleet

`arena template gen<N>`, `arena fleet launch|status|collect|…` and
`arena build` live in `fleet/`; everything the fleet writes goes under
`$ARENA_FLEET_ROOT` (default `~/arena-fleet/`). See
`docs/fleet-verification.md` before launching anything, and `RUNBOOK.md` for
the whole cycle, ending with `arena provenance import gen<N>` (the models into
`models/`, their attribution into `PROVENANCE.toml`).
