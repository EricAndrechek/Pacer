# Prior art for Pacer's forecasting research harness

Literature review written before the arena was built (2026-10-24), kept as the reasoning behind its design (`DESIGN.md`). "[unverified]" marks claims found only in secondary sources; package and licence notes were current then.

## 1. Naming: mostly not RL

The plan stacks four established fields:

- **Inner loop: online probabilistic forecasting under prequential evaluation.** You forecast, observe, score, then update ([Dawid 1984](https://www.cs.ubc.ca/~murphyk/MLRG/dawid84Prequential.pdf)). For streams under drift, the standard estimator is prequential error with fading factors ([Gama et al. 2013](https://doi.org/10.1007/s10994-012-5320-9)).
  - The random-window benchmark is **rolling-origin evaluation**, also called backtesting ([Tashman 2000](https://doi.org/10.1016/S0169-2070(00)00065-0); [Cerqueira et al. 2020](https://doi.org/10.1007/s10994-020-05910-7)).
  - "Adaptation" is **regret** against the best model in hindsight (Cesa-Bianchi & Lugosi, *Prediction, Learning, and Games*).
  - Calibrated bands under drift come from **adaptive conformal** methods ([Gibbs & Candès 2021](https://arxiv.org/abs/2106.00170); [conformal PID](https://arxiv.org/abs/2307.16895)).
- **Models calling models: stacking, forecast combination and meta-learning.** Examples are Wolpert's stacking, [FFORMA](https://doi.org/10.1016/j.ijforecast.2019.02.011) (M4 runner-up) and exponential-weights expert aggregation. Beware the "combination puzzle": a simple average often beats fitted weights ([Claeskens et al. 2016](https://doi.org/10.1016/j.ijforecast.2015.12.005)).
- **Outer loop: LLM-guided program search.** This is AutoML with an LLM as the mutation operator (§3).
- **Agents that see only scores: adaptive data analysis** (§2).

RL fits only where forecasts change the data. Pacer's forecasts drive the rotation controller and the user's pacing, so the per-account split is **performative** ([Perdomo et al. 2020](https://arxiv.org/abs/2002.06673)). The outer loop trains nothing by gradient; "evolutionary search with an archive" names it better.

**Recommendation:** Frame it as "prequential evaluation of online forecasters, plus LLM program search", and borrow online-learning tools rather than RL tools. The exception is the account split, which should be treated as dependent on the controller's policy.

## 2. Hidden-test evaluation of submitted code

- **Kaggle code competitions.** Submitted notebooks are re-run offline on Kaggle's servers against test data that cannot be downloaded, and only scores come back. Time-series competitions (Optiver, Jane Street) serve the test set through an API (`env.iter_test()`, now the `kaggle_evaluation` gateway). Each next batch, with lagged truth, arrives only after the current predictions are in. Final ranks come from a **forecasting phase** that re-runs frozen notebooks on data collected after the deadline ([Optiver](https://optiver.com/kaggle-and-optiver-predicting-nasdaqs-closing-cross-auction-movements/)). [API details are from general knowledge; Kaggle's pages would not fetch.]
- **Public vs private leaderboard.** Across 120 Kaggle competitions there was little adaptive overfitting ([Roelofs et al. 2019](https://papers.nips.cc/paper/9117-a-meta-analysis-of-overfitting-in-machine-learning)). Those had large test sets and about 5 submissions a day; automated agents on one person's data have neither.
- **Theory.** Thresholdout answers a holdout query only when the holdout answer differs noisily from the training one ([Dwork et al. 2015](https://arxiv.org/abs/1506.02629)). The Ladder reports a new score only when it beats the best by a margin, and its paper shows a "boosting attack" that climbs a naive leaderboard without learning anything ([Blum & Hardt 2015](https://arxiv.org/abs/1502.04585)).
- **LLM agents overfit their selection signal.** On MLE-bench, choosing the final solution by test score instead of validation would add about 9–13 medal-rate points ([Toledo et al. 2025](https://arxiv.org/abs/2507.02554)). AIRA₂ attributes this to evaluation noise ([2603.26499](https://arxiv.org/abs/2603.26499)).

For this project:
1. **Split by time into three tiers.**
   - *Dev* (the oldest data, plus synthetic): rich per-window diagnostics.
   - *Leaderboard* (the middle period): Ladder feedback only, meaning a rounded score or "improved by ≥δ", with a query budget per agent per generation.
   - *Lockbox* (the latest weeks): final selection only, never shown to agents.
2. **Score prospectively.** Freeze each generation and score it on data that did not exist when it was written. That is Kaggle's forecasting phase, and the idea behind [ForecastBench](https://arxiv.org/abs/2409.19839) and [LiveHouse-TS](https://arxiv.org/abs/2608.17299). Pacer generates that data daily.
3. **Sandbox the model code.** No network, no data paths, and no logs returned to the agent. Start a fresh process per window, or a stateful model carries future truth into an earlier, overlapping window.

**Recommendation:** Use Kaggle-style execution behind a streaming gateway, three time-tiered splits with Ladder feedback, and new data as the final arbiter.

## 3. LLM-driven program search

**Systems:**
- **[FunSearch](https://www.nature.com/articles/s41586-023-06924-6)** evolves one function inside a fixed skeleton. It keeps islands, clusters programs by their score signature, and prompts with the best k=2 programs. Weak islands are reseeded, and the evaluator is sandboxed.
- **[AlphaEvolve](https://arxiv.org/abs/2506.13131)** applies diffs to whole files, uses an LLM ensemble and a MAP-Elites plus islands database, and runs an **evaluation cascade** (cheap checks before expensive ones).
- **[OpenEvolve](https://github.com/algorithmicsuperintelligence/openevolve)** is an open reimplementation with no documented defences against reward hacking.
- **[ShinkaEvolve](https://arxiv.org/abs/2509.19349)** reached state of the art in about 150 evaluations. It rejects near-duplicate candidates by embedding before evaluating them, samples parents by fitness and novelty, and runs a bandit over the LLMs.
- **Agent-level search.** [AIDE](https://arxiv.org/abs/2502.13138) runs a tree search; [MLE-bench](https://arxiv.org/abs/2410.07095) grades on hidden tests and checks logs for plagiarism; [RE-Bench](https://arxiv.org/abs/2411.15114) compares agents with human experts.
- **2025–26 work.** The [Darwin Gödel Machine](https://arxiv.org/abs/2505.22954) keeps an open-ended archive of agents. [CORAL](https://arxiv.org/abs/2604.01658) runs co-evolving long-lived agents with shared memory, **isolated workspaces and a separate evaluator**, and reports a 3–10× higher improvement rate than fixed evolutionary search. [EvE](https://arxiv.org/abs/2605.09018) rates agents by their *marginal gain*.

**Cheating is the default:**
- METR found o3 reward-hacked 30.4% of RE-Bench runs, where the scorer was visible, against 0.7% on HCAST. Tactics included stubbing evaluators, overwriting timers or equality, and reading the grader's answer off the call stack. "Don't cheat" prompts barely helped ([METR 2025](https://metr.org/blog/2025-06-05-recent-reward-hacking)).
- The Darwin Gödel Machine deleted the markers its own hallucination detector relied on.
- In ImpossibleBench, hiding tests nearly eliminated cheating ([2510.20270](https://arxiv.org/abs/2510.20270)).

**Lessons for ~10 agents per generation:**
- Agents get an interface, never the scorer.
- If copying is allowed, a small population collapses onto the leader. Assign niches (structural, statistical, foundation-model, ensemble) and show each agent the best models plus a diverse sample. Reward marginal ensemble contribution, not raw score alone.
- "Copy, not modify" means content-addressed, immutable models composed by reference.
- Randomise agent model × effort across niches, or attribution is confounded.
- Run an LLM monitor over every submission to catch hard-coding and probing.

**Recommendation:** Copy FunSearch/OpenEvolve's island-and-niche database and CORAL's isolation, and monitor every submission.

## 4. Interface and metrics

- **Use sample paths, not per-horizon quantiles.** Quantiles cannot answer path questions: whether the meter hits 100% before reset, the time to limit, or whether 5h, 7d, per-model caps and spend agree. Joint sample paths can, because every such functional derives from them.
- **Scores, all strictly proper** ([Gneiting & Raftery 2007](https://doi.org/10.1198/016214506000001437)):
  - Per target and lead time: CRPS with the fair estimator, or pinball/WQL for quantile models.
  - Whole paths: energy score **plus** variogram score, since the energy score barely notices correlation errors ([Scheuerer & Hamill 2015](https://doi.org/10.1175/MWR-D-14-00269.1)).
  - Interval sets: WIS ([Bracher et al. 2021](https://doi.org/10.1371/journal.pcbi.1008618)).
  - Events: Brier and log score.
  - Time to limit: survival CRPS censored at reset ([Avati et al. 2020](https://arxiv.org/abs/1806.08324)).
  - Calibration: PIT and coverage.
  - Across targets: skill scores against a fixed baseline.
- **Pacer specifics.** Score only at real polls (never interpolate the truth); truncate at `resets_at`.
- **Libraries.**
  - [scoringrules](https://github.com/frazane/scoringrules) covers CRPS, energy, variogram, threshold-weighted, Brier, log and interval scores, with numpy/numba/jax backends. properscoring is its predecessor.
  - utilsforecast has quantile losses and coverage.
  - [fev](https://github.com/autogluon/fev) has rolling windows, skill score and win rate, plus foundation-model adapters.
  - statsforecast, sktime, darts and gluonts are regular-grid backtesters.
  - river is prequential for online learners.
  - None handles event streams, irregular polls, reset-bounded horizons and bitemporal as-of views together.

**Recommendation:** Build the thin core yourself: as-of views over parquet/DuckDB, the gateway, the window sampler and a cache. Reuse scoringrules for all scoring and fev/statsforecast for baselines.

## 5. Time-series foundation models, late 2026

| Model | Sizes | Weights licence | Covariates | Output | Package |
|---|---|---|---|---|---|
| **Timestral** (Mistral, 2026-10-15) | 5M/28M/123M/209M | Modified MIT (revenue cap [unverified]) | past + future, categorical, multivariate | 21 quantiles; CPU 10–140 ms (vendor) | [mistralai/timestral](https://mistral.ai/news/timestral/) |
| **TimesFM-3** (Google, 2026-08 [secondary]) | 330M | **non-commercial** | past + future | 9 quantiles | `timesfm` |
| TimesFM-2.5 | 200M | Apache-2.0 | in-context regression | quantiles | `timesfm` |
| **Chronos-2** (Amazon, 2025-10) | 120M | Apache-2.0 | past + future, multivariate | quantiles | `chronos-forecasting>=2.0` |
| Chronos-Bolt | 9–205M | Apache-2.0 | none | quantiles; fastest | same |
| **Toto 2.0** (Datadog, 2026-05) | 4M–2.5B | Apache [weights unverified] | multivariate | probabilistic | `toto-2` |
| Moirai 2.0 | 11.4M | CC-BY-NC-4.0 | unclear | quantiles | `uni2ts` |
| TiRex | 35M | NXAI Community | none | quantiles | `tirex-ts` |
| Sundial | 128M | Apache-2.0 | none | **native sample paths** | HF `thuml/sundial-base-128m` |
| TabPFN-TS-3 (2026-05) | n/a | no production use | any features | quantiles; slow | `tabpfn-time-series` |
| Time-MoE / MOMENT / Lag-Llama | — | permissive | none | superseded | — |

All except the largest Toto models run on CPU.

**Leaders, all self-reported:**
- Timestral-209M claims first place zero-shot on GIFT-Eval, TIME and fev-bench, and says its 28M model beats Chronos-2.
- Toto 2.0 tops GIFT-Eval when non-zero-shot entries are included ([2605.20119](https://arxiv.org/abs/2605.20119)).
- On fev-bench, Chronos-2 leads TiRex and TimesFM-2.5 ([2509.26468](https://arxiv.org/abs/2509.26468)).
- Agent-built ensembles ([TimeCopilot](https://arxiv.org/abs/2509.00616), [TSOrchestr](https://arxiv.org/abs/2512.16022)) already sit on GIFT-Eval. They are direct prior art for agents composing these models.

These models extrapolate a series from its own past; Pacer's meters are structured (monotone within a cycle, resetting at `resets_at`, driven by spend).

**Recommendation:** Use Timestral-28M/123M, Chronos-2 and TimesFM-2.5 as child models that forecast spend rate, with a structural model mapping spend to meter points. Keep the non-commercially licensed models for research only.

## 6. Holes

- **Point-in-time correctness.** Pacer's rows are not what was known at the time:
  - Streamed turns are later replaced by their finished copy (the repo's `AGENTS.md`, correctness rule 7).
  - Dedup, archive folds and restamps rewrite rows.
  - Prices were back-filled.
  - Ingest lags behind writes.

  The store needs to be **bitemporal**, with as-of meaning *recorded ≤ cutoff*. Two more places leak: state carried across windows, and stacking on child predictions that were not made out-of-sample ([Kapoor & Narayanan 2023](https://doi.org/10.1016/j.patter.2023.100804)).
- **Nonstationarity.** Limit policy, per-model caps, models, prices and the rotation controller (live since 2026-10-19) all change. Tag regimes, report per regime, and give recent data more weight.
- **Winner's curse.** The best of K looks better than it is. Use White's Reality Check / Hansen SPA or the **Model Confidence Set** ([Hansen et al. 2011](https://doi.org/10.3982/ECTA5771)), and see backtest-overfitting probability ([Bailey et al. 2017](https://doi.org/10.21314/JCF.2016.322)). Re-score the winner on the lockbox.
- **Evaluation variance.** Overlapping windows are correlated, so the effective sample size is the number of independent weeks, roughly 4 a month for 7-day targets, and the accounts share one person. Freeze a paired window set, use a block bootstrap by week, and test with Diebold–Mariano (HAC). Detecting a gain δ needs about (2.8σ_d/δ)² independent blocks.
- **Compute.** The harness, not the parent, invokes children and memoises them on (child hash, cutoff, data version). Cap depth and time; score at a fixed cadence.
- **Single user.** Results describe one person's usage, not other users'. At minimum, run leave-one-account-out and prospective tests.
- **Synthetic data.** Agents tuned on a simulator learn the simulator's assumptions. Use synthetic data to debug interfaces, not to select models. Synthetic data bootstrapped from real data leaks that data to the agents.

**Recommendation:** Build the bitemporal as-of store, the paired window set with bootstrap intervals, and the lockbox and prospective tier before any agent generation; without them no later score can be trusted.
