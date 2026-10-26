# Runbook: the forecast arena from a fresh clone

Every step, in order, with the exact commands used for the first two agent
generations (24–26 October 2026). Nothing here needs anything that is not in
this folder, except your own data and the tools in "Prerequisites". All data,
results and caches are written under `ARENA_HOME` and the fleet root, never
into git.

Placeholders: `<frozen>` is your frozen snapshot's id (ours was
`frozen-2026-10-24`), `<new>` a later one, `<run>` a run id that `arena run`
prints.

## 0. Prerequisites

| needed for | what |
|---|---|
| everything | [uv](https://docs.astral.sh/uv/) (Python 3.12+; it fetches one if needed) |
| the pretrained models on host workers | the `fm` extra (torch etc., about 1 GB) and the pretrained weights (a few GB, step 1) |
| Docker workers (`--docker`), hidden-tier runs of agent models, `arena build`, the eval gate | Docker Desktop or OrbStack, with `/tmp` shared into containers |
| a snapshot of real data | [Pacer](https://github.com/EricAndrechek/Pacer) on macOS, running long enough to hold weeks of history (its store and Claude Code's transcripts are the source) |
| synthetic data only | nothing more |
| agent generations | macOS (the agent sandbox is verified on macOS only), the Claude Code CLI (`claude`) signed in, and Docker |
| optional | Pacer's pacing CLI, to gate each wave of agents on your usage windows (`ARENA_PACER`, below) |

## 1. Setup

```sh
git clone https://github.com/EricAndrechek/Pacer && cd Pacer/research/arena
uv sync --extra fm                    # or `uv sync` without the pretrained models
uv run pytest                         # whole suite; Docker-, weights- and real-data tests skip
uv run --extra fm arena weights fetch # every pinned Hugging Face snapshot into the HF cache (once)
```

`arena weights fetch --models a,b` fetches only those models' (and their
children's) weights; `--dry-run` lists what is cached and what is missing.
Scoring itself never downloads: every pretrained model runs offline.

Environment variables (all optional):

| variable | default | what |
|---|---|---|
| `ARENA_HOME` | `~/.local/share/pacer-arena` | snapshots, the salt, results, caches, envs, reports |
| `ARENA_FLEET_ROOT` | `~/arena-fleet` | everything the agent fleet writes (outside the repo and `~/.claude`) |
| `ARENA_SNAPSHOT` | the newest snapshot | which snapshot a command uses without `--snapshot` |
| `ARENA_PACER` | `~/.claude/skills/pacer/pacer` | the pacing CLI the launcher asks before each wave; absent means no gating |
| `HF_HOME`, `HF_HUB_CACHE` | `~/.cache/huggingface` | where the weights are fetched to and read from |

## 2. Data

Synthetic (no Pacer needed; the generating truth is kept under `truth/`):

```sh
uv run arena synth --out synth-default --seed 1
```

Your own history (reads clones of Pacer's store and the transcripts, never the
live files; writes only under `ARENA_HOME`):

```sh
uv run arena export --id <frozen> --freeze            # tiers: last 3 weeks lockbox, 3 before leaderboard, rest visible
```

- The first export creates `ARENA_HOME/salt` (32 random bytes). It
  pseudonymizes sessions, projects and ids; accounts become A1, A2, … Keep the
  salt: later exports with the same salt keep the same pseudonyms, which the
  prospective re-run needs. Never share or commit it.
- Nine validation gates run first; if one fails there is no snapshot and the
  report is in `ARENA_HOME/export-failures/`.
- `--freeze` marks the snapshot immutable. Ours used the defaults:
  `T_end` = the latest known row, tiers `3w,3w`.

## 3. Self-tests

```sh
uv run arena selftest --snapshot synth-default              # oracle, leak probes, known answers, determinism, recovery, calibration
uv run arena selftest --snapshot <frozen> --docker          # also the leak probe in a real Docker worker
```

On a real snapshot the two checks that need the generating truth are skipped.

## 4. Tournaments

**Model sets.** The ports and baselines are every model whose
`models/PROVENANCE.toml` kind is `port` or `example`:

```sh
PORTS=$(uv run python -c "from arena import provenance as p; print(','.join(n for n, r in sorted(p.load().items()) if r['kind'] in ('port', 'example')))")
G1=$(uv run python -c "from arena import provenance as p; print(','.join(m for a in p.agents(1) for m in a['models']))")
G2=$(uv run python -c "from arena import provenance as p; print(','.join(m for a in p.agents(2) for m in a['models']))")
TARGETS=meter.five_hour,meter.seven_day,meter.scoped,cycle.next_start,spend.hourly,tokens.hourly,split.accounts
```

**Same episodes for everyone.** The episodes depend on the tier, snapshot,
seed, `--episodes` and the targets. Pass `--targets $TARGETS` to every run
that is meant to be compared, so two runs with different model sets still
draw identical episodes; `arena runs merge` checks that before folding one
into the other.

**Host or Docker.** Ports run on host workers (fast). Agents' models run on a
hidden tier only with `--docker` (each worker its own container, no data
mounted); the first run builds the scoring image and each model's env.
`--jobs N` changes speed, never results.

What we ran (`<frozen>` = our snapshot; same seeds and counts reproduce the
same episodes on the same snapshot):

1. **Phase-2 board** (what generation 1 saw in its template): every port on
   the leaderboard tier.

   ```sh
   uv run --extra fm arena run --models $PORTS --tier leaderboard --episodes 24 --seed 1 --snapshot <frozen> --jobs 6 --progress
   uv run --extra fm arena run --models $PORTS --tier leaderboard --episodes 120 --seed 7 --snapshot <frozen> --jobs 6 --progress
   ```

2. **Generation-1 board** (what generation 2 saw, beside the phase-2 board):
   every generation-1 model, same tier, seed and count as the 24-episode
   board.

   ```sh
   uv run --extra fm arena run --models $G1 --tier leaderboard --episodes 24 --seed 1 --snapshot <frozen> --docker --jobs 4 --progress
   ```

3. **The lockbox** (scored once, after both generations): 48 episodes, seed
   11, in three runs on identical episodes, merged into the first.

   ```sh
   A=port-engine-rule,port-live-meter,naive-flat,naive-split,naive-diurnal-spend,fm-timestral-123m-meter,fm-timestral-5m-meter,fm-chronos2-meter,fm-timesfm25-meter,struct-timestral-123m,spend-decay-1d,spend-decay-6h,spend-decay-30m,ml-gbm-quantile,fm-timestral-123m-spend
   B=g1-01-sonnet-calibrate123,g1-01-sonnet-calstack,g1-08-opus-fm,g1-05-opus-ens-meter-big,g1-07-sonnet-pool-scoped,g1-10-fable-analog,g1-10-fable-mix,g1-09-opus-ensemble,g1-09-opus-split
   C=g2-01-haiku-weekly-209m-extended,g2-02-sonnet-deep-meter-v8,g2-03-opus-spend-fast,g2-04-opus-fable-pool,g2-05-sonnet-final,g2-06-opus-fmgate2,g2-07-opus-pool,g2-08-fable-burst,g2-08-fable-burst-mix
   R=$ARENA_HOME/results          # if ARENA_HOME is unset: ~/.local/share/pacer-arena/results

   uv run --extra fm arena run --models $A --tier lockbox --episodes 48 --seed 11 --targets $TARGETS --snapshot <frozen> --jobs 6 --progress
   uv run --extra fm arena run --models $B --tier lockbox --episodes 48 --seed 11 --targets $TARGETS --snapshot <frozen> --docker --jobs 4 --progress --results-db $R/final-gen1.duckdb
   uv run --extra fm arena run --models $C --tier lockbox --episodes 48 --seed 11 --targets $TARGETS --snapshot <frozen> --docker --jobs 4 --progress --results-db $R/final-gen2.duckdb
   uv run arena runs merge --from-db $R/final-gen1.duckdb --run <B run> --into <A run>
   uv run arena runs merge --from-db $R/final-gen2.duckdb --run <C run> --into <A run>
   ```

   The finalists were each agent's own submission (its hand-back notes) and,
   for generation 1, the leaders of the generation-1 board; A is the ports
   that lead or anchor some board. Expect hours: combiners and structural
   models take minutes per episode under Docker.

Boards:

```sh
uv run arena board --run <A run>                                   # one leaderboard per target
uv run arena board --run <A run> --target meter.seven_day --baseline port-engine-rule
```

## 5. An agent generation

Everything goes under `ARENA_FLEET_ROOT`; read
[`docs/fleet-verification.md`](docs/fleet-verification.md) first. Plans of
earlier generations are in [`fleet/generations/`](fleet/generations), and
their `plan.toml` files are the templates for a new one.

1. **Visible view.** The agents' train-only copy of the snapshot (late values
   masked, labels cut at `T_train`):

   ```sh
   uv run arena fleet visible --snapshot <frozen>
   ```

2. **Install** the eval gate (the one command an agent may use to reach hidden
   data) into the fleet root, with the Docker endpoint pinned:

   ```sh
   uv run arena fleet install
   uv run arena fleet selftest            # optional: one tiny Haiku agent on dummy data checks the sandbox
   ```

3. **Template**: the repo every agent of the generation clones. Earlier models
   come from `models/`; their scores from the boards above (several runs
   allowed, one section each):

   ```sh
   uv run arena template gen3 --snapshot <frozen> --models $PORTS,$G1,$G2 --from-results <phase-2 board run>,<gen-1 board run>
   uv run arena fleet image --gen gen3    # the scoring image from the template
   ```

4. **Plan**: a TOML with `[fleet]` (`max_parallel`, `eval_budget`,
   `eval_episodes`) and one `[[agent]]` per agent (`name`, `niche`, `model`,
   `effort`, `max_turns`, `budget_usd`, `task`); copy
   `fleet/generations/gen2/plan.toml` and edit it. Spread Claude models across
   niches at random.

5. **Launch** (dry run first; agents run in waves of `max_parallel` at low
   priority, each gated on your usage if the pacing CLI is present):

   ```sh
   uv run arena fleet launch --gen gen3 --plan plan.toml --dry-run
   uv run arena fleet launch --gen gen3 --plan plan.toml
   ```

6. **Status** while it runs: `uv run arena fleet status --gen gen3`.

7. **Collect**: fetch each agent's hand-back, check it modified no earlier
   model, run the reviewer, scan the transcripts for attempts on hidden data,
   register the new models:

   ```sh
   uv run arena fleet collect --gen gen3
   ```

   A "modified an earlier model" flag can be a mode-only change
   ([`docs/known-issues.md`](docs/known-issues.md)).

8. **Import** into the repo: copy the models into `models/` (without the
   agents' scratch folders), record their attribution in
   `models/PROVENANCE.toml` and the generation in
   `fleet/generations/gen3/agents.toml`; then check each new model and write
   `SUMMARIES.md` from the agents' `REPORT.md` notes, in relative terms only
   (no spend or token figures: they describe your usage):

   ```sh
   uv run arena provenance import gen3 --summaries summaries.json   # {agent: one sentence}
   uv run arena provenance check
   for m in $(uv run python -c "from arena import provenance as p; print(' '.join(m for a in p.agents(3) for m in a['models']))"); do
     uv run --extra fm arena test models/$m --episodes 2 --snapshot synth-default --json > /dev/null || echo "FAILED $m"
   done
   ```

9. **Tournament** as in step 4: the new generation's board on the leaderboard
   tier, then finalists on the lockbox with the same seed and episodes as the
   earlier lockbox runs, merged in.

## 6. The prospective re-run (two weeks later)

The lockbox was scored once. The honest test is data that did not exist when
the models were written: export a newer snapshot and score the same frozen
models only at cutoffs after the old freeze.

```sh
uv run arena export --id <new> --freeze           # same ARENA_HOME, so the same salt and account labels
uv run --extra fm arena run --models $A --tier prospective --after <frozen> --snapshot <new> --episodes 48 --seed 11 --targets $TARGETS --jobs 6 --progress
uv run --extra fm arena run --models $B --tier prospective --after <frozen> --snapshot <new> --episodes 48 --seed 11 --targets $TARGETS --docker --jobs 4 --progress --results-db $R/prosp-gen1.duckdb
uv run --extra fm arena run --models $C --tier prospective --after <frozen> --snapshot <new> --episodes 48 --seed 11 --targets $TARGETS --docker --jobs 4 --progress --results-db $R/prosp-gen2.duckdb
uv run arena runs merge --from-db $R/prosp-gen1.duckdb --run <B run> --into <A run>
uv run arena runs merge --from-db $R/prosp-gen2.duckdb --run <C run> --into <A run>
```

- `--after <frozen>` means the frozen snapshot's `T_end`; an ISO time works
  too. Cutoffs fall in `(T_end of <frozen>, T_end of <new>]`; each model still
  sees everything known before its cutoff. The command prints the span.
- Two weeks give about two weekly cycles per account: enough to check the
  lockbox ranking roughly, not to settle close calls. Note the `--after` value
  next to the run id (the runs table does not store it).
- Model hashes cover the harness code, so if the harness changed since the
  lockbox, the same models carry new hashes: compare runs by model name.

## 7. Reports

- **Private HTML** (absolute scores from your data; keep it to yourself):

  ```sh
  uv run arena report --runs <A run> --baseline port-engine-rule --gens 1,2 --out $ARENA_HOME/reports/lockbox.html
  ```

  `--narrative notes.md` adds your own summary (a heading containing
  "Caveats" becomes the caveats section); `--selftest results.json` adds the
  self-test table.

- **Public `RESULTS.md`**: `arena report --public` writes relative results
  only (skill against a baseline, ranks, calibration), safe to publish.
  Read it before committing it anyway.

## Housekeeping

- Docker runs use `--rm` containers; `docker volume ls -qf dangling=true`
  should stay near zero.
- `ARENA_HOME/cache/children` holds child forecasts keyed by model hash; stale
  entries are never read again, delete the folder to reclaim space.
- Stop a long `arena run --jobs N` with Ctrl-C in its terminal, then check for
  leftover workers ([`docs/known-issues.md`](docs/known-issues.md)).
