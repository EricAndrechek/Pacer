# Contracts every builder works against

Pinned before the phase-1 build so five builders can work in parallel. If a
contract is wrong, say so in your MERGE NOTES. Don't quietly change it in your
own area: the other four are coding against it too.

## Code that is the contract

| file | what it pins |
|---|---|
| `arena/snapshot/schema.py` | every snapshot table, column and type; scope tags (E/M/S); data vs label tables |
| `arena/snapshot/__init__.py` | `arena_home()` and the snapshot directory layout |
| `arena/types.py` | the model interface: `Request`, `TargetRequest`, `Forecast`, `TargetForecast`, `History`, `Events`, `Context`, `Target` |
| `arena/protocol.py` | the runner ↔ worker wire format (no pickle) |
| `arena/results_schema.sql` | the results database |
| `models/example-linear/` | the reference model; it must keep working |

Times are epoch milliseconds UTC in Python and `timestamp[ms, UTC]` in parquet.

## Locations

`ARENA_HOME` (default `~/.local/share/pacer-arena/`) sits outside the repo and
every worktree:

```
salt                          32 bytes; never copied anywhere else
snapshots/<id>/manifest.json
snapshots/<id>/train/<table>/…parquet     t_known <= T_train
snapshots/<id>/holdout/<table>/…parquet   t_known >  T_train (evaluator only)
snapshots/<id>/labels/<table>.parquet     label tables (harness only)
snapshots/<id>/validation/report.json
results/arena.duckdb, results/forecasts/<run_id>/…parquet
cache/children/…              child forecasts by (child hash, snapshot, scope, cutoff, request)
```

Partition `turns`, `turn_revisions` and `meter_readings` by month of
`t_known` (plus `window=` for readings). Small tables are single files.
`manifest.json` holds the snapshot id, `created_at`, `frozen`, `T_train` and
the tier boundaries (`T_leaderboard_end`, `T_end`), the source fingerprints,
`salt_id`, per-table row counts and content hashes, the lag-model parameters
and a validation summary.

## Command line (`arena …`, in `arena/cli.py`; each builder owns its subcommand)

| command | owner | does |
|---|---|---|
| `arena export [--id ID] [--freeze] [--t-train ISO] [--tiers 3w,3w]` | exporter | builds a snapshot from copies of Pacer's store and the transcripts; runs every validation gate; no snapshot on failure |
| `arena synth --out ID --seed N [--users K]` | synth | writes a synthetic snapshot in the same layout, with a `truth/` folder holding the generating parameters |
| `arena test <model_dir> [--episodes N] [--seed S] [--targets …] [--snapshot ID]` | core | runs on the visible tier, in-process workers, full diagnostics to stdout |
| `arena eval <model_dir> --tier leaderboard\|lockbox --episodes N --seed S --json` | core (runner), fleet (Docker wrapper) | the hidden-tier scorer: prints rounded per-target scores only |
| `arena run --models a,b,… --tier T --episodes N --seed S [--longrun]` | core | tournament into the results database |
| `arena board [--target T] [--tier T] [--run ID]` | scoring | leaderboard views, paired comparisons |
| `arena template gen<N>` / `arena fleet launch …` | fleet | the agent fleet |

`arena/cli.py` is created by the core builder with an `argparse` subparser per
command. The other builders each add one module, `arena/cli_<area>.py`,
exposing `register(subparsers)`. The core builder's `cli.py` imports these when
they exist, so nobody edits another builder's file.

## Who owns which files

| builder | owns |
|---|---|
| exporter | `export/**`, `arena/cli_export.py`, `tests/export/**` |
| core | `arena/snapshot/views.py`, `arena/snapshot/cycles.py`, `arena/pricing.py`, `arena/episodes.py`, `arena/runner.py`, `arena/worker.py`, `arena/registry.py`, `arena/cache.py`, `arena/results.py`, `arena/cli.py`, `tests/core/**` |
| scoring | `arena/scoring/**`, `arena/cli_board.py`, `tests/scoring/**` |
| synth | `synth/**`, `arena/cli_synth.py`, `tests/synth/**` |
| fleet | `fleet/**`, `arena/cli_fleet.py`, `tests/fleet/**` |

Shared files (`pyproject.toml`, `uv.lock`, the contract files above): add a
dependency if you need one and list it in MERGE NOTES. The merge agent
reconciles the lockfile.

## Seams between builders

- **Scoring ↔ core.** Scoring exposes `arena.scoring.score_checkpoint(request,
  forecast, truth) -> list[ScoreRow]`, with `Truth`, `TargetTruth` and
  `ScoreRow` as pinned in `arena/types.py`. The runner builds the `Truth`:
  - meter readings after `now`, up to the horizon, within the same cycle;
  - realised hourly spend, tokens and shares;
  - the actual next start for `cycle.next_start`.
- **Pricing.** `arena/pricing.py` (core) prices a turns frame either with the
  rates known at a given time (for features and the kit) or with the final
  rates (for truth). Cost is null, never 0, when no rate is known.

  Scoring also exposes `aggregate(...)` and the comparisons over the results
  tables. The runner calls `score_checkpoint`, and nothing else in scoring.
- **Core ↔ fleet.** The fleet's `arena-eval` runs `arena eval` on the host
  (outside the agent's sandbox, from the generation's pinned harness) and
  starts every worker, children included, through core's worker command
  (`ARENA_WORKER_CMD`, with `ARENA_WORKER_KILL_CMD`): one Docker container per
  worker, no network, no data mounted. Core keeps `arena eval` free of
  anything host-specific (paths come from arguments and `ARENA_HOME`), and
  keeps workers runnable as `python -m arena.worker` with the protocol on
  stdin/stdout, using `$ARENA_WORKER_SCRATCH` as scratch when the launcher
  sets it. (Amended at the phase-1 merge: the first design ran all of
  `arena eval` in one container with the snapshot mounted, which let a model
  open the holdout.)
- **Exporter ↔ synth ↔ core.** All three agree only through `schema.py` and
  the layout above. Core's tests use synth's output, or tiny fixtures written to
  the schema.

## Amended at the phase-2 merge

- **A model's identity covers the code it runs** (`arena/registry.py`).
  `content_hash` = sha256 over the folder's hash (`folder_hash`, the old
  identity) and `code_hash`: `kit/**`, `arena/**` except scoring, the CLI,
  the results database, the self-tests and the registry, and `uv.lock`. It is
  `models.model_hash`, the child-cache key and what `name@<hash>` pins.
  `fleet/evalgate.py` restates both over the generation's harness, so the gate,
  the collector and the results database still name a model the same way.
- **Meter grids have a dense head** (`arena/episodes.py`, `GRID_HEAD`):
  five-hour +30 s, +1, +2, +3, +5 min, then every 5 min; seven-day and
  scoped +1, +5, +15, +30 min, then every 30 min; the last point is the reset.
  A model must not assume an even step.
- **Meters can fall inside a cycle** under the same reset (an allowance
  re-based). Truth keeps every reading as read; nothing in the harness or the
  kit keeps a running maximum of a reading. (A model may still choose
  non-decreasing forecast paths.)
- **`arena/types.py`:** `Context.children` (the declared child names);
  `History.tz_offset_min` and `Events.tz_offset_min`, the device's latest
  known UTC offset in minutes (any account's turns, even in a scope-only
  view), None while none is known; `TargetRequest.family` applies to
  `spend.hourly` as well as `tokens.hourly` (a parent asking a child for one
  family's spend).
- **`arena/protocol.py`:** `fit` and `update` carry `tz_offset_min`.
- **Runs:** `RunConfig.jobs` (`arena run --jobs N`) and
  `RunConfig.worker_cmds` (per top-level model hash, for its whole tree;
  `arena run --docker` fills it). Results are identical for any number of
  jobs.

## Amended for publication

- **Attribution is tracked** (`arena/provenance.py`): `models/PROVENANCE.toml`
  (`kind` port | example | agent | selftest; for agents `generation`, `agent`,
  `claude_model`, `effort`, `niche`, `copied_from` by name) and
  `fleet/generations/gen<N>/agents.toml`. `ResultsDB.register_model` fills
  `models`' attribution columns from it when a model is listed;
  `arena/provenance.py` is not model code (not in `code_hash`).
- **The prospective tier takes a start**: `SnapshotData.load(..., tier="prospective",
  after=<ms>)`, from `--after <ISO time | snapshot id>` (a snapshot id means its
  manifest's `T_end`). Cutoffs fall in `(after, T_end]`.
- **New commands**, each its own `arena/cli_<x>.py`: `arena provenance`,
  `arena weights fetch`, `arena runs merge`.

## Rules for every builder

- **Never** launch Pacer or any app, run `open`, run `make` install, render or
  screenshot targets, or write to Pacer's store, `~/.claude`, `~/Library` or
  `~/.config`. Read Pacer's store only through a copy (`open_copy` in
  `research/harness/pacer_replay.py`, or copy the db and its `-wal`/`-shm`
  files first; the exporter clones them itself).
- **Python through `uv` only.** Docker runs always use `--rm`.
- **Real usage data never goes in git:** no parquet, no DuckDB, no numbers
  copied out of it into code. Account labels are `A1`…; never a real id,
  username or path.
- **Tests run with `uv run pytest tests/<area>`** and must pass before you hand back.
- **Finish with a MERGE NOTES section:** files touched, dependencies added,
  contract problems found, anything another builder must know.
