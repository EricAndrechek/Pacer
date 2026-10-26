# Forecast arena — design

Status: phase 1 (exporter, synthetic generator, harness core, scoring,
fleet tooling) and phase 2 (self-tests, the app's engine and live meter,
spend models, naive baselines, learned models and combiners, the pretrained
forecasters) are built; two agent generations have run and their 89 models
are in `models/`. This is the design as signed off, amended where the build
changed it ([`CONTRACTS.md`](CONTRACTS.md) lists the amendments). How to use
it is in [`README.md`](README.md) and, step by step from a fresh clone,
[`RUNBOOK.md`](RUNBOOK.md); what happened is in
[`docs/history.md`](docs/history.md).

## In plain words

Four pieces, built in this order:

1. **A frozen copy of your usage history** (the *snapshot*), exported from
   Pacer and the raw transcripts, normalized to one format. Every row carries
   two times: when it happened, and when Pacer could have known it.
2. **The harness.** It picks test cases (an account or a group of accounts, a
   moment in time, how much history to show), hands each model only what was
   known at that moment, asks for forecasts of everything ahead, then feeds the
   model what happened next, piece by piece. It asks again after each piece and
   scores every answer against what really happened.
3. **Models**, each in its own folder behind one small interface. They share a
   kit of helpers, and a model can call other models to any depth.
4. **The agent fleet.** Claude Code agents, each in a sealed working copy, write
   new models. They can explore the older part of the data and score their models
   on the hidden recent part, and they see only scores from it. Results land in
   one queryable database with who wrote each model, and with which Claude model and effort.

Nothing here goes into the app. Run time, memory and how hard a model would be
to port are not judged; only accuracy is.

## Goals and non-goals

- **Goal:** the most accurate forecasts we can find, of whole paths rather
  than end values, that adapt as new data arrives and would work on anyone's
  data.
- **Goal:** a harness trustworthy enough that a model can't score well by
  seeing the future, by accident or on purpose.
- **Non-goal (for now):** Swift, speed, retraining cost, porting difficulty.

## Folder layout

Everything lives in `research/arena/`, a self-contained `uv` project. Data,
results and caches are gitignored, and a commit check refuses parquet, DuckDB,
large files and anything that looks like an account id.

```
research/arena/
  DESIGN.md, README.md
  pyproject.toml, uv.lock
  arena/            the harness package (read-only to agents)
    snapshot/       schema, readers, as-of views
    episodes.py     the test-case sampler
    runner.py       fit / update / forecast loop, worker processes, timeouts
    forecast.py     the Forecast type (sample paths) and adapters
    registry.py     model discovery, content hashes, child calls, cache
    scoring/        metrics, aggregation, model comparisons
    results.py      the results database
    cli.py          arena test | eval | run | board | template
  kit/              shared helpers models may use, and may ask to extend
  models/           one folder per model (immutable once committed)
    example-linear/ the trivial y = mx + b example
    PROVENANCE.toml who wrote each model (port, example, selftest, agent)
  export/           Mac-side exporter: Pacer store + transcripts -> snapshot
  synth/            synthetic data generator (same schema)
  fleet/            agent launcher, template builder, settings, reviewer
    generations/    each generation's plan, agents and summaries
  tests/            harness self-tests
  data/       (gitignored) working and frozen snapshots
  results/    (gitignored) results database, forecast archive, caches
```

Reused from `research/`: the engine ports in `harness/pacer_replay.py`
(phase 2 baselines), catalog price history in `price-history/`, and from an
earlier, unpublished lab the spend models and the Timestral runner. That
lab's case-based scorer is retired: it leaks (an activity
profile built from all history, and today's prices) and it scores only the end
value.

## The snapshot

The full spec is in [`docs/snapshot-spec.md`](docs/snapshot-spec.md). In short:

- **Tens of megabytes of parquet, in 13 tables.**
  - **Usage:** `turns` (one row per API call), `turn_revisions`.
  - **Meters:** `meter_readings` (every window kind, with idle periods kept as
    explicit rows); `cycles` (labels and helpers only).
  - **Prices:** `prices`, as each catalog knew them over time.
  - **Accounts:** `accounts`, `account_events`.
  - **Activity:** `sessions`, `prompts` (timestamps only), `subagent_spawns`,
    `session_cost_state`.
  - **Other:** `limit_hits`, `app_alive`, `regimes`.
  - **What the app actually showed and scored:** `predictions_of_record` and
    `eval_of_record`, kept past the app's 180-day pruning, as baselines and labels
    only.
- **Each table is tagged by who has the data:** every Pacer user, users with
  several accounts, or this setup only. Every feature from a "this setup only"
  table can be dropped, and scores are reported with and without them.
- **Two clocks on every row.** `t_event` is when it happened. `t_known` is the
  earliest moment today's Pacer would have held the row in its final form:
  - **Exact from Sep 24**, from SwiftData's change history.
  - **Before that**, a lag drawn from the measured distribution (p50 16 s, p99
    17 min).
  - **Prices**, by catalog commit date, never by their backdated effective date.

  Rewritten rows keep their final value. The harness has two modes:
  `current_code` (default, the view today's Pacer would have had) and
  `as_recorded` (strict, to reproduce exactly what the app showed at the time).
- **Output tokens carry a reliability flag.** They're unreliable in three
  periods:
  - before Jul 3 (the old first-copy rule);
  - a probable Claude Code defect Aug 25–Sep 15;
  - a confirmed one Sep 23–Oct 22 (#353), when subagent transcripts lost
    their finished copies and about half the output.

  An imputed value from Claude Code's own per-session counters sits alongside
  the raw one; the raw value is never overwritten. Cost is a view that prices each
  row with rates known by the cutoff, and is null (never 0) when no rate was
  known.
- **Clean spans by target.**
  - **5-hour and 7-day meter paths:** from May 7 for the first account, from
    first sighting for the others.
  - **Fable weekly:** from Jul 11.
  - **Output and spend:** Jul 3–Aug 24, Sep 16–22 and from Oct 22, plus the
    imputed values elsewhere.
- **Pseudonymized.**
  - Accounts become `A1`–`A4`.
  - Sessions, projects and ids become salted 64-bit hashes; the salt is kept
    outside the repo and the snapshot.
  - There is never any prompt text, tool input, path, branch, title or account UUID.
- **Nine validation gates; failing any one means no snapshot.**
  - The store must match the raw transcripts exactly (on the first export,
    every row did).
  - Claude Code's counters must match the transcripts, which catches the next
    upstream defect of this kind.
  - Readings and cycles must pass sanity checks.
  - Price coverage must be complete.
  - A point-in-time self-test must pass.
  - Re-exporting must be byte-for-byte deterministic.
  - A leak scan must find no paths, emails or UUIDs.
- **Layout.** Partitioned by month of `t_known`, so a held-back period is a set
  of whole files. `train/` is what agents may see. `holdout/` and `labels/` are
  read only by the evaluator.
- **Working and frozen snapshots.** One exporter run builds the working
  snapshot for phases 1–2. The same script builds the frozen one at the start of
  the agent rounds.

## Targets

Per account unless noted. Forecasts cover every point from the cutoff to the
horizon, not only the end.

| target | path forecast | horizon |
|---|---|---|
| `meter.five_hour` | meter % over time | to the current cycle's reset (active cycles only) |
| `meter.seven_day` | meter % over time | to reset |
| `meter.scoped.<cap>` | e.g. the Fable weekly cap | to reset |
| `meter.nowcast` | the meter *right now*, between readings (the live meter) | to the next reading |
| `cycle.next_start` | when an idle 5-hour window starts again | 24 h |
| `spend.hourly` | API-equivalent $ per hour; any group of accounts | 24 h and 7 d |
| `tokens.hourly` | tokens per hour by model family; any group | 24 h and 7 d |
| `split.accounts` | share of the next day's spend per account | 24 h (second track: shaped by the rotation controller) |

The harness derives these from every meter path: the value at reset, the chance
of reaching 100% before reset, and the time to 100% (censored at reset).

Meters are per account and don't add up across accounts. Groups of accounts
only make sense for spend and tokens.

## The model contract

A model is a folder `models/<name>/` with `model.py` and `model.toml`:

```toml
name = "spend-decay"
targets = ["meter.five_hour", "meter.seven_day"]
children = ["port-engine-diurnal"]   # models it may call; pinned by hash at load
deps = ["lightgbm>=4"]               # optional extra packages
```

```python
class Model:                                   # duck-typed; kit.BaseModel is optional
    def __init__(self, ctx): ...               # config, seed, scratch dir, child access
    def fit(self, history): ...                # everything known at the cutoff
    def update(self, events): ...              # optional: rows that became known since
    def forecast(self, request) -> Forecast: ...
```

- **`history`** is a read-only, as-of view of every snapshot table (polars or
  DuckDB relations). `history.now` is the cutoff. Rows known later than the
  cutoff do not exist in it, because the model's process never receives them.
- **`update`** is optional. A model without it is re-fitted on the extended
  history at each checkpoint.
- **`request`** names the targets and the account scope. Each target has a time
  grid (5-hour every 5 min and 7-day every 30 min after a dense head of
  seconds to minutes, spend hourly) and a number of paths.
- **A `Forecast`** is a set of sample paths per target (default 200). The point
  shown to people is the middle path. Ranges, the chance of hitting the limit and
  the time to the limit all come from the same paths, so they always agree.
  Models that think in quantiles use `Forecast.from_quantiles(…, dependence=…)`.
  A model may also attach its own direct estimates (say, the chance of hitting
  the limit), and those get scored too.
- **Attribution never comes from the model.** The fleet launcher records who
  wrote it (agent session, Claude model, version, effort, generation, the models
  it copied from) in the results database.

## Episodes and the runner

An **episode** is one test case:

- the account scope;
- the **view**: only the scope's accounts, like a user who has just those, or
  every account;
- the history start;
- the cutoff;
- the horizon;
- the checkpoints.

- **Sampler.** Seeded. It draws a scope, then a cutoff uniformly within the
  tier's period. The history start is random, from "everything available" down
  to "the last 3 days", which tests cold starts. Within a run, every model gets
  exactly the same episodes. A new run draws new episodes. The seed is stored,
  so any run can be replayed.
- **Streaming.** After `fit` at the cutoff, the runner replays later rows in
  the order Pacer would have learned them. It calls `update` with each batch and
  asks for a new forecast at each checkpoint: every meter reading for the scope,
  plus hourly. Each forecast is scored on readings that arrive after it.
- **Isolation by construction.**
  - The runner, which is trusted, holds the episode's data.
  - Each model runs in its own worker process, which receives data only as
    in-memory batches over a pipe.
  - Workers get no data files, no network and no shared state. Each episode
    gets a fresh worker: a model carrying state from one episode into an
    overlapping one would be seeing the future.
  - On the hidden tiers, each worker runs in its own Docker container with
    CPU and memory caps and no data mounted; the runner stays on the host
    and starts them through a configurable worker command.
  - Every call has a generous timeout. A timeout counts as a miss and is
    reported, so one stuck model can't stall a tournament.
- **Long runs.** The same loop over weeks measures adaptation: rolling scores,
  regret against the best model in hindsight, and recovery after real changes
  (the Fable cap appearing, rotation starting, price changes, a new account).
- **Weights and packages.** `arena build <model>` installs a model's packages
  and fetches pretrained weights with network on. Scoring then runs offline.

## Models calling models

- A model asks for children by name through `ctx.model("name")`. The **runner**
  runs each child in its own worker with exactly the parent's as-of view, so a
  child can never see more than its parent.
- Child forecasts are cached by (child hash, snapshot, scope, cutoff, request)
  across runs. A popular base model is computed once.
- `ctx.backtest(child, every=…)` returns the child's forecasts over the
  parent's own past, each made without seeing what followed. That is the safe
  way to train a combiner, and the classic stacking leak is impossible.
- Loops are caught when models load. Depth is capped (default 8). A model's
  time budget includes its children.

## Scoring

Truth is the real readings at their real times, never interpolated, and stops
at reset. The forecast path is read at each reading's time.

- **Whole path, probabilistic.** For each target:
  - **CRPS at each lead time:** one number for how close and how honest the
    spread of paths is.
  - **Energy and variogram scores:** catch paths whose individual values look
    fine but whose shape is wrong.
- **Point.** The middle path's absolute error at each reading, and at reset
  (the number used so far).
- **Events.**
  - **Brier score** for "hits 100% before reset".
  - **Censored CRPS** for the time to 100%.
- **Calibration.** Coverage of the 50/80/95% ranges, and a PIT histogram.
- **Skill.** Every score is also shown relative to the port of the app's
  shipping model and to a naive baseline.

Scores live in a library (`scoringrules`), not hand-rolled code.

- **Comparisons.** Always paired on identical episodes.
  - **Intervals:** a bootstrap that resamples whole weeks, because episodes
    within a week are correlated.
  - **Pairs:** Diebold–Mariano tests.
  - **Ties:** a Model Confidence Set, so "best" means "statistically tied for
    best" and the luckiest of 100 models isn't crowned.
- **Leaderboards.** One per target, because the questions differ. The primary
  column is path CRPS skill; the point error, event and calibration scores sit
  beside it. An "overall" view (rank averaged across targets) is a convenience,
  never the selection rule.

## Tiers: what agents see

The frozen snapshot is split by time:

| tier | period | who sees what |
|---|---|---|
| visible | oldest data → T1 | Agents get the data (pseudonymized) and run the harness on it themselves, with full diagnostics. |
| leaderboard | T1 → T2 | `arena eval` scores a model on fresh random episodes per call and returns rounded scores per target. Each agent gets a budget of calls per generation. |
| lockbox | T2 → freeze | Scored only by the coordinator when a generation ends. Picks winners and shows how far the leaderboard flattered them. |
| prospective (optional) | after the freeze | Frozen models re-scored on data that did not exist when they were written. |

Plus a **synthetic** board: generated users with different habits, used for
stress tests and never for choosing winners.

T1 and T2 come from the data: each hidden tier needs enough 7-day cycles to
mean something. With four accounts, three weeks give about 12 weekly cycles,
so 7-day results will stay noisy whatever we do. A later freeze helps.

## Synthetic data

`synth/` writes snapshots in the same schema:

- **Users:** sessions arrive as a point process with daily and weekly rhythms.
- **Usage:** turns carry a model mix and token sizes. The meter rises per plan
  with integer rounding, polls come on a cadence with sleep gaps, and accounts
  switch by policy.
- **Injected changes:** a price change, a new model, a limit change, a new account.

Its parameters come from aggregate statistics of the real data, never from raw
rows. Uses:
- harness tests with a known right answer;
- fast local debugging for agents;
- the stress board.

## Results database

`results/arena.duckdb`:

| table | holds |
|---|---|
| `runs` | seed, snapshot id, tier, harness version |
| `episodes` | each test case |
| `models` | content hash, name, author agent session, Claude model + version + effort, generation, parents |
| `scores` | run × episode × model × checkpoint × target × metric |
| `failures` | timeouts and errors |

Forecast paths themselves go to a parquet archive for drill-downs. Leaderboards
are SQL views over these tables.

## Harness self-tests (before any real model)

1. **Oracle.** A privileged test model handed the true future must score
   perfectly. This tests the scoring and the alignment of times.
2. **Leak probes.** Models that try every way to see the future must gain
   nothing over a constant forecast:
   - reading files;
   - inspecting the stack or globals;
   - reading the environment;
   - opening the network;
   - poking the cache;
   - keeping state between episodes.
3. **Known answers.** Constant, last-value and straight-line models on small
   synthetic data must reproduce hand-computed scores.
4. **Determinism.** The same seed and models give identical results.
5. **Replay parity.** The port of the app's shipping engine, run through the
   harness, must reproduce what the app actually recorded at the time (every
   recorded prediction), within tolerance. This is the strongest proof that the
   as-of view matches what the app knew.
6. **Synthetic recovery.** On data generated from a known model, that model
   scores best.

## The agent fleet

Verified on the owner's Mac with Haiku runs and dummy data; the full report is in
`docs/fleet-verification.md`.

**Shape**
- **One process per agent.** Each agent is a separate headless `claude -p`
  process launched from the coordinating session, 4–5 at a time, with
  `taskpolicy -c utility`. That low priority is inherited by everything the
  agent runs, so the owner's work and Pacer stay responsive. Their usage lands in
  Pacer under whichever account is signed in.
- **Model and version pinning works.** All seven ids tested were accepted:
  Haiku 4.5, Sonnet 4.6, Opus 4.6, Opus 5, Sonnet 5.5, Opus 5.5 and Fable 5.1.
  The alias `haiku` means 5.5, so always pass full ids.
  - `--effort` works, but it shows only in the transcript; the launcher records it.
  - Opus and Sonnet 4.6 run "extra high" as "high".
  - Claude Code attaches Opus as an advisor even to Haiku agents.
    `CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1` turns that off, so attribution stays pure.
- **A clean start.**
  - The environment is stripped (`env -i` plus the basics), so this
    session's job folder and secrets don't leak in.
  - `--restricted` and `--strict-mcp-config` drop the owner's settings, hooks,
    MCP servers and skills.
  - Auto memory is off.
  - The brief comes from `--append-system-prompt-file`.
  - The tools are Bash, Read, Write, Edit, WebFetch and WebSearch only.
  - `--max-turns` and `--max-budget-usd` stop runaways.

**Where agents live.** Under a fleet root outside the Pacer repo and outside
`~/.claude`: `$ARENA_FLEET_ROOT`, by default `~/arena-fleet/`:
- **Agents.** Each agent gets a **fresh clone of the generation's template
  repo**, not a worktree of Pacer. A worktree would let it browse every Pacer
  branch through git. The coordinator fetches its commits back afterwards.
- **`bin/arena-eval`.** The one command allowed to reach hidden data.
- **`hidden/`.** The holdout and labels.
- **`settings/`.**

**Isolation, from the verification**
- **The macOS sandbox blocks shell reads** of the hidden paths: `cat`, Python
  and chained commands alike. `dangerouslyDisableSandbox` is ignored.
- **Docker and the Bash network are blocked by default.**
- **The sandbox does not cover the Read tool**, so every hidden path also gets
  a `Read(//…)` deny rule.
- **Blocked paths:**
  - `hidden/`;
  - Pacer's store;
  - `~/.claude/projects` (every transcript on the Mac);
  - the session-wakes cache;
  - the Pacer repo, which holds the snapshot on disk;
  - other agents' folders.

  In short: everything the hidden targets could be rebuilt from, and no
  copying within a generation.
- **The escape hatch.** `arena-eval` is exempt from the sandbox by its exact
  absolute path. Chained commands, `$()`, redirects and function shadowing all
  stay sandboxed.
  - **Where it runs:** the runner runs on the host, inside `arena-eval`, from
    the generation's pinned harness, and is the only process that reads the
    snapshot. Every model worker, children included, runs in its own Docker
    container (`ARENA_WORKER_CMD`): no network, read-only root,
    `--cpus 2 --memory 4g`, thread counts set to 2 (containers see all 14
    cores), the model and its env mounted read-only, and **no data mounted**.
    Rows arrive only as the runner's as-of batches over stdin, so a model
    cannot read the future even by opening files: there is nothing to open.
    The Docker endpoint is pinned at install, never taken from the agent's
    environment.
  - **What comes back:** rounded scores only.
  - **Cost:** a container per worker adds about 1-1.5 s per episode (measured
    3.3-3.8 s against 2.1-2.2 s with host workers).
- **Network.**
  - **WebSearch and WebFetch are open** for research.
  - **Bash can reach** package and model hosts (PyPI, GitHub, Hugging Face)
    for installs and pretrained weights.
  - **Agents run** in their own folder with their own `uv` cache.

  Still to confirm with one run from the real fleet root: writes in the agent's
  own folder and a `uv pip install`.

**Workspace and rules**
- **The template.** `arena template gen<N>` builds the template repo. It holds:
  - the harness (pinned; the evaluator scores with its own copy, so edits are
    pointless);
  - the kit;
  - every earlier model, by hash, with its scores;
  - the visible data;
  - the example model;
  - the synthetic generator;
  - an `AGENTS.md` that explains the schema, the rules and how to hand back.
- **Model spread.** The matrix spans Haiku to Fable, versions 4.6 to 5.5, and
  low to extra-high effort. It is assigned at random across niches (structural,
  statistical, pretrained, machine learning, ensembles), so the effect of the
  Claude model isn't confounded with the niche.
- **Hand-back.**
  - Agents commit their models with a `REPORT.md`.
  - Harness bugs and requests for new kit helpers go in `UPSTREAM.md`.
  - New models only; earlier models are never modified, just copied or called.
- **Review.** A reviewer model reads every submission for hard-coded answers,
  probing and evaluator tricks before its scores count. Agents' transcripts are
  scanned for any attempt to reach blocked paths.

## Phases

1. **Now: design, then sign-off.** After sign-off, the build:
   - **First, I pin the contracts myself** so builders can work in parallel
     without drifting:
     - the snapshot schema (`arena/snapshot/schema.py`);
     - the `History`, `Request` and `Forecast` types;
     - the worker protocol;
     - the results tables.
   - **Then one builder per workstream,** each in its own `wt` worktree with a
     non-overlapping file scope:

     | workstream | model | why that model |
     |---|---|---|
     | Exporter, validation gates, working snapshot (reads copies of the store) | Opus | data correctness; judgement on eras and the two clocks |
     | Harness core: as-of views, sampler, runner and workers, children and cache, CLI | Opus | the part everything else trusts |
     | Scoring: metric wrappers, aggregation, week-block bootstrap, Diebold–Mariano, Model Confidence Set | Sonnet | precise spec, library-backed |
     | Synthetic generator | Opus | modelling judgement |
     | Fleet tooling: template builder, launcher, `arena-eval`, Docker evaluator, reviewer | Opus | security-sensitive |

     Builders never launch the app, never run installs or renders, and touch
     only copies of the store. Once these merge, the self-tests and example model
     follow; then a merge agent folds the branches together and runs the
     end-to-end check.
2. **Ports of what exists, to test the harness.** These include:
   - the app's engine methods, the shipping rule, the live meter and the
     spend-to-meter conversion;
   - the lab's spend models;
   - Timestral at all four sizes, Chronos-2, TimesFM 2.5;
   - naive baselines.

   Loop phases 1 and 2 until the self-tests and replay parity pass and the
   leaderboards hold steady across seeds.
3. **Freeze; generation 1** (about 10 agents, 4–5 at a time); then a tournament.
4. **Generation 2 onward** sees every earlier model and its scores. Repeat
   until satisfied. Still no Swift.

## Decisions in this design (veto any)

1. **Agents see the older data** (pseudonymized `train/`), Kaggle-style. Only
   the leaderboard and lockbox periods are hidden.
2. **Agents' internet.** Web search and fetch are fully open. Shell commands
   reach package and model hosts (PyPI, GitHub, Hugging Face) but not arbitrary
   sites, so nothing an agent runs can post data elsewhere. Scoring is offline.
3. **Tiers.** The lockbox is the last 3 weeks before the freeze and the
   leaderboard the 3 weeks before that. Everything earlier is visible. The freeze
   happens when phase 2 ends, so the later it is, the more weekly cycles the
   hidden tiers hold.
4. **Generations.** About 10 agents per generation, 4–5 running at a time,
   gated on usage before each wave. Each has a turn and budget cap, and runs
   at low priority so this Mac stays responsive.
5. **One leaderboard per target**, scored on whole paths, with point error,
   limit calls and calibration alongside. Winners are picked on the lockbox.
