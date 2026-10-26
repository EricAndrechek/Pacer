# How the arena was built, and what it found

A chronological account of the first weekend of work (24–26 October 2026):
the decisions, what broke and how it was fixed, the self-tests, the two agent
generations and the lockbox result. Everything here is relative or structural;
the data came from one person's Claude Code usage across four accounts (A1–A4),
and no absolute spend or token figure is reproduced. To re-run any of it on
your own data, see [`../RUNBOOK.md`](../RUNBOOK.md).

## Why build it

Pacer forecasts where each rate-limit meter will be at its reset, and how
fast spend accumulates. Its forecasts had been tuned in an earlier, unpublished
lab that scored models case by case. That scorer leaked: it built an activity
profile from all of the history (including the part being forecast) and priced
past turns at today's rates, and it scored only the value at reset, not the
path. The arena replaces it with a harness in which a model cannot see the
future even if it tries, scores whole probabilistic paths, and lets Claude
Code agents write models against a hidden test period. The reasoning and the
literature behind the design are in [`research-prior-art.md`](research-prior-art.md);
the design itself in [`../DESIGN.md`](../DESIGN.md).

## Phase 1: the harness (24 October)

The design was signed off in the afternoon. The coordinating session then
pinned the contracts itself ([`../CONTRACTS.md`](../CONTRACTS.md): the snapshot
schema, the `History` / `Request` / `Forecast` types, the runner-worker wire
format, the results tables) so five builders could work in parallel, each in its
own worktree with a disjoint set of files:

- **exporter** (Pacer's store and the raw transcripts into a point-in-time
  snapshot, behind nine validation gates);
- **core** (as-of views, the episode sampler, the runner and its worker
  processes, child models and their cache, the command line);
- **scoring** (CRPS, energy and variogram scores, Brier, coverage, PIT,
  week-block bootstrap, Diebold–Mariano, the Model Confidence Set);
- **synthetic data** (simulated users in the same schema, with the generating
  truth kept beside it);
- **fleet** (the agent sandbox, the eval gate, the template, the launcher, the
  collector and reviewer).

All five merged the same evening. What the merge turned up:

- **The first hidden-tier scorer leaked.** The fleet's design ran all of
  `arena eval` inside one container with the snapshot mounted, so a model
  process could have opened the holdout. Fixed before any agent ran: the
  runner stays on the host and is the only process that reads the snapshot;
  every model worker, children included, is its own container with no
  network, a read-only root and **no data mounted**; rows arrive only as as-of
  batches over stdin (`ARENA_WORKER_CMD`).
- **Late-known columns.** Some values in a row become known later than the
  row itself (a streamed turn's final output, a later restamp). The views mask
  each such column until its own known-time (`views.LATE_COLUMNS`).
- **The exporter's gates passed on the real data**: every row in Pacer's store
  matched the transcripts, prices covered every turn, and a re-export was
  byte-identical.

## Phase 2: self-tests and ports (24 October, evening)

Before any real model, the harness had to prove it could not be fooled
(`arena selftest`):

- **oracle**: a model handed the true future scores perfectly;
- **leak probes**: models that read files, inspect the stack, read the
  environment, open the network, poke the cache or keep state between episodes
  gain nothing over a constant forecast;
- **known answers**: constant, last-value and straight-line models reproduce
  hand-computed scores;
- **determinism**: byte-identical results across runs and worker kinds;
- **synthetic recovery**: on synthetic data the generating model wins by a wide
  margin;
- **calibration**: a calibrated model's 80 % ranges cover about 80 %.

They found two real leaks, both closed: masked columns kept their hidden values
in the Arrow buffers under the null slots and shipped them over IPC; and
scoring inside an episode, while the worker was still alive, opened a timing
side channel (scoring now happens after the worker is gone). They also showed
that a *host* worker can read the snapshot from disk, which is why host
workers are for trusted models only.

In parallel, four builders ported what existed:

- **the app's engine** (every forecasting method and the shipping rule, plus a
  replay-parity check: run through the harness, the port reproduced every
  prediction the two current engine versions had recorded, to within
  rounding, and about 98 % of all recorded rows including an older engine);
- **spend models and naive baselines** (the live meter, spend-decay at four
  horizons, flat, linear-to-reset, seasonal, diurnal, split);
- **learned models and combiners** (gradient-boosted quantiles, quantile
  forests, EWA, stacking, FFORMA, median);
- **pretrained forecasters** (Timestral at four sizes, Chronos-2, TimesFM 2.5,
  TiRex, Toto, Moirai-2, as meter models, spend models and structural
  spend-to-meter models).

Fixes decided at that merge:

- **A model's identity covers the code it runs**: its folder, `kit/`, the
  harness code that serves it, and `uv.lock`. An edit to `kit/` is a new
  model, with a cold child cache.
- **Meter grids got a dense head** (seconds to minutes ahead, then every 5 or
  30 minutes): the next-reading score had been measured at the first grid
  point, unfairly.
- **Meters can fall inside a cycle** under an unchanged reset time (an
  allowance re-based); nothing keeps a running maximum any more.
- **`cycle.next_start` cutoffs are length-biased** towards long idle stretches;
  left as a known issue.

Then the snapshot was frozen: the last three weeks as the **lockbox**, the
three weeks before as the **leaderboard** tier, everything earlier
**visible** to agents. Only two of the four accounts appear in the visible
tier; the other two first appear in the hidden tiers, a natural test of
unseen accounts. A Haiku self-test agent on dummy data confirmed the sandbox
recipe ([`fleet-verification.md`](fleet-verification.md)).

## Generation 1 (night of 24–25 October)

Ten agents, five at a time, Claude models from Haiku 4.5 to Fable 5.1 and
efforts from low to extra-high, spread at random across five niches
(machine learning, foundation models, structural, statistical, ensembles).
Each got a template repo, a turn and dollar cap, and twenty arena-eval calls
on the leaderboard tier. Plan, record and summaries:
[`../fleet/generations/gen1/`](../fleet/generations/gen1).

What went wrong, and the fixes:

- **Git did not work in the sandbox** (writes under `.git` are refused). The
  launcher's end-of-run hand-back commit saved every agent's work; the brief
  now says not to run git.
- **Commands timed out** at Claude Code's Bash limit, and **pretrained weights
  were unreachable** (the real Hugging Face cache is denied). Mid-generation,
  before the last three agents started, they got longer timeouts, the `fm`
  extra and a clone of the weights in their own folder. So g1-08, g1-09 and
  g1-10 had a better setup than the first seven.
- **Turn counts were wrong** in Claude Code's final result for some runs; the
  launcher now counts turns from the stream and reports budget or turn caps
  as such.
- **A copied model shadowed its original.** One agent copied
  `spend-decay-6h` and kept its name inside `model.toml`; the registry
  indexed that name too, so every ensemble that called the port silently got
  the copy. The registry now finds models by folder name only.

The collector fetched 43 models, the reviewer passed all of them, and the
transcript scan found no attempt on hidden data or on another agent's folder.

## The tournaments (25 October)

The first attempt to run every finalist and port together on the lockbox in
Docker was projected at about 19 hours (combiners and structural models take
minutes per episode with a container per child) and was stopped. It was
restarted as **paired runs**: the trusted ports on host workers, the agents'
models in Docker, the same tier, snapshot, seed and episode count, so the
episodes are identical, then folded into one run (now `arena runs merge`).
Stopping the first attempt exposed a bug: workers spawned by `--jobs` are
orphaned when the parent gets SIGTERM.

`arena board` on the merged run (over a million score rows) then hung for
hours inside the Model Confidence Set, which looped on models with identical
losses, and held the results database's lock meanwhile; fixed.

## Generation 2 (25–26 October)

Eight agents, each with one focus: the seven-day meter, deep ensembles, spend
and tokens, the Fable weekly cap, honest ranges, a wildcard, limit calls, the
five-hour meter. Their template held every generation-1 model and the scores
of all earlier models. All the generation-1 fixes were in from the start, and
all eight finished on their own. 46 models; reviews passed. The collector
flagged every agent for modifying an earlier model; each flag was a file-mode
change from the template's read-only copies, not an edit (a known issue). A
third paired run scored the nine generation-2 finalists on the same lockbox
episodes. Plans, record and summaries:
[`../fleet/generations/gen2/`](../fleet/generations/gen2).

## The lockbox result

48 episodes on the lockbox tier, seed 11; 15 ports and baselines, 9
generation-1 and 9 generation-2 finalists. CRPS skill is `1 − CRPS(model) /
CRPS(reference)` on identical (episode, checkpoint, target) rows: positive is
better than the reference.

| target | reference | best models | skill |
|---|---|---|---|
| five-hour meter | the shipping rule | g1-10-fable-analog; the plain Timestral-5M port close behind | about +0.35 and +0.32 |
| seven-day meter | the shipping rule | g2-01-haiku-weekly-209m-extended, g2-06-opus-fmgate2, g1-08-opus-fm, Timestral-5M, all within 0.02 | about +0.47 to +0.48 |
| Fable weekly cap | the shipping rule | a flat forecast and the live meter | about +0.98 (degenerate, below) |
| hourly spend | flat | g1-10-fable-analog and five others, within 0.03 of each other; Timestral-123M among them | about +0.40 |
| hourly tokens | flat | the same group | about +0.42 to +0.44 |
| account split | the naive split | g1-08-opus-fm | about +0.49 |
| next start | "never" (naive-flat: no start before the horizon) | g2-06-opus-fmgate2 | about +0.25 |

What it says, with the caveats that matter:

- **The shipping rule is beaten on every meter,** by a wide margin on the
  seven-day meter. But the best agent models are statistically hard to
  separate from a plain pretrained forecaster (Timestral-5M) on both meters:
  most of the gain is the pretrained model, not the agents' work on top.
- **The Fable cap was degenerate in the lockbox**: it barely moved, so a flat
  forecast was nearly perfect and every model that predicted movement lost.
  This tier says nothing about forecasting that cap.
- **The five-hour sample was small**: 10 episodes. Its ranking is not
  reliable.
- **Spend and tokens**: the agents' statistical and analog models tied the
  pretrained spend forecaster, all far ahead of the flat and diurnal
  baselines.
- **Next start** had 7 episodes; treat it as anecdote.
- **Which Claude model did better?** The top entries came from across the
  range: a Haiku agent's configuration of Timestral tops the seven-day board,
  Fable and Opus 5.5 agents most of the rest. The generation-1 agents with the
  better setup were Opus 5.5 and Fable, the larger models had larger budgets,
  and there is one run per agent: this is not a measurement of Claude models.

The next step is the **prospective** re-run: score the same frozen models on
data that did not exist when they were written (`arena run --tier prospective
--after <frozen snapshot>`; [`../RUNBOOK.md`](../RUNBOOK.md)). Open problems
are in [`known-issues.md`](known-issues.md).
