# Forecast arena results

Generated 2026-10-26. Baseline: `port-engine-rule`. Relative-only: skill in percent against the baseline.

## Summary

## The short version

The first round of the forecast arena (October 2026) asked how well models can forecast Claude Code rate-limit meters and spend. It tested what Pacer ships against 45 ported models and 89 models written by two generations of Claude agents.

**Models from this round beat what Pacer ships on every meter.** They were judged on the most recent three weeks of one real usage history, which no model and no agent ever saw.

- **5-hour meter:** about **35% more accurate** than Pacer's shipping rule (CRPS skill). The typical miss at reset is about a third smaller, and the miss at the next reading about two-thirds smaller.
- **Weekly meter:** about **48% more accurate**.
- **Hourly spend:** about **40% more accurate** than assuming the current rate continues.

**The winners are simple, not giant.**
- The smallest pretrained model, **Timestral 5M**, matched or beat the 123M and 209M versions on both meters.
- The 5-hour leader is a **nearest-moments ("analog") forecaster written from scratch by a Fable 5.1 agent**, with no pretrained weights at all. It looks for past moments like now and replays what followed.

## How the round ran

**Step 1: a test bench that can't be fooled.** A frozen, pseudonymised snapshot of the usage history, with two clocks on every row (when it happened, when Pacer could have known it), checked row for row against the raw transcripts. The harness hands each model only what was known at the forecast moment and scores the whole forecast path, including how honest its ranges are.

The proof it holds:

- a model handed the answers scores perfectly;
- models that try to cheat gain nothing;
- the Python port of Pacer's engine reproduces every prediction the current app recorded.

**Step 2: everything that existed, ported and ranked (45 models).**

- Pacer's 7 engine methods and the rule it ships.
- The live meter and spend models.
- Timestral in 4 sizes, plus Chronos-2, TimesFM 2.5, TiRex, Toto and Moirai.
- Machine-learning models and model combiners.

**Step 3: two generations of Claude agents, 18 in all.** Haiku 4.5 up to Fable 5.1, at low up to extra-high effort, each in a sandbox that could not reach the hidden data, together wrote 89 models. The second generation started from the first generation's models and scores.

## What the agents showed

- **Fable 5.1 and Opus 5.5 wrote the standouts:** the 5-hour analog model, the weekly ensembles, and the best account-split and next-cycle-start forecasts.
- **The leaderboard flattered some models.** The first generation's leaderboard winner on the 5-hour meter (Sonnet 4.6 at low effort, calibrating Timestral) fell back to about the shipping rule's level on the hidden final weeks. Catching that is what the held-back weeks are for.
- **The second generation added small, real gains.** On the weekly meter, a Haiku 4.5 agent's long-context Timestral 209M and an Opus 5.5 agent's gated ensemble now lead, just ahead of generation 1's best. Opus 5.5's ensemble also became the best next-cycle-start forecast. On the 5-hour meter, nothing in generation 2 beat generation 1's analog model.
- **Effort and model size mattered less than expected.** A Haiku agent wrote the weekly leader.

## What's next

1. **Run a winner in shadow mode inside Pacer,** beside the shipping rule.
2. **Fix the ranges.** The winners' 80% ranges are now too wide, where the rule's were too narrow. A calibration layer is the cheapest remaining gain.
3. **Score these frozen models again on data that didn't exist yet** (`arena run --tier prospective`; see RUNBOOK.md). That is the honest test of generalisation. This round used one person's data and four accounts.

## Results by target

### 5-hour limit meter (`meter.five_hour`)

10 episodes, lockbox tier. Skill is the CRPS reduction against `port-engine-rule` (positive is better). Top 8 shown.

| # | model | kind | skill vs baseline | cover80 | PIT flatness | tied for best |
|---|---|---|---|---|---|---|
| 1 | `g1-10-fable-analog` | agent | +35.3% | 0.97 | 0.123 | yes |
| 2 | `fm-timestral-5m-meter` | port | +32.4% | 0.96 | 0.268 | yes |
| 3 | `g2-08-fable-burst` | agent | +22.9% | 0.93 | 0.078 | yes |
| 4 | `g2-07-opus-pool` | agent | +18.7% | 0.92 | 0.107 | yes |
| 5 | `g1-10-fable-mix` | agent | +17.8% | 0.96 | 0.151 | yes |
| 6 | `g2-08-fable-burst-mix` | agent | +14.8% | 0.96 | 0.174 | yes |
| 7 | `struct-timestral-123m` | port | +11.2% | 0.77 | 0.436 | yes |
| 8 | `ml-gbm-quantile` | port | +5.0% | 0.64 | 0.484 | yes |
| ref | `port-engine-rule` | port | 0.0% | 0.61 | 0.324 | yes |

### 7-day limit meter (`meter.seven_day`)

19 episodes, lockbox tier. Skill is the CRPS reduction against `port-engine-rule` (positive is better). Top 8 shown.

| # | model | kind | skill vs baseline | cover80 | PIT flatness | tied for best |
|---|---|---|---|---|---|---|
| 1 | `g2-01-haiku-weekly-209m-extended` | agent | +48.3% | 1.00 | 0.308 | yes |
| 2 | `g2-06-opus-fmgate2` | agent | +48.0% | 0.99 | 0.044 | yes |
| 3 | `g1-08-opus-fm` | agent | +47.4% | 0.99 | 0.150 | yes |
| 4 | `fm-timestral-5m-meter` | port | +46.6% | 0.96 | 0.185 | yes |
| 5 | `g2-07-opus-pool` | agent | +44.9% | 0.99 | 0.148 | yes |
| 6 | `g1-05-opus-ens-meter-big` | agent | +44.6% | 0.58 | 0.368 | yes |
| 7 | `g2-05-sonnet-final` | agent | +38.9% | 0.99 | 0.042 | yes |
| 8 | `fm-timestral-123m-meter` | port | +30.9% | 0.96 | 0.178 | yes |
| ref | `port-engine-rule` | port | 0.0% | 0.68 | 0.261 | yes |

### Scoped (per-model) meter (`meter.scoped`)

19 episodes, lockbox tier. Skill is the CRPS reduction against `port-engine-rule` (positive is better). Top 8 shown.

| # | model | kind | skill vs baseline | cover80 | PIT flatness | tied for best |
|---|---|---|---|---|---|---|
| 1 | `port-live-meter` | port | +97.7% | 1.00 | 0.006 | yes |
| 2 | `naive-flat` | port | +97.7% | 1.00 | 0.006 | yes |
| 3 | `g1-05-opus-ens-meter-big` | agent | +91.4% | 0.75 | 0.237 | yes |
| 4 | `g1-01-sonnet-calstack` | agent | +90.1% | 0.95 | 0.211 | yes |
| 5 | `fm-timesfm25-meter` | port | +88.8% | 0.83 | 0.311 | yes |
| 6 | `g1-01-sonnet-calibrate123` | agent | +85.1% | 0.72 | 0.259 | yes |
| 7 | `g2-05-sonnet-final` | agent | +81.2% | 1.00 | 0.030 | yes |
| 8 | `fm-timestral-123m-meter` | port | +79.7% | 0.99 | 0.153 | yes |
| ref | `port-engine-rule` | port | 0.0% | 0.87 | 0.135 | yes |

### Hourly spend (`spend.hourly`)

20 episodes, lockbox tier. Skill is the CRPS reduction against `naive-flat` (positive is better). Top 8 shown.

| # | model | kind | skill vs baseline | cover80 | PIT flatness | tied for best |
|---|---|---|---|---|---|---|
| 1 | `g1-10-fable-analog` | agent | +41.0% | 0.87 | 0.060 | yes |
| 2 | `g1-10-fable-mix` | agent | +40.8% | 0.87 | 0.066 | yes |
| 3 | `fm-timestral-123m-spend` | port | +40.4% | 0.84 | 0.109 | yes |
| 4 | `g1-09-opus-ensemble` | agent | +40.2% | 0.83 | 0.124 | yes |
| 5 | `g2-06-opus-fmgate2` | agent | +40.0% | 0.82 | 0.133 | yes |
| 6 | `g1-08-opus-fm` | agent | +39.9% | 0.81 | 0.134 | yes |
| 7 | `g2-03-opus-spend-fast` | agent | +38.1% | 0.93 | 0.111 | yes |
| 8 | `naive-diurnal-spend` | port | +18.5% | 0.55 | 0.285 |  |
| ref | `naive-flat` | port | 0.0% | 0.26 | 0.602 |  |

### Hourly tokens (`tokens.hourly`)

20 episodes, lockbox tier. Skill is the CRPS reduction against `naive-flat` (positive is better). Top 7 shown.

| # | model | kind | skill vs baseline | cover80 | PIT flatness | tied for best |
|---|---|---|---|---|---|---|
| 1 | `g1-10-fable-analog` | agent | +43.6% | 0.91 | 0.024 | yes |
| 2 | `g1-10-fable-mix` | agent | +43.4% | 0.91 | 0.019 | yes |
| 3 | `fm-timestral-123m-spend` | port | +42.5% | 0.88 | 0.235 | yes |
| 4 | `g1-09-opus-ensemble` | agent | +42.0% | 0.90 | 0.224 | yes |
| 5 | `g2-06-opus-fmgate2` | agent | +41.9% | 0.87 | 0.216 | yes |
| 6 | `g1-08-opus-fm` | agent | +41.9% | 0.87 | 0.215 | yes |
| 7 | `g2-03-opus-spend-fast` | agent | +41.3% | 0.94 | 0.037 | yes |
| ref | `naive-flat` | port | 0.0% | 0.56 | 0.356 |  |

### Split across accounts (`split.accounts`)

16 episodes, lockbox tier. Skill is the CRPS reduction against `naive-split` (positive is better). Top 6 shown.

| # | model | kind | skill vs baseline | cover80 | PIT flatness | tied for best |
|---|---|---|---|---|---|---|
| 1 | `g1-08-opus-fm` | agent | +49.4% | 0.92 | 0.051 | yes |
| 2 | `g1-09-opus-split` | agent | +36.9% | 0.86 | 0.136 |  |
| 3 | `g1-09-opus-ensemble` | agent | +36.8% | 0.86 | 0.138 |  |
| 4 | `g2-06-opus-fmgate2` | agent | +36.7% | 0.86 | 0.138 |  |
| 5 | `g1-10-fable-analog` | agent | +29.1% | 0.95 | 0.075 |  |
| 6 | `g1-10-fable-mix` | agent | +28.7% | 0.95 | 0.078 |  |
| ref | `naive-split` | port | 0.0% | 0.48 | 0.416 |  |

### Next cycle start (`cycle.next_start`)

7 episodes, lockbox tier. Skill is the CRPS reduction against `naive-flat` (positive is better). Top 5 shown.

| # | model | kind | skill vs baseline | cover80 | PIT flatness | tied for best |
|---|---|---|---|---|---|---|
| 1 | `g2-06-opus-fmgate2` | agent | +24.9% | - | - | yes |
| 2 | `g1-10-fable-mix` | agent | +14.8% | - | - |  |
| 3 | `g1-10-fable-analog` | agent | +14.5% | - | - |  |
| 4 | `g1-09-opus-ensemble` | agent | -3.0% | - | - |  |
| 5 | `g1-08-opus-fm` | agent | -25.0% | - | - |  |
| ref | `naive-flat` | port | 0.0% | - | - |  |

## Model catalogue

Where each model came from: the family it belongs to, the generation and the agent that wrote it, which Claude model and effort that agent ran at, the niche it was given, and the model it was copied from.

| model | kind | gen | agent | claude model | effort | niche | copied from | best skill |
|---|---|---|---|---|---|---|---|---|
| `g1-01-sonnet-calibrate123` | agent | 1 | g1-01-sonnet | sonnet-4-6 | low | machine-learning | - | +85.1% on `meter.scoped` |
| `g1-01-sonnet-calstack` | agent | 1 | g1-01-sonnet | sonnet-4-6 | low | machine-learning | - | +90.1% on `meter.scoped` |
| `g1-05-opus-ens-meter-big` | agent | 1 | g1-05-opus | opus-5 | medium | ensemble | - | +91.4% on `meter.scoped` |
| `g1-07-sonnet-pool-scoped` | agent | 1 | g1-07-sonnet | sonnet-5-5 | xhigh | statistical | - | +14.6% on `meter.scoped` |
| `g1-08-opus-fm` | agent | 1 | g1-08-opus | opus-5-5 | high | foundation-model | - | +49.4% on `split.accounts` |
| `g1-09-opus-ensemble` | agent | 1 | g1-09-opus | opus-5-5 | xhigh | ensemble | - | +42.0% on `tokens.hourly` |
| `g1-09-opus-split` | agent | 1 | g1-09-opus | opus-5-5 | xhigh | ensemble | - | +36.9% on `split.accounts` |
| `g1-10-fable-analog` | agent | 1 | g1-10-fable | fable-5-1 | high | statistical | - | +43.6% on `tokens.hourly` |
| `g1-10-fable-mix` | agent | 1 | g1-10-fable | fable-5-1 | high | statistical | - | +43.4% on `tokens.hourly` |
| `g2-01-haiku-weekly-209m-extended` | agent | 2 | g2-01-haiku | haiku-4-5 | high | weekly | `['fm-chronos2-meter', 'fm-moirai2-meter', 'fm-timesfm25-meter', 'fm-timestral-123m-meter', 'fm-timestral-209m-meter', 'fm-timestral-28m-meter', 'fm-timestral-5m-meter', 'fm-tirex-meter', 'fm-toto-meter']` | +48.3% on `meter.seven_day` |
| `g2-02-sonnet-deep-meter-v8` | agent | 2 | g2-02-sonnet | sonnet-4-6 | high | deep-ensemble | - | +30.6% on `meter.seven_day` |
| `g2-03-opus-spend-fast` | agent | 2 | g2-03-opus | opus-4-6 | high | spend | - | +41.3% on `tokens.hourly` |
| `g2-04-opus-fable-pool` | agent | 2 | g2-04-opus | opus-5 | high | fable-cap | - | +39.4% on `meter.scoped` |
| `g2-05-sonnet-final` | agent | 2 | g2-05-sonnet | sonnet-5-5 | high | calibration | - | +81.2% on `meter.scoped` |
| `g2-06-opus-fmgate2` | agent | 2 | g2-06-opus | opus-5-5 | high | wildcard | - | +48.0% on `meter.seven_day` |
| `g2-07-opus-pool` | agent | 2 | g2-07-opus | opus-5-5 | xhigh | limit-calls | - | +79.0% on `meter.scoped` |
| `g2-08-fable-burst` | agent | 2 | g2-08-fable | fable-5-1 | high | five-hour | - | +22.9% on `meter.five_hour` |
| `g2-08-fable-burst-mix` | agent | 2 | g2-08-fable | fable-5-1 | high | five-hour | - | +14.8% on `meter.five_hour` |
| `fm-chronos2-meter` | port | - | - | - | - | - | - | +26.9% on `meter.seven_day` |
| `fm-timesfm25-meter` | port | - | - | - | - | - | - | +88.8% on `meter.scoped` |
| `fm-timestral-123m-meter` | port | - | - | - | - | - | - | +79.7% on `meter.scoped` |
| `fm-timestral-123m-spend` | port | - | - | - | - | - | - | +42.5% on `tokens.hourly` |
| `fm-timestral-5m-meter` | port | - | - | - | - | - | - | +73.6% on `meter.scoped` |
| `ml-gbm-quantile` | port | - | - | - | - | - | - | +5.0% on `meter.five_hour` |
| `naive-diurnal-spend` | port | - | - | - | - | - | - | +18.5% on `spend.hourly` |
| `naive-flat` | port | - | - | - | - | - | - | +97.7% on `meter.scoped` |
| `naive-split` | port | - | - | - | - | - | - | +0.0% on `split.accounts` |
| `port-engine-rule` | port | - | - | - | - | - | - | +0.0% on `meter.five_hour` |
| `port-live-meter` | port | - | - | - | - | - | - | +97.7% on `meter.scoped` |
| `spend-decay-1d` | port | - | - | - | - | - | - | +20.4% on `meter.scoped` |
| `spend-decay-30m` | port | - | - | - | - | - | - | -91.8% on `meter.five_hour` |
| `spend-decay-6h` | port | - | - | - | - | - | - | +38.7% on `meter.scoped` |
| `struct-timestral-123m` | port | - | - | - | - | - | - | +11.2% on `meter.five_hour` |

## Agents per generation

### Generation 1

| agent | claude model | effort | niche | exit | turns | eval calls | models (scored) | best 5-hour | best weekly | summary |
|---|---|---|---|---|---|---|---|---|---|---|
| `g1-01-sonnet` | sonnet-4-6 | low | machine-learning | budget cap | 224 | 7 | 7 (2) | +1.3% | +30.6% | LightGBM quantile regression (cqr), a CRPS-calibrated wrapper over the 123M Timestral and stacks of foundation models; calibrate123 became the board leader on five-hour and seven-day. |
| `g1-02-haiku` | haiku-4-5 | high | foundation-model | finished | 110 | 0 | 11 (0) | - | - | Eleven ensembles of pretrained forecasters (median, CRPS stack, quantile pooling, online weighting) across meter, spend and split targets; sandbox restrictions blocked scoring, so no results. |
| `g1-03-sonnet` | sonnet-4-6 | high | structural | finished | 265 | 3 | 2 (0) | - | - | A past-cycle bootstrap for the five-hour meter weighted by level, burn rate, activity and time of day; about 10% better than spend-decay on the visible tier but biased low on the hidden tier. |
| `g1-04-opus` | opus-4-6 | high | machine-learning | budget cap | 378 | 5 | 3 (0) | - | - | Two LightGBM quantile families: spend/tokens with lags and AR(1) copula paths, and meters with out-of-fold spread scaling and minimum spread for weekly targets; weaker on the hidden tier than visible. |
| `g1-05-opus` | opus-5 | medium | ensemble | budget cap | 233 | 3 | 4 (1) | -54.4% | +44.6% | A banded ensemble of diverse children with fitted spread and a nowcast head; a mixture pool beat quantile averaging, the wide version timed out on the scorer, and the slimmed submission was unscored. |
| `g1-06-sonnet` | sonnet-5-5 | medium | structural | finished | 20 | 1 | 1 (0) | - | - | A spend-decay-6h copy with a 1.5x wider sampled spread; about 6% better seven-day CRPS on eight visible episodes, within noise, with sandbox friction noted. |
| `g1-07-sonnet` | sonnet-5-5 | xhigh | statistical | finished | 255 | 10 | 7 (1) | - | - | Statistical analog, block-bootstrap, hazard and Markov models plus pools with spend-decay; self-calibration carried to the hidden tier, beating foundation models on hourly, next-start and split. |
| `g1-08-opus` | opus-5-5 | high | foundation-model | finished | 152 | 5 | 1 (1) | -22.5% | +47.4% | One all-target model: Timestral recalibrated on its own self-backtests with level and phase conditioning, rationing near caps, a regime simulation for split; calibration helped weekly meters. |
| `g1-09-opus` | opus-5-5 | xhigh | ensemble | finished | 166 | 6 | 5 (2) | -17.3% | +7.0% | Routed in-process ensemble of Timestral, analog-spend structural and spend-decay with a weekly re-base overlay; child-worker versions timed out on the scorer and stacking weights failed out of sample. |
| `g1-10-fable` | fable-5-1 | high | statistical | finished | 203 | 5 | 2 (2) | +35.3% | +14.3% | Kernel-weighted analog ensembles from the account's own past across all targets; strong on hourly, split and next-start, behind the leaders on weekly meters; one mix call lost to the shell time limit. |

### Generation 2

| agent | claude model | effort | niche | exit | turns | eval calls | models (scored) | best 5-hour | best weekly | summary |
|---|---|---|---|---|---|---|---|---|---|---|
| `g2-01-haiku` | haiku-4-5 | high | weekly | finished | 94 | 0 | 15 (1) | - | +48.3% | Tuned Timestral size and context for the seven-day meter: the 209M model with a 14-day context was about 8% better than the 123M baseline on a few visible episodes; no leaderboard result. |
| `g2-02-sonnet` | sonnet-4-6 | high | deep-ensemble | finished | 192 | 3 | 5 (1) | -15.6% | +30.6% | Layers of combiners over the best earlier models ended as pure routing (calibrated wrapper for five-hour and seven-day, spend-decay-1d for scoped); all leaderboard calls timed out, so no score. |
| `g2-03-opus` | opus-4-6 | high | spend | finished | 309 | 6 | 6 (1) | - | - | Weighted-empirical-quantile plus analog and surprise-path models for spend and tokens; strong on visible, worse on hidden until surprise paths widened tails; ensembles with children timed out. |
| `g2-04-opus` | opus-5 | high | fable-cap | finished | 158 | 4 | 3 (1) | - | - | Fable-cap model: resampled capped-family spend, random points-per-dollar conversion, damping, whole-point rounding, plus a spend-decay mix; better limit calls and PIT than burst alone. |
| `g2-05-sonnet` | sonnet-5-5 | high | calibration | finished | 128 | 10 | 9 (1) | -9.9% | +38.9% | Calibration layer: puts probability mass at the current whole-point reading from the meter's own unchanged-share estimate; flattened PIT with CRPS changes of a few percent; heavy ensembles timed out. |
| `g2-06-opus` | opus-5-5 | high | wildcard | finished | 118 | 3 | 2 (1) | -28.8% | +48.0% | Gated the leaders by account state (idle, blocked) with sampled resume times and rounding to whole points; helped dormant accounts and five-hour PIT; noisy hidden-tier scores. |
| `g2-07-opus` | opus-5-5 | xhigh | limit-calls | finished | 141 | 5 | 2 (1) | +18.7% | +44.9% | A limit simulator (bootstrapped burn, per-path ceilings, parking, coupling, re-base hazard) pooled with Timestral-5M; competitive seven-day Brier, poor time-to-limit, scoped rises over-predicted. |
| `g2-08-fable` | fable-5-1 | high | five-hour | finished | 87 | 5 | 4 (2) | +22.9% | - | Five-hour burst process (semi-Markov activity, integer paths); about 15% better than Timestral on visible A1 episodes, weaker on A2; a 50/50 Timestral mix tied it on CRPS, won on others. |

## Harness checks

11 checks, 0 failing.

| check | status | detail |
|---|---|---|
| Oracle (a model handed the true future) | pass | Scores ≈ perfect: CRPS ≈ 0, Brier 0, 80% coverage 1. A truth shifted by 30 minutes scores strictly worse. Run on synthetic data, Docker workers included. |
| Known answers | pass | Constant, last-value and straight-line models reproduce hand-computed scores on a tiny synthetic world. |
| Determinism | pass | Same seed gives byte-identical score rows across two runs, across in-process vs subprocess workers, and for any --jobs N. |
| Leak probes | pass | Models that try every way to see the future (files, environment, stack, history internals, the child cache, state carried between test cases, network, timing) gain nothing over a constant forecast inside Docker workers. On host workers a probe CAN read snapshot files, so host workers run trusted models only; every agent model is scored in Docker. |
| Leak control | pass | With the null-slot scrub switched off, the probe does see hidden values, so the probe is real. |
| Synthetic recovery | pass | On synthetic data, a model built from the true generating process beats every simple model (5-hour CRPS 0.27 vs about 4.3). |
| Calibration sanity | pass | Paths drawn from the true process give 80% coverage of about 0.82 and a roughly flat PIT. |
| Snapshot checks (frozen-2026-10-24) | pass | All 9 gates: store matches raw transcripts exactly, store matches the archive, Claude Code's own counters match, readings, cycles, prices, point-in-time slicing, byte-identical rebuild, leak scan. |
| Docker isolation | pass | A probe model inside a scoring container finds no ARENA_HOME, no snapshot, no data file anywhere and no network; the same probe on the host does read the snapshot. |
| Replay parity with the app | pass | The Python port of the shipping engine reproduces 1,278 of 1,278 predictions the current app recorded (largest gap 0.00002 points), and 97.8% of 28,870 including older engine versions. |
| Leaks found and closed by the self-tests | pass | 1) masked columns still carried their hidden values in the Arrow buffer under null slots (fixed: every served table is rebuilt; the as-of assertion refuses a null slot with a value). 2) Scoring between checkpoints made run time reveal how many future readings existed (fixed: scoring waits until the model's process has closed). |

### Engine port parity

The shipped Swift engine's output against the harness port, row by row.

| era | rows | within tolerance | method agrees | reading agrees |
|---|---|---|---|---|
| legacy | 27,212 | 97.77% | 94.5% | 99.5% |
| current | 1,278 | 100.00% | 100.0% | 100.0% |
| lab-standin | 380 | 89.47% | 82.6% | 100.0% |

## Caveats and method

- **The final, held-back ranking scored a selection, not all 89 agent models.** It covers the 15 strongest ports, generation 1's 9 strongest on the leaderboard runs, and each generation-2 agent's own submission(s): 33 models on identical test cases. Agent models not in that selection show "-" in the agents tables below.
- **The 5-hour ranking rests on few scored points.** Read it as "these few clearly beat the rule", not as an exact order.
- **The per-model (Fable) weekly cap couldn't be judged.** It barely moved in the final weeks, so a flat forecast wins.
- **Some agents' models fail some forecasts** (a missing key, a crash); those count as misses for that forecast only.
- **The last three generation-1 agents had a better setup than the first seven,** fixed mid-run, which confounds comparing Claude models within generation 1.
- **Ported models ran on ordinary workers, agent models in sealed Docker containers.** Tests show the two paths give identical scores.

This report is relative-only: scores are shown as skill against a baseline, and as unitless calibration measures (coverage, PIT flatness). Absolute errors, token counts and dollar amounts are left out on purpose.

### Glossary

- **CRPS**: Continuous ranked probability score: how far a whole forecast distribution sits from what happened. Lower is better, and it rewards forecasts that are both sharp and honest about uncertainty.
- **Skill**: 1 minus (model CRPS over baseline CRPS), computed on the same episode, checkpoint and target cells. 0.20 means 20% lower CRPS than the baseline; negative means worse.
- **Coverage (cover80)**: The share of true values that fell inside the model's 80% interval. Honest is 0.80; lower means over-confident, higher means too wide.
- **PIT / pit_tv**: The probability integral transform places each truth in the model's own forecast distribution. A calibrated model fills ten bins evenly; pit_tv is the distance from flat (0 is calibrated).
- **MCS**: Model confidence set (Hansen): the models that cannot be told apart from the best at the 90% level, by a block bootstrap over episodes. 'Tied for best' means in the set, not that it won.
- **ae_point, ae_reset, next_reading_ae, brier_hit**: Absolute error of the point estimate, of the predicted reset time, and of the next reading, and the Brier score of the limit-hit call.
- **Tiers**: visible: the data agents can see, for development. leaderboard: the held-out weeks that rank models. lockbox: the final weeks, scored rarely. Scores from different tiers or seeds are never averaged.
