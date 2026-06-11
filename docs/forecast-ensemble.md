# Forecast ensemble — a self-selecting tournament of predictors

> Status: **foundation landed (pure, tested, offline-validated); not yet
> wired to any displayed surface.** Originating idea (Eric): instead of
> hand-picking one projection method, keep a set of algorithms, score each,
> and use whichever is performing best — swapping dynamically as one starts
> outperforming the others. This note records the design + what's built.

## Why

The predictions redesign (`docs/predictions-redesign.md`) proved that **no
single projection method wins everywhere** — naive beat the 2nd-derivative
estimator for end-of-day/monthly, profiles beat naive, the estimator beat
linear for the 7-day window. Those choices were made by hand, by backtesting
on Eric's real store. The ensemble *systematizes and automates* that: run
every candidate against the user's own realized history and let the data pick
the winner, per surface, per user, re-evaluated as behavior drifts.

## The one subtlety: score out-of-sample, not in-sample fit

The natural-but-wrong score is "which method fits the curve best" (R²).
Optimizing in-sample fit picks the most *overfit* model, which forecasts
worse. The tournament instead scores **walk-forward forecast error**: at each
past cut-point a forecaster sees only the data up to then, projects, and is
graded against what the period *actually* totalled (robust median absolute %
error). Same data the manual before/afters used — just systematized.

## Pieces (PacerCore/Forecast/Ensemble/)

- **`Forecaster`** — protocol: `projectTotal(ForecastInput) -> Double?`, plus
  an `id` and a `complexity` rank. Pure value types.
- **`ForecastInput`** — the current partial period as a cumulative series +
  prior complete periods + calendar. Value-agnostic.
- **Candidates** (end-of-day roster, each wrapping a shipped method):
  `average-rate` (clock-linear pace, complexity 0), `recent-rate`
  (current naive, 1), `recency-slope` (`TrendEstimator`, 2),
  `hour-of-day-shape` (`ActivityProfile` blend, 2).
- **`Backtester`** — scores forecasters over `Case`s (input + realized truth):
  median/mean abs % error + *coverage* (fraction of cases it could project).
- **`ForecastSelector`** — picks the winner with three guardrails:
  **eligibility** (enough cases + coverage), **prefer-simpler** (take the
  simplest model within a small error margin of the best — Occam's selection,
  the main defense against overfitting the *choice*), and **hysteresis**
  (don't switch off the incumbent unless a challenger beats it by a margin).

## Offline validation

Run over the real store's end-of-day data (165 backtest cases), the selector
**independently picked `hour-of-day-shape`** — the exact method hand-selected
and shipped in #48:

```
hour-of-day-shape  median 16.5%   (selected)
recent-rate        median 18.8%
average-rate       median 21.0%
recency-slope      median 28.3%
```

So the tournament reproduces the right choice with no human in the loop.

## Next steps (not done)

1. **Monthly roster** — add a day-of-week-weights candidate; reuse the same
   framework with a month-length period.
2. **Wire it in (gated)** — have the cards read "the selected forecaster for
   this surface" instead of a hardcoded method. Run the selector *offline /
   logging-only* first to confirm its live picks beat the hardcoded ones,
   then swap (displayed change → before/after + sign-off, as always). Since
   the selector currently picks the already-shipped method, the first wire-in
   is a no-op on the displayed numbers — it just moves the *choice* into data.
3. **On-device ML candidate — built (#53).** `MLFeatures` featurizes
   (soFar, elapsed-fraction, hour-of-day, weekday, recent rate, pace
   baseline) → training rows replayed from prior periods; `CreateMLTrainer`
   (guarded `#if canImport(CreateML)`) trains an `MLBoostedTreeRegressor`
   on-device and hands back a pure prediction closure; `RegressorForecaster`
   enters it as *just another candidate*. Validated on the real store
   (out-of-sample, 79 cases): the model trains fine but **loses** to
   `hour-of-day-shape` (37.6% vs 14.5% median) on ~28 days of training data,
   so the selector correctly doesn't pick it — exactly the de-risk: ML can
   only help, never regress. It'll be selected automatically if it starts
   winning (more history, or better features — stacking the simple
   forecasters' outputs as features is the obvious next lever).
4. **Uncertainty** — the spread of candidate predictions is a cheap interval
   ("$10.5k–$12k"), more honest than a single point.
