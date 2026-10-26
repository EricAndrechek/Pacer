# Known issues

Open problems in the harness, the fleet tooling and the results so far, each
with what to do about it until it is fixed. The history behind most of them is
in [`history.md`](history.md).

## Harness

- **Orphaned `--jobs` workers on SIGTERM.** Killing `arena run --jobs N` with
  SIGTERM (or closing its terminal) stops the parent but leaves its job
  processes and multiprocessing's resource tracker running, re-parented to
  init; under `--docker` they keep starting containers. Until the pool handles
  signals: stop a run with Ctrl-C in its terminal (SIGINT reaches the whole
  process group), or signal the group (`kill -TERM -<pgid>`); afterwards check
  `pgrep -fl 'arena|multiprocessing'` and `docker ps --filter name=arena-` and
  kill what is left.
- **Host workers are for trusted models only.** A host worker
  (`python -m arena.worker`, the default for `arena run` and `arena test`) runs
  as you and can open any file you can, including the snapshot's `holdout/`.
  The as-of guarantee holds only for Docker workers (no data mounted). `arena
  run` refuses agent models (`models/PROVENANCE.toml`, or anything under the
  fleet root) on a hidden tier without `--docker`; `--trust-agent-models`
  overrides that, and nothing stops a model you wrote yourself. Visible-tier
  and synthetic runs on host workers are for development, not for picking
  winners.
- **In-process workers share one Python process.** `arena test` runs models
  in-process by default. Agent models import their own helper files by bare
  name (`from hourly import …`), and two models with a helper of the same name
  in one process get whichever loaded first. Use `--subprocess` when testing a
  model whose children carry helpers (tournaments always use processes).
- **`cycle.next_start` cutoffs are length-biased.** A cutoff drawn uniformly in
  time lands in long idle stretches more often than short ones, and with a
  24-hour horizon "no start before the horizon" is often right. Read
  next-start boards with that in mind; a longer horizon or reporting by idle
  length would fix it.
- **The runs table does not record `--after`.** A prospective run is stored as
  tier `prospective` on the newer snapshot; note the `--after` value next to the
  run id (the command prints the tier's span when it starts).
- **Children are re-fitted at every checkpoint.** A model that calls children
  through `ctx.model(...)` re-runs them per checkpoint, each in its own
  container under Docker: combiners and structural models take minutes per
  episode there. Several agents moved their children in-process to stay within
  the eval gate's time limit.

## Fleet tooling

- **The collector flags mode-only changes as edits.** `arena fleet collect`
  reports "modified an earlier model" when only a file's mode changed (the
  template makes earlier models read-only; the hand-back commit records the
  mode). Every generation-2 agent was flagged this way for
  `g1-05-opus-ens-meter/tools_bench.sh`; none had edited it. Until the check
  ignores mode-only diffs, confirm a flag with `git diff --stat` in the
  generation's `collect.git` before treating it as a violation.
- **Arena-eval draws new episodes on every call.** Agents could not compare two
  of their own models on the same hidden episodes, and several found call-to-
  call noise larger than the differences they were testing. A paired mode (two
  models, one call, same episodes) was requested.
- **Agents' git does not work inside the sandbox.** Handled, not fixed: the
  launcher commits `models/`, `REPORT.md` and `UPSTREAM.md` when the run ends,
  and the brief says not to run git.

## Results

- **The Fable cap was degenerate in the lockbox.** The scoped weekly meter
  barely moved during the lockbox weeks, so a flat forecast (and the live
  meter) beat every model that predicted movement. The lockbox says nothing
  about forecasting that cap; the prospective re-run may.
- **The five-hour lockbox sample was small**: 10 episodes, against 19 to 20
  for the weekly meters and hourly targets. Its ranking is not reliable, and
  next start (7 episodes) even less so.
- **One person's data.** Every result describes four accounts of one user.
  Run the same pipeline on your own export before believing any ranking.
- **Generation 1 had two setups.** g1-08, g1-09 and g1-10 started after the
  mid-generation fixes (longer commands, offline weights); compare them with
  g1-01 … g1-07 accordingly.

## Imported agent models

- **Known model bugs are left as written** (they are the agents' work, scored
  as submitted). Every imported model loads through the registry and was run
  with `arena test --episodes 2` on a synthetic snapshot: 85 of 89 run
  cleanly. Four of g1-02-haiku's fail on every forecast:
  `g1-02-haiku-fm-online` raises, and `g1-02-haiku-fm-split`,
  `-fm-spend-ensemble` and `-fm-spend-stack` return forecasts without the
  requested keys (scored as `invalid_forecast`). Tournaments count those as
  misses.
- **Some agent comments quote scores** from their own runs on the visible and
  leaderboard tiers (meter CRPS in percentage points, coverage). They are
  agents' notes, kept as written; no spend or token figure appears.
- **Tuned priors.** A few agent models carry small priors fitted on the
  visible tier: g1-08-opus-fm's PIT calibration maps (and the copies in
  g2-06-opus-fmgate and -fmgate2), g1-10-fable-analog's default hour-of-day
  activity shape and idle factors (also copied into g2-06), and
  g2-08-fable-burst's prior hazards. On someone else's data they act as
  priors that the account's own history overrides as it accumulates.
- **Pretrained weights carry their own licences**, some non-commercial
  (Moirai-2 CC-BY-NC-4.0, TiRex NXAI community licence, Timestral modified
  MIT); see [`research-prior-art.md`](research-prior-art.md) §5 before using
  a model outside research.
