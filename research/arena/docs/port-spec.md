# Port spec: the round-1 winners in Pacer (Swift)

For the session that implements, inside Pacer, the forecasters the arena's
first round picked. The app runs every top model for real, and each user's
Pacer picks per meter from its own record (the engine's self-evaluation),
falling back to the shipping rule when no model has a record yet; there is no
shadow phase. It is
self-contained: every constant, rule and edge case needed is here, with the
Python that defines it (paths are under `research/arena/`). The Python is the
reference: where this text and the code disagree, the code wins and this
document has a bug.

What to port. The decisive lockbox runs (five-hour: six models tied for
best, all clearly better than the shipping rule, which is out of that set;
weekly: six tied for best, the Timestral-5M and 123M meters not among them)
leave one model tied for best on **both** meters that needs no pretrained
weights and builds on code the app already has:

**The recommended v1 port is spend-decay plus the calibration layer**:
`calib-spend-decay-30m` for the five-hour meter and `calib-spend-decay-6h`
for the weekly (and scoped) meters. Spend-decay was already well
calibrated on the five-hour meter, with the lowest error at reset on the
weekly one, but its weekly ranges were too wide; the calibration layer
recalibrates the ranges from its own recent backtests without moving the
median, so the point the user reads is spend-decay's. The calibrated pair was validated on the visible and synthetic tiers only
(`findings/2026-10-round1b/narrative.md`); its lockbox effect is untested.

| | forecaster | meters | status |
|---|---|---|---|
| **v1** | **spend-decay** (`-30m` five-hour, `-6h` weekly) **+ the calibration layer** | both | the port |
| alternative | the analog model (`g1-10-fable-analog`, five-hour path) | five-hour (and tied on weekly, but see below) | pure arithmetic, no weights |
| alternative | Timestral-5M (`fm-timestral-5m-meter`) | five-hour | tied for best on five-hour only; needs a converted network and its licence |

The calibration layer can sit on any of them; it never moves the median.
The analog model's weekly path is a day-model simulation (fixtures cover it
within Monte-Carlo bounds only); prefer spend-decay there.

Contents: [spend-decay](#spend-decay-the-v1-port-with-the-calibration-layer) ·
[the analog model](#the-analog-model-alternative) · [Timestral-5M](#timestral-5m-alternative) ·
[the calibration layer](#the-calibration-layer) · [Pacer's data](#mapping-to-pacers-data)
· [parity](#parity) · [open questions](#open-questions).

Conventions: times are epoch milliseconds (UTC) unless a name ends in `_s`
or `_min`; `W` is the window length (5 h or 7 d); a *reading* is one
`(t_event, util_pct, resets_at, state)` row of one meter (account × window ×
scoped cap); `HOUR = 3_600_000`, `DAY = 24 · HOUR`. The device's UTC
offset `tz` is the latest known turn's (the arena), the device clock's (the
app).

---

## Spend-decay (the v1 port, with the calibration layer)

Source: `models/spend-decay-30m/model.py` (the same code for `-6h` and
`-1d`; only `model.toml` differs), on the spend-to-meter conversion of
`kit/spend.py` (`fit_on_day`, `fit_details`, `spent_between`,
`past_cycles`, `local_day_start`). A deterministic restatement is
`kit/detq.py` (`spend_decay_parts`, `spend_decay_quantiles`).

**The idea.** The meter rises because the account spends. Convert recent
spend to meter points with the account's own fitted rate, assume the current
burn fades with a time constant τ, and take the spread from how wrong the
same forecast was at the same phase of past cycles. No weights, a few hundred
lines, and most of it (the conversion, the live value) exists in the app.

### Variants and constants

| model | windows | `lookback_min` | `case_days` | `phase_band` |
|---|---|---|---|---|
| `spend-decay-30m` | five-hour | 30 | 60 | 0.10 |
| `spend-decay-6h` | seven-day, scoped | 360 | 120 | 0.10 |
| `spend-decay-1d` | seven-day, scoped | 1440 | 120 | 0.10 |

Shared (`model.py`): `TAUS_H = (0.5, 1, 2, 4, 8, 16, 48)` hours; cut phases
`PHASES = 0.05, 0.10, …, 0.95` of the window; error points
`FRACS = 0.05, 0.10, …, 1.00` of the time left; `MIN_CASES = 16`;
`MIN_SPREAD_CASES = 8`; default τ when too few cuts: 2 h (five-hour), 16 h
(weekly, scoped); the fallback spread `σ = 0.6` (log scale).

### The conversion (`kit.spend.fit_on_day`)

Meter points per dollar per model family (`FAMILIES = fable, opus, sonnet,
haiku, other`), refit once per local day, from the 14 days before that
day's local midnight:

1. **Spend.** The account's turns (not `<synthetic>`), priced at the rates
   known at now with the best output tokens; a turn with no known rate adds
   nothing. `spent(t0, t1)` = per family, the sum over turns with
   `t0 < t_event <= t1`.
2. **Intervals.** Consecutive readings of one meter (sorted by
   `(t_event, util)`) that are both active, whose resets are within half a
   window, `0 < Δt < 1 h`, and that did not fall (`rise >= 0`); each with
   its rise and `spent(t0, t1)`. Those whose later reading falls in
   `(day − 14 d, day]`, `day` = the local midnight starting the fit's day
   (the device offset `tz` as below).
3. **Whose.** The account's own intervals when it has at least 100, else
   every visible account's (in a single-account view, its own, however
   few).
4. **Fit.** Counted families: all, or for a scoped cap only the family its
   name contains (`_cap_family`: "Fable" → fable). `X` = spend of counted
   families (others 0), `y` = rise. If `ΣX <= $1`: no conversion (the
   forecast is the reading, flat). `pooled = Σy / ΣX`. Non-negative least
   squares of `y` on `X` over the counted columns, **no intercept**. R² the
   app's way (`hourly_r2`): rise and prediction summed per local hour of the
   later reading, over hours with any rise or spend. **Weak** when
   `Σy < 20` points or `R² < 0.5`: every counted family gets `pooled`.
   Otherwise each counted family gets its NNLS rate, except a family that
   spent `<= $1` in the span, which gets `pooled`. Uncounted families: 0.

`k` below is that rate vector; `k · spent(t0, t1)` is points.

### The forecast at now (`state`, `path`)

With the cycle as for the analog model (`kit.baselines.meter_now`: the
latest known reading's own reset, `start = reset − W`, the cycle's readings
as read, `used` = the latest one, `t_last` its time):

    now_value = min(100, used + k·spent(t_last, now))
    cyc       = k·spent(start, t_last)
    ratio     = clip(used / cyc, 0.25, 4)    if cyc > 1, else 1
    span      = min(lookback, now − start)
    burn      = k·spent(now − span, now) / span        (points per ms; 0 if span <= 0)
    centre(ℓ) = clip(now_value + burn · ratio · τ · (1 − e^(−ℓ/τ)), used, 100)   ℓ = g − now

### τ, learned walk-forward (`build_cases`, `_pick_tau`)

For every visible account (own first), every past cycle (`past_cycles`:
active readings grouped by reset within half a window, reset = the
truncated median, reset before now) with reset within `case_days` of now
and seen to its end (last reading `>= reset − max(15 min, 0.05 W)`), and
every phase `u` in PHASES:

1. `cut = start + u·W` (truncated to an integer); skip unless the cycle has
   a reading at or before the cut no more than an hour old;
2. `k` = the conversion **of the cut's own local day** (`fit_on_day` for
   `min(local_day_start(cut), today)`; skip the cut if none);
3. the cut's state as above with `used` = that reading, `t_last` its time,
   `now = cut`;
4. truth at `cut + FRACS·(reset − cut)`: the step function of the cycle's
   readings (the reading before the cut where none), the last point
   replaced by the cycle's final reading;
5. for each τ in TAUS_H: `centre(FRACS·(reset − cut))`, and
   `ae = |centre at reset − final|`.

Each cut records its phase, `half = u >= 0.5`, its account, `active =
burn > 0`, `ae[τ]`, `centre[τ, FRACS]` and `truth[FRACS]`. Then τ for now:
among cuts in now's half (`(now − start)/W >= 0.5`), the account's own if
at least 16, else every account's if at least 16, the τ minimizing the
**median** `ae` (five-hour) or the **mean** `ae` (weekly, scoped); else the
TAUS_H value nearest the default.

### Paths and quantiles (`_spread_cases`, `spend_decay_quantiles`)

Pick past cuts by these filters, in order, the first holding at least 16
cuts: near (`|phase − now's phase| <= 0.10`) ∧ own ∧ same `active`;
near ∧ same `active`; near ∧ own; near; same half ∧ same `active`; same
half. If none reaches 16: near if it has at least 8, else same half if at
least 8, else none.

- **Picked cuts.** Each cut's error trajectory `truth − centre[τ]` at
  FRACS, read at today's fractions `f = clip(ℓ / (reset − now), 0, 1)` by
  linear interpolation with 0 at `f = 0`. A path is
  `centre + error`, clipped to `[used, 100]`, then made non-decreasing
  (running maximum). The model draws errors uniformly with replacement, so
  its distribution gives every picked cut's path equal weight: the
  quantile at α per grid time is the **equal-weight type-1 quantile** of
  those paths (first sorted value whose cumulative share `>= α − 1e-9`).
- **No picked cuts.** Paths `used + (centre − used)·m`, `m = e^{0.6 Z}`:
  each path is increasing in `m`, so the quantile at α is that path at
  `m = e^{0.6 Φ⁻¹(α)}`, clipped to `[used, 100]` and made non-decreasing.
- **No conversion.** The reading, flat.

All three are exact (`exact: true` in every spend fixture).

### Edge cases

| situation | what happens |
|---|---|
| idle window | no forecast (as for the analog model) |
| no spend since the reading | `now_value = used`; with no burn the centre is flat |
| re-based meter (falls within a cycle) | `used` is the latest reading as read; intervals that fell are excluded from the fit; `ratio` uses the cycle's spend before the re-base too (a known blind spot) |
| weak conversion | one pooled rate for every family (the live meter shows nothing then, the forecast still runs) |
| new account, short history | no past cycles: default τ and the lognormal spread; under 100 own intervals the conversion pools every visible account's |
| reading older than the lookback | `spent(t_last, now)` still counts everything since the reading |

### On the app's code

- **The conversion.** `SpendMeterFitter` (`LiveMeter/SpendMeterFitter.swift`,
  stored as `SpendMeterFit`) fits per **model** per **local hour** with an
  intercept (`nnls-hourly-v1`); the arena's conversion is the interval
  form above, per **family**, no intercept. Reuse its pieces
  (`SpendMeterFitter.span(endingAtStartOf:)` for the 14-day span,
  `capCounts` for scoped caps, `NNLS.swift`, `maxPairGap` = 1 h) and add the
  interval fit beside the hourly one; parity with the fixtures needs the
  interval form. Swapping in the app's hourly rates is possible but
  untested: score it in shadow before trusting it.
- **Spend.** `TokenSample` rows of the account (`accountId`, from
  `AccountActivation`), priced by `PriceLedger.cost(model:at:speed:geo:breakdown:)`
  and summed per family between two instants (`sampledAt`, exclusive start,
  inclusive end). The arena prices with the rates known at now; the app's
  `PriceLedger` is the same idea.
- **The live value.** `now_value` is **not** `LiveMeter.estimate`: no carry
  within the whole point, no held-tick guard, no tenths; just the reading
  plus converted spend since it, capped at 100. Keep the two apart, or the
  forecast and the live meter disagree in ways the fixtures will not catch.
- **Storage.** The cut table depends only on completed cycles and daily
  fits: rebuild it when a cycle resets or the local day changes (the model's
  own cache key), not per poll.

---

## The analog model (alternative)

Source: `models/g1-10-fable-analog/model.py` (`Model._meter`) and
`models/g1-10-fable-analog/analog.py`; settings in that folder's
`model.toml`. A deterministic restatement of the five-hour path is
`kit/detq.py` (`analog_query`, `analog_trajectories`, `analog_quantiles`).

**The idea.** Cut every complete past cycle of the same meter every few
minutes. Each cut records where the meter stood (level, recent rises, time of
day, weekday, phase of the cycle) and what happened after it, to its reset.
At `now`, weight every cut by how much it looks like now, and read the
forecast distribution off the weighted cuts' futures, re-based on the meter
now. Kernels and an effective-sample-size rule are the only machinery.

### Five-hour constants (`model.toml` `[config.meter.five_hour]`)

| name | value | meaning |
|---|---|---|
| `step_min` | 5 | cut every 5 min of each past cycle |
| `M` | 60 | a cut's future is stored at 60 points: fractions k/60 of the time it had left |
| `use_turns` | false | the day-model fallback ignores turns (below) |
| `shrink` | 0.85 | final dispersion shrink toward the median |
| `bw_phase_frac` | 0.08 | phase kernel bandwidth: 0.08 · W = 24 min |
| `bw_hour` | 2.5 | time-of-day kernel bandwidth, hours (circular, period 24) |
| `bw_rate` | 1.0 | recent-rise kernel bandwidth, in log1p(points) |
| `recency_days` | 120 | weight decays as exp(−age / 120 d), age = now − the cut's cycle reset |
| `other_account` | 0.3 | weight of another account's cycles (an "all accounts" view only) |
| `weekend_mismatch` | 0.5 | weight when exactly one of (cut, now) is a weekend day |
| `target_ess` | 30 | widen bandwidths until the effective sample size reaches 30 |
| `min_ess` (default) | 8 | below it, blend in the day-model fallback |
| `block_share` (default) | 0 | no day-model paths when ESS is enough |
| `bw_level`, `scale_alpha` (defaults) | 0 | level kernel and pace scaling are off |
| rate lags | 15 min, 60 min | `analog.meter_lags("five_hour")` |
| `max_cycles` | 400 | at most the latest 400 past cycles per account |

### Inputs

The account's readings of the five-hour window known at `now` (in the app:
every stored row; in the arena: `t_known <= now`, and `t_event >=` the
history start), and the device's UTC offset at `now` (`tz`, minutes; the
arena takes the latest turn's `tz_offset_min`, 0 when none is known). A row
is *active* when its state is active and `resets_at` is set; rows with a
null `util_pct` are dropped. Nothing else: no turns, no spend.

### The cycle now and the query (`kit/baselines.meter_now`, `kit/spend.current_cycle`)

1. The latest reading known at now (by `t_known`, then `t_event`) decides
   the cycle: if it is idle, its `t_event > now`, or its reset has passed,
   there is no current cycle (the arena then asks no five-hour question; the
   model's fallback is the request's own reset and level 0).
2. `reset` = that reading's own `resets_at` (no median: it jitters by
   milliseconds per poll); `start = reset − W`.
3. The cycle's readings: active rows with `|resets_at − reset| < W / 2`
   (`RateLimitCycle.contains`, never `==`) and `t_event <= now`, sorted by
   `(t_event, util_pct)`. `u` = the last one's util **as read** (a meter can
   fall inside a cycle, an allowance re-based under the same reset; never
   take a running maximum).
4. `step_at(t, util, x)` = util of the last reading at or before `x`, **0**
   before the first one.
5. Query: `e = now − start`; `remaining = reset − now`;
   `rates[j] = u − step_at(cycle readings, now − lag_j)` for lags 15 and
   60 min; `hour = ((now + tz·60000) mod DAY) / HOUR` (fractional);
   `dow = ((now + tz·60000) div DAY + 3) mod 7` (0 = Monday; floor division).

### The table of cuts (`analog.build_meter_table`, `kit/spend.past_cycles`)

Past cycles of each account in the view (only the account itself in a
scope-only view):

1. Take the active readings (sorted by `(t_event, util)`), order them by
   `resets_at` (stable), and split where consecutive resets differ by
   `>= W / 2`. A cycle's reset is the **median** of its readings' resets,
   truncated to an integer (`int(np.median(...))`: the mean of the two middle
   ones when the count is even, then truncated toward zero). Drop cycles whose
   reset is after `now`. Within a cycle, readings in `t_event` order.
2. Keep the latest 400 per account. A cycle is usable when its last reading
   is at or after `reset − max(HOUR, 0.2 · (reset − start))` (one hour for
   five-hour).
3. Cuts at elapsed `e ∈ {5 min, 10 min, …}` while `e < W − 5 min`, and
   `e >= t_first − start` (none before the cycle's first reading).
   For each cut, `x = start + e`:
   - `u0 = step_at(cycle, x)`;
   - `rates[j] = u0 − step_at(cycle, x − lag_j)`;
   - `hour`, `dow` of `x` as above; the account; `t_ref = reset`;
   - `D[k] = step_at(cycle, x + trunc(k/60 · (reset − x))) − u0` for
     k = 1…60 (`trunc`: the float product cast to int64).

### Weights (`analog.meter_weights`, `analog.widen_until`)

    g(d, bw)  = exp(−½ (d / bw)²)
    base      = (acct == now's ? 1 : 0.3) · exp(−(now − t_ref) / (120 d)) · (weekend(dow) == weekend(now's dow) ? 1 : 0.5)
    w(scale)  = base · g(e_cut − e, 24 min · scale) · g(circ(hour_cut, hour), 2.5 · scale)
                     · Π_j g(log1p(max(rate_cut_j, 0)) − log1p(max(rate_j, 0)), 1.0 · scale)
    circ(a,b) = min(|a − b| mod 24, 24 − |a − b| mod 24);   weekend(d) = d >= 5
    ESS(w)    = (Σ w)² / Σ w²

Start at `scale = 1`; while `ESS < 30` and fewer than 6 widenings,
`scale *= 1.5`. Use the last `w`.

### Quantiles (`kit/detq.analog_quantiles`)

Each cut becomes one trajectory on the request grid (`analog_trajectories`):

    fr(g)   = clip((g − now) / max(remaining, 1), 0, 1)
    fk      = [0, 1/60, 2/60, …, 1];  D' = [0, D[1], …, D[60]]
    p       = clip(searchsorted_right(fk, fr) − 1, 0, 59);  a = (fr − fk[p]) / (fk[p+1] − fk[p])
    inc     = D'[p] · (1 − a) + D'[p+1] · a
    inc     = inc >= 0 ? floor(inc + 1e-9) : ceil(inc − 1e-9)          (whole points, like readings)
    value   = clip(u + inc, 0, 100)

The model draws 200 cuts with probability `w / Σw` (with replacement); the
distribution those draws sample is exactly the weighted one, so its
quantile at level α, per grid time, is the **weighted type-1 quantile**:
sort the trajectories' values ascending (stable: ties in table order), sum
the normalized weights, and take the first value whose cumulative weight is
`>= α − 1e-9`. Then the dispersion shrink, applied to the quantiles (it is
monotone, so it commutes with taking them):

    med   = the weighted type-1 quantile at 0.5
    Q'(α) = clip(round_half_even(med + 0.85 · (Q(α) − med)), 0, 100)

`Q'` is the five-hour forecast. Its values are whole points. (The Python
model shrinks its 200 draws toward their *sample* median; when the weight
below an atom is within noise of 1/2 the two medians are adjacent whole
points, so its paths can sit one point from `Q'`. `Q'` is the limit the
draws estimate, and what a port should compute.)

### Edge cases

| situation | what happens |
|---|---|
| no current cycle (idle window) | no five-hour forecast; the app shows the reading (0) and the next-start question takes over |
| re-based meter (falls within a cycle) | `u` is the latest reading as read; a cut's `D` can be negative (rounded up toward 0) and the value is clipped at 0 |
| short history (few complete cycles) | bandwidths widen up to 1.5⁶ ≈ 11.4×; if ESS is still below 8, a share `1 − ESS / 8` of the paths comes from the day-model below |
| no complete past cycle (new account) | all paths from the day-model; with no hourly evidence at all, the pace fallback |
| `now` within 5 min of the reset | there are no cuts that late in past cycles (`e < W − 5 min`); the phase kernel and widening still find neighbours |
| the request's reset differs from the cycle's | the trajectories use the cycle's `remaining`; the grid ends at the request's reset (`fr` is clipped at 1) |

The fallbacks are simulations, not weighted quantiles (`exact: false` in
the fixtures):

- **Day-model** (`analog.meter_daymodel_paths`, also the whole weekly path):
  local days are active or idle (a two-state chain by weekday type), an
  active day's increments come from the account's own active days pooled with
  a lognormal prior, spread over the hours by an own day's shape or a default
  diurnal shape (`analog._SHAPE`). Constants (`cfg` defaults): `block_days`
  60, `active_pts` 2, `prior_p_weekday` 0.7, `prior_p_weekend` 0.35,
  `prior_days` 4, `mult_after_active` 1.25, `mult_after_idle` 0.6,
  `prior_total_n` 3, `prior_total_median` 12 points/day, `prior_total_sigma`
  0.9, `block_recency_days` 21, `block_bw_total` 1.0.
- **Pace** (`analog.meter_paths_pace`): a burst at rate
  `0.6 · r_recent + 0.4 · r_cycle` (points/hour; 2 when zero) times a
  lognormal(0, 0.7) factor, lasting Exp(mean 1.5 h), 50 % of paths idle when
  nothing rose recently (else 15 %), floored to whole points.

Port the fallbacks as written if the app should answer for new accounts;
their fixtures are Monte-Carlo (match within the given bounds, not exactly).
A simpler choice for the shadow phase: answer "not enough history" when
ESS < 8, as the shipping engine already does when it lacks support.

---

## Timestral-5M (alternative)

Source: `kit/fm/meter_model.py` (`MeterModel.meter_quantiles`),
`kit/fm/series.py` (`meter_series`, `resample_last`, `regular_grid`),
`kit/fm/paths.py`, `kit/fm/backends.py` (`TimestralBackend`), and the
vendored network `kit/fm/_vendor/timestral/` (Mistral AI, Apache-2.0 code,
commit `a534bdbd`). Weights: `mistralai/Timestral-5M` at revision
`bdd20cfc15a3fea0e4cb5ccef37f8d3ca7aa335f` (`model.toml`).

### Inputs and context

| window | step | context steps | context span | stale after |
|---|---|---|---|---|
| five-hour | 5 min | 144 | 12 h | 120 min |
| seven-day | 15 min | 288 | 3 days | 120 min |

1. **Cumulative burn** (`meter_series`): the meter's readings known at now
   (util not null/NaN), in `t_event` order. For each reading: if idle, it
   adds 0. If active, find the previous *active* reading: when there is none
   or its reset differs by `>= W / 2` this reading starts a cycle and adds its
   whole util; else it adds `util − previous util`. Negative additions become
   0 (a re-base adds nothing; burn counts again from the lower value).
   `cum` = the running sum. Never a running maximum of util.
2. **The meter now** `used`: the latest reading of the cycle whose reset is
   within `W / 2` of the request's `reset_at`, as read; if none, the latest
   active reading's util; else 0.
3. **Context** (`regular_grid`, `resample_last`): times
   `now − step · (n − 1 − i)`, i = 0…n−1 (oldest first, the last exactly
   `now`); each takes the `cum` of the last reading at or before it, or NaN
   when there is none or it is more than 120 min older.
4. If the last context value is NaN (no reading in two hours) or
   `used >= 100`: the forecast is flat at `min(used, 100)`, every level.

### The network call

`horizon = max(1, ceil((grid[-1] − now) / step))` steps. The arena calls
`TimestralForecaster.forecast(context[1, 1, T], prediction_length=horizon)`
with its defaults; what that does, in order (`forecaster.py`):

1. NaN → unobserved (mask), value 0; forward fill for the patch values;
   left-pad to a multiple of the patch size (32) with unobserved zeros.
   Five-hour: 144 → 160 (5 patches). Seven-day: 288 (9 patches).
2. `_forecast_raw` on the context and, **symmetric averaging**, on its
   negation; the result is `0.5 · (q + (−q_neg) reversed along levels)`.
   Each pass: causal per-patch location/scale (Welford running mean and std
   in float64, `minimum_scale` 1e-6, asinh squash), patch embedding of
   `[values, missing]`, an 8-block transformer (6 time-attention blocks, 2
   time-variate), `horizon_patches` forecast-query tokens, the quantile head
   (21 levels, made monotone by a softplus cumulative sum around the
   median, `quantile_width_factor` 3), denormalized in the last context
   patch's frame, then each later horizon patch re-framed
   (`_refine_block`, `scaler.advancing_block_frames`), and capped to
   `[ctx_min − k·s, ctx_max + k·s]` with `k = 1e4`.
3. **Non-negative clip**: the context is all non-negative, so quantiles are
   clamped at 0.

Output: `raw [horizon, 21]` at levels
`0.01, 0.05, 0.10, 0.15, …, 0.90, 0.95, 0.99`. One decode block covers up to
32 patches (1,024 steps), so every meter horizon here is a single block.
**The first patches do not depend on how many are decoded** (measured: the
first 40 steps agree to 3e-5, float32 rounding, between horizons of 40 and
700 steps), so a fixed-shape model can always decode the longest horizon of
its window and keep the first `horizon` steps.

### From the network's quantiles to the meter's (`meter_quantiles`)

    c_last  = context[-1]
    burn    = raw − c_last                                    [horizon, 21]
    burn    = running max over time of max(burn, 0); sort each row ascending
    (levels already include 0.01 and 0.99, so `extend_tails` adds nothing)
    burn    = sort rows(running max over time of max(burn, 0))  (idempotent here)
    burn    = [zeros(21); burn]                               rows at t_rel = 0, step, …, horizon · step
    meter_q[g, :] = clip(used + linear_interp(t_rel, burn, g − now), used, 100)   per level
    Q(α)    = linear interpolation in α over the 21 levels of meter_q[g, :]

The arena draws comonotone paths from these (`kit/fm/paths.to_paths`: path
i at level `(i + 0.5) / n` everywhere); the app needs only `Q`.

### Core ML conversion

A concrete path, in the order to try it:

1. **Freeze the reference.** In this folder, with the `fm` extra and the
   weights cached, load `TimestralForecaster.from_pretrained` on the pinned
   snapshot (`kit.fm.weights.local_snapshot`). Weights are float32, 20.8 MB,
   5,208,960 parameters.
2. **Cut the graph at the network.** Wrap, as one `torch.nn.Module` with
   fixed shapes and one series (`R = 1`, `group_ids = [0]`, no covariates):
   `TimestralModel._predict_context_only` from the *scaled* inputs onwards,
   i.e. inputs `scaled [1, T]` (float32, asinh-normalized) and
   `observed [1, T]` (bool), output the normalized head quantiles
   `[1, H·32, 21]` before `denormalize_quantiles`. Compute the masks and
   positions (`build_forecast_time_mask`, `build_two_stream_variate_mask`,
   `build_forecast_positions`) inside the module from `observed` with plain
   tensor ops; replace `torch.unique(group_ids)` by the constant `R = 1`
   answer. Keep the float64 causal statistics (`scaler.py`), the
   denormalization, `_refine_block`, the cap, the symmetric average and the
   clip **in Swift** (Double, Accelerate): Core ML has no float64, and they
   are a few hundred lines of arithmetic.
3. **Shapes.** Two models (or one with enumerated shapes):
   five-hour `T = 160` steps (5 patches), `H = 2` patches (60 steps to a
   full five hours); seven-day `T = 288` (9 patches), `H = 21` patches (672
   steps to a full week). Batch the two
   symmetric passes as `R = 2` only if the masks are re-derived for two
   groups; `R = 1` called twice is simpler.
4. **Convert** with `torch.jit.trace` then `coremltools.convert(...,
   convert_to="mlprogram", compute_precision=FLOAT32, minimum_deployment_target=macOS15)`.
   Check against the PyTorch module on the fixtures' contexts (`detail.context`)
   before anything else.
5. **Precision.** Ship float32 first (≈ 21 MB). Try `FLOAT16` (≈ 10 MB, can
   run on the Neural Engine) only if the fixtures still pass at the fp16
   tolerance below: inputs are asinh-normalized (order 1), but the head's
   softplus cumulative sums and the `sinh` denormalization amplify error in
   the tails.
6. **Latency.** PyTorch on one CPU thread (a heavily loaded machine):
   about 0.2 s per five-hour forecast and 0.1 s per weekly one, both passes
   included. Core ML on Apple silicon should be milliseconds; measure it,
   and in any case forecast at most once per poll.

**Licence to check.** The code is Apache-2.0. The weights are under
Mistral AI's *Modified MIT License* (the Hugging Face repo's `LICENSE`, read
2026-10-26 on `main`; **re-read it at the pinned revision**): broad
permission to use, modify and redistribute, with the copyright and
permission notice kept in all copies; the licence does not apply when the
company's (or the user's employer's) global consolidated monthly revenue
exceeds USD 20 million, which then needs a commercial licence from Mistral
AI; and this covers derivatives. A Core ML conversion bundled in Pacer is a
redistributed derivative: ship the notice with it (About, `LICENSE`
folder), and decide whether Pacer's distribution is affected by the revenue
clause before shipping beyond a shadow build.

**If conversion fails** (or the licence rules it out): nothing is lost;
v1 is spend-decay on both meters, and Timestral is only an alternative.

---

## The calibration layer

Source: `kit/calib.py` (`CalibModel`, `fit_kind`, `fit_scale`, `apply`),
wrapped as `models/calib-<base>/` for eight bases; v1 uses it on
spend-decay (`calib-spend-decay-30m`, `calib-spend-decay-6h`). **Port the
`scale` method**
(the default, and the only one the calibrated fixtures use). The layer
changes the spread of a forecast and never its median: Pacer shows the
median by default and the range on hover, so the point the user reads does
not move; only the honesty of the range does.

Why `scale`: on rolling forecasts over the visible tier's last weeks it was
the one variant that improved calibration without costing CRPS (see the
module docstring). The PIT remaps (`pit`, `both`) cannot widen a forecast
past its own range and chased its recent skew; separate factors below and
above the median chased its recent bias (a spread-only map cannot move the
median, so a few days of forecasts that ran high taught it a huge lower
tail). Both cost CRPS on the following days.

### What it learns, from what

- **Records.** The base forecaster's own past forecasts of the same meter,
  each made without seeing what followed, scored against the readings that
  arrived after its origin, in its cycle, up to its reset, as far as they
  are known now. Per stored forecast: its quantiles at 40 levels
  `(i + 0.5)/40` per grid time (`read_sorted` of its sorted paths), its
  lowest value (`floor`) and whether every value was a whole point
  (`whole`). A record is one reading: the forecast's 40 quantiles read at
  the reading's time (linear between grid times, flat before the first),
  the reading `y`, its lead (seconds since the forecast), and the
  forecast's `floor` and `whole`. At most 8 readings per forecast and lead
  bin, evenly spaced by index.
- **Origins.** In the arena: backtests every 2 h (five-hour) and every 8 h
  (seven-day and scoped caps), the latest 24 of each (12 for the two heavy
  bases), plus every forecast made during the episode. In the app: the base
  forecaster is deterministic given its inputs, so recompute it at past
  origins from the stored readings (no stored trail needed), or keep its 40
  quantile curves per forecast as it makes them.
- **Lead bins.** Five-hour (seconds of lead): `(0, 1800]`, `(1800, 7200]`,
  `> 7200`, centres 300, 3600, 11400. Weekly: `(0, 7200]`,
  `(7200, 86400]`, `(86400, 259200]`, `> 259200`, centres 600, 25200,
  151200, 396000. Each forecast origin counts once per bin: its records in
  the bin share a weight of 1 (`origin_weights`).
- **Randomized PIT.** From a record's 40 values `q` (sorted): `F(x−)` = the
  share of `q < x − 1e-6`, `F(x)` = the share `<= x + 1e-6`. The chance
  that the PIT falls at or below `a` (`below_share`): if
  `F(y) − F(y−) > 1e-12`, `clip(min(F(y), a) − F(y−), 0) / (F(y) − F(y−))`;
  else 1 if `F(y−) <= a + 1e-12`, else 0. This is the scorer's PIT (a tie's
  PIT spread uniformly over it): a flat forecast whose truth sits on it is
  calibrated at every level and does not pull the scale toward 0.
- **The scale at a knot** (`fit_scale`), for `c ∈ {0.5, 0.8, 0.95}`:
  1. `scaled(s)`: each record's values `m + s · (q − m)` (`m` = the
     record's median, the mean of its 20th and 21st values), clipped to
     `[floor, 100]`, rounded half to even when `whole` (what `apply` will
     do to the paths: the fit sees the clip at the meter's floor);
  2. `miss(s)` = the weighted mean over records of
     `below_share(scaled, (1 − c)/2) + 1 − below_share(scaled, (1 + c)/2)`;
  3. it only falls as `s` grows. If `miss(3) > 1 − c`: `s = 3`; if
     `miss(1/3) <= 1 − c`: `s = 1/3`; else bisection on `log s` in
     `[−ln 3, ln 3]`, 40 halvings, keeping the upper end (the smallest `s`
     that reaches the target).

  Records whose 40 values are all equal (within 1e-6) and whose reading is
  not on them are left out: no scale fixes a point that missed.
- **Shrinkage.** `n` = forecast origins with records for the window, `n_b`
  per bin. Fewer than 3 origins: no change at all. Pooled over bins:
  `log s = n/(n + 8) · log ŝ_pooled`. Bin `b`:
  `log s_b = n_b/(n_b + 8) · log ŝ_b + 8/(n_b + 8) · log s_pooled`; an
  empty bin takes the pooled value.

**Which coverage.** The target is the randomized coverage, the one the
PIT histogram (`pit_tv`) measures. The scorer's `cover50/80/95` count a
reading on an interval's end as inside, and a meter often sits exactly on
its forecast's floor (it did not move: about a fifth of readings on the
visible weeks), where many low quantiles coincide; a forecast calibrated in
the PIT sense then shows inclusive coverage above nominal, and the layer
moves it there. Judge it by `pit_tv` and CRPS, and read `cover*` with that
in mind.

### How it applies (`kit/calib.apply`)

Per grid time `g`, `lead = (g − now)/1000` s: each knot's `log s`
interpolated linearly in `log(max(lead, 1))` between the bin centres, flat
beyond the first and last. Given the child's values `P[i, g]` (paths, or
quantile curves):

1. Per column: `r` = mid-rank level of each value (ties averaged:
   `(average 1-based rank − 0.5)/n`), `c = |2r − 1|`, `m` = the column's
   median (mean of the two middle values when `n` is even).
2. `V = m + s(c) · (P − m)`, `s(c)` linear between the three knots and flat
   outside them; then rearranged: the k-th smallest child value gets the
   k-th smallest new value.
3. Shift the column by `m − median(V)` (the two middle paths sit either
   side of the median at central level 1/n, so they move by a hair).
4. If every child path is non-decreasing in time, every path that now falls
   anywhere is replaced by its least-squares non-decreasing fit (pool
   adjacent violators). If every child value is a whole number, round half
   to even. Clip to `[min of all child values, max(100, max of all child
   values)]`.

For the app, apply it to quantile curves: the child's quantile curves at
the 200 levels `(i + 0.5)/200`, treated as 200 comonotone paths, through
steps 1–4; the calibrated quantile at α is the sorted column read at
position `α · 200 − 0.5` (linear, clamped; `kit/detq.calib_quantiles`).
That is exactly what the calibrated fixtures hold.

### Refit and storage

- **When.** The arena refits at every forecast (milliseconds). In the app,
  refit when a new reading arrives for the window or at most hourly, and
  always after a reset (a cycle's records become final then).
- **Storage.** A fitted map is tiny: per window, 3–4 bins × 3 scales plus
  counts (`KindFit.to_json`). Keep it in memory with a copy in
  `ClaudeCodeMeta` (keyed by account, window, base model and layer version)
  so a relaunch starts calibrated; the records can always be rebuilt from
  the readings. A new base forecaster invalidates the map.

---

## Mapping to Pacer's data

Names from `PacerCore/Sources/PacerCore/`.

| arena input | Pacer source | notes |
|---|---|---|
| five-hour / seven-day readings | `RateLimitSample` (`sampledAt` → `t_event`, `window` ∈ `five_hour`/`seven_day`, `usedPercentage` → `util_pct`, `resetsAt`, `accountId`, `source`) | active ⇔ `resetsAt != nil`. Read through `LimitScope.rateLimitPredicate(account:since:)`: unscoped reads interleave accounts. Cycle membership through `RateLimitCycle.contains` (half a window), never `resetsAt ==`. |
| scoped weekly caps (e.g. Fable) | `UsageLimitSample` (`kind == "weekly_scoped"`, `identity`, `percent`, `resetsAt`, `modelDisplayName`, `accountId`) | the arena's `scope_model` is the model named in `identity` / `modelDisplayName` (`export/readings.py::_scope_model`). |
| older readings | `AccountUsageArchive` (rows archived after 35 days) | the exporter unions archive and live rows and keeps one per `(account, window, cap, t_event)`, the live one first; the analog model reads up to 120 days, Timestral at most 3. |
| `t_known` | — | the app knows a row when it writes it; use `sampledAt <= now`. The arena's `t_known` models only the replay. |
| `tz_offset_min` | `TimeZone.current.secondsFromGMT(for: now) / 60` | the arena takes the latest turn's offset; both are the device clock. Local hour and weekday use it, at `now` for the query and at each cut for the table (a DST change mid-history shifts old cuts by an hour, as in the arena). |
| account of a reading | `RateLimitSample.accountId` / `UsageLimitSample.accountId` | set by the poller from the token's organization; one meter per account. |
| spend (spend-decay) | `TokenSample` rows, priced by `PriceLedger.cost(model:at:speed:geo:breakdown:)` at the rate in effect at `sampledAt`, attributed to accounts by `TokenSample.accountId` (from `AccountActivation` intervals), summed per model family | spend-decay reads it; the analog five-hour path and Timestral read **no** spend. `<synthetic>` models are skipped (correctness rule 2); unpriced rows add nothing (null, never 0). The arena prices with the rates known at now; a price change re-prices history in both. |

**Where a shadow forecaster records.** Beside the engine's own trail, with
the engine's write policy (`UsageIntelligenceEngine.recordPredictionSnapshots`,
`shouldRecordSnapshot`: on change or heartbeat):

- `PredictionSnapshot`, one row per recompute per window: a distinct
  `surface` (for example `shadow-rl-five_hour` / `shadow-rl-seven_day`,
  qualified by account like the engine's), `method` naming base and layer
  (`arena-spenddecay-v1+calib` for v1; `arena-analog-v1+calib`, `arena-timestral5m-v1+calib`), `paramsVersion`
  for the layer's version, `periodKey` = the cycle's rounded reset (the
  same key the engine's rate-limit rows use, so shadow and engine join on
  `(periodKey)`), `value` = the median at the reset, `lo50/hi50` and
  `lo80/hi80` = the calibrated quantiles at the reset, `usedPct`,
  `crossingAt` from the median path crossing 100, `support` = the analog
  model's ESS (or origins behind the map), `bandStratum` = the lead bin.
- `ForecastModelOutcome` once a cycle completes (`modelId` as above), so
  the scoreboard compares shadow and shipping models on the same cycles.

Retention is the snapshot table's (180 days); nothing else needs storing.

---

## Parity

The fixtures in `findings/2026-10-port/fixtures/` come from
`arena port-fixtures` (`arena/cli_portfix.py`) on a synthetic snapshot only
(`arena synth --out port-fixtures --seed 42`), so they hold no real usage.

### Files

- `cases.json`: `{format, spec, snapshot, seed, keepalive_min,
  weekly_grid_step_ms, cases: [...]}`. Each case:
  - `id`;
  - `inputs`: `account`, `window_kind`, `scope_model`, `history_start`
    (rows with `t_event` before it are not seen), `tz_offset_min`, and
    `readings` as columns `t_event`, `t_known`, `util_pct` (null: unknown),
    `resets_at` (null: idle), `state` (`active` | `idle`): the account's
    readings of that window from `history_start` to `now`, thinned (a row is
    kept when its value, state or cycle changes, at least hourly, and the
    first and last). Every output below was computed from **these rows
    only** (a snapshot reduced to them), so they are exact for them;
  - `request`: `key`, `target` (`meter.five_hour` | `meter.seven_day`),
    `account`, `now`, `reset_at`, `grid` (epoch ms; five-hour: +30 s, +1,
    +2, +3 min, then every 5 min to the reset; weekly: +1, +5, +15 min, then
    every **2 h** to the reset, coarser than the arena's 30 min to keep the
    files small; models must not assume an even step).
- `cases-spend.json`: the same shape for the spend models' 12 cases
  (`s00`…`s11`, five-hour and weekly alternating; weekly histories 12 days
  so past weekly cycles exist), whose `inputs` also carry `turns` as columns
  `t_event`, `t_known`, `family`, `cost_micro_usd`: the account's spend
  known at now, priced as the arena prices it (rates known at now, best
  output), as **one pseudo-turn per model family per 5 minutes** (the
  bucket's last `t_event`, its latest `t_known`, the summed cost rounded to
  a micro-dollar). The outputs were computed from these pseudo-turns, so a
  port feeds them to its spend sums as they are (`cost_micro_usd · 1e-6`
  dollars at `t_event`) and skips pricing; `kit.spend` reads nothing else
  from turns. `spend_bucket_ms` says the bucket.
- `<model>.json` for `spend-decay-30m` and `calib-spend-decay-30m`
  (five-hour cases of `cases-spend.json`), `spend-decay-6h` and
  `calib-spend-decay-6h` (weekly ones), and, on `cases.json`,
  `g1-10-fable-analog`, `fm-timestral-5m-meter`,
  `calib-g1-10-fable-analog`, `calib-fm-timestral-5m-meter`:
  `{format, spec, model, snapshot, seed, outputs: [...]}`, one output per
  case:
  - `levels` `[0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 0.95]`;
  - `quantiles` `[7][G]` (rows are levels) and `median` `[G]`;
  - `exact` (true: reproducible to float precision; false: a Monte-Carlo
    estimate from `mc_paths` paths) and, when not exact, `mc_bounds.lo` /
    `mc_bounds.hi` `[7][G]`: the same estimate at each level ∓ 4√2
    standard errors of an n-path quantile;
  - `detail` (floats to 6 decimals, except `fit`, which is stored at full
    precision because a port applies it as is): spend-decay: `mode`
    (`cases` | `lognormal` | `flat`), `latest`, `latest_t`, `start`,
    `reset`, `rates` (points per dollar per family, FAMILIES order),
    `weak`, `r2`, `state` (`now_value`, `burn` per ms, `ratio`, `used`),
    `u_now`, `tau_h`, `centre` (the centre path on the grid), `n_cases`,
    `picked`; analog: the query (`u`, `elapsed_ms`, `remaining_ms`, `rates`,
    `hour`, `dow`, `tz_ms`), `table_rows`, `table_cycles`, `ess`,
    `bw_scale`, `shrink`, `shrink_median`; Timestral: `used`, `step_ms`,
    `horizon_steps`, `context` (the context vector, null = NaN), `flat`,
    `levels_ext`, `raw_levels` and, for five-hour cases, `raw` (the
    network's output `[horizon][21]` after symmetric averaging, cap and
    clip); calibration: `fit` (the map in force, `KindFit` JSON) and
    `child_exact`.
- `calib-*.json` also carry `fit_parity` (for v1: `calib-spend-decay-*.json`): per window kind, the layer's
  records at one case's `now` (`q [N][40]`, `y`, `lead_s`, `origin`,
  `floor`, `whole`, rounded to 4 decimals) and the map each method fits from
  exactly those rounded records, at full precision (`fits.scale` is the one
  to port), with `n0`, `n0_bin`, `min_origins`, `s_max`.

### Tolerances

| check | tolerance |
|---|---|
| spend-decay `rates`, `state`, `tau_h`, `centre`, `n_cases`, `picked`, `mode` | to the 6 decimals stored (counts and choices exactly) |
| spend-decay quantiles (all `exact: true`) | `1e-6` (type-1 boundaries as for the analog model) |
| analog query features, `table_rows`, `table_cycles`, `ess`, `bw_scale` | to the 6 decimals stored (counts exactly) |
| analog five-hour quantiles (`exact: true`) | equal (whole points). A level whose cumulative weight lands within 1e-9 of a jump may take the neighbouring value; report such points rather than loosen the rule |
| Timestral `context` | equal, NaN in the same places |
| Timestral `raw` vs the converted network | float32: `|Δ| <= 1e-3 · max(1, |x|)`; float16: `1e-2 · max(1, |x|)` |
| Timestral meter quantiles from the fixture's own `raw` | `1e-6` (pure arithmetic) |
| Timestral meter quantiles end to end | the `raw` tolerance carried through (about 0.01 points in float32) |
| calibration map from `fit_parity` records | `s` to 1e-9 relative (`fits.scale`, stored at full precision; the bisection is deterministic) |
| calibrated quantiles from the fixture's `fit` and the port's own child quantiles | `1e-6` plus the child's tolerance |
| any `exact: false` output | the port's own estimate with `>= mc_paths` paths inside `mc_bounds`; allow up to 0.5 % of (level, grid time) points outside, the price of two independent random streams |

### How a Swift test uses them

1. Decode `cases.json` and each model file (Codable structs mirroring the
   keys above; times as `Int64` ms).
2. For each case, build the reading array the forecaster takes
   (`t_event` → `sampledAt`, `util_pct`, `resets_at`, `state`) and, for
   spend cases, the spend array (`t_event`, family, dollars); keep rows
   with `t_known <= now` and `t_event >= history_start`, and set the time
   zone offset to `tz_offset_min` (not the test machine's). The Python
   reference consumer is `arena.cli_portfix.snapshot_from_case` (run spend
   models under `fixture_pricing`).
3. Run the port at `now` on `grid` with `reset_at`; compare intermediates
   first (`detail`), then `quantiles` and `median`, with the tolerances
   above. For the calibrated models, take the child's quantile curves from
   the port's own child, apply `detail.fit`, and compare; separately, refit
   from `fit_parity` and compare the maps.
4. Keep the fixtures read-only in the test bundle; regenerate them only
   with `arena port-fixtures` (from `research/arena`, with the `fm` extra):

       uv run arena synth --out port-fixtures --seed 42
       uv run --extra fm arena port-fixtures --snapshot port-fixtures --seed 42 --cases 20 --spend-cases 12 \
           --model spend-decay-30m,spend-decay-6h,calib-spend-decay-30m,calib-spend-decay-6h,g1-10-fable-analog,fm-timestral-5m-meter,calib-g1-10-fable-analog,calib-fm-timestral-5m-meter \
           --out findings/2026-10-port/fixtures

---

## Open questions

Things this spec could not settle, roughly in the order they will bite:

0. **Spend-decay on the app's own fit.** The arena's spend-decay used the
   interval, per-family, no-intercept conversion; the app stores an hourly,
   per-model fit with an intercept (`SpendMeterFit`). Parity needs the
   interval form; whether the app's fit forecasts as well is untested.
   Likewise its spend: the arena prices every turn with the rates known at
   now, the app with `PriceLedger` (the same idea; a catalog gap would make
   a cost null in both, and silently zero in neither).
1. **Does the layer help where it matters?** The round-1 winners' ranges
   were too wide on the lockbox weeks; on the visible weeks, where the layer
   was validated (the lockbox is never run outside the coordinator), the same
   bases were about right or too narrow, and the layer mostly widened them:
   the PIT got flatter for most bases with CRPS unchanged within noise. It
   adapts to whatever the last days' backtests show, but its effect in the
   over-wide regime is untested. The prospective re-run (`RUNBOOK.md` §6)
   with the `calib-*` models answers this before the app shows a calibrated
   range.
2. **Core ML tracing of the masks.** `build_forecast_time_mask`,
   `build_two_stream_variate_mask` and `group_first_observed_patch` use
   boolean indexing and `torch.unique`; whether they trace and convert as
   written is unverified. If not, compute them in Swift and pass them in as
   inputs (they depend only on the observation mask).
3. **float32/float16 parity of the network** is untested; the tolerances
   above are targets, not measurements. The `sdpa_sigmoid` gated attention
   may not map to the Neural Engine.
4. **Licence.** Read Mistral AI's terms at the pinned revision, and decide
   for Pacer's distribution the revenue-threshold question; the arena only
   checked `main` on 2026-10-26.
5. **Type-1 boundaries in the analog model.** A cumulative weight within
   1e-9 of a level is resolved by summation order, which Swift may not
   reproduce bit for bit; the fixtures may contain none, so a port can pass
   them and still differ on rare live cases by one whole point at one level.
6. **The cycle reset as a truncated median** (`int(np.median(...))`) in the
   table of cuts: odd-looking, but it is what the model was scored with; a
   port that "fixes" it shifts every past cycle's phase by up to half a
   millisecond (harmless) — keep it for parity.
7. **Clock and time zone.** The arena uses the latest turn's UTC offset
   for every cut; across a DST change the app should do the same (one
   offset, the current one) to match, even though per-cut offsets would be
   more correct.
8. **Fallbacks.** The analog model's day-model and pace fallbacks are
   simulations matched only within Monte-Carlo bounds; for a shadow build,
   "not enough history" (ESS < 8 or no complete cycle) is simpler and loses
   little: the five-hour analog fixtures here are all exact.
9. **Staleness in the app.** Timestral returns a flat forecast when the
   newest reading is over two hours old (`stale_min`), as after the Mac
   sleeps. The shipping engine has its own rule there; pick one for the
   shadow comparison, or the two will be scored on different cases.
