# Predictions redesign — slope/acceleration warnings + 2nd-derivative estimates

> Status: **shipped 2026-06-10** (PRs #46, #47, #48). See "Outcome" below
> for what actually landed and the key finding — which overturned the
> original plan. The sections after Outcome are the original design note,
> kept for context.
> Originating idea: Pacer's projections feel less sensible than Claude
> God's because they extrapolate the *current slope* only; Claude God's
> daily-total estimates look better because they account for the second
> derivative (acceleration), and ideally would self-learn on personal
> usage patterns.

## Outcome (shipped 2026-06-10)

**Key finding — the original premise was wrong.** Validated on Eric's real
store (read-only copy, Apr–Jun 2026), the damped 2nd-derivative estimator
does **not** beat Pacer's naive displayed projections, and the acceleration
term actively *hurts* on this data:

- End-of-day: naive median error 20%; the estimator (any knob setting) 27–31%.
  Acceleration raised both error and the overshoot tail. Spend is
  session-based and tapers in the evening — no derivative knows the day ends.
- Monthly: a wash (~60% mid-month error either way; bursty weekday/weekend).
- 5-hour burn: only ~1 in 17 climbing windows ever hits 100% — rarely actionable.
- 7-day burn: the estimator beats the shipped 90-min-lookback linear
  (precision 25%→30%, ETA less-early), but mostly because 90 min is absurd
  for a weekly trajectory; a longer lookback gets most of it.

What **does** beat naive is the user's own empirical rhythm (the "self-
learning lite" option 2), so that's what shipped for the displayed numbers:

| Piece | What shipped | PR |
|---|---|---|
| **Shared estimator** | `TrendEstimator` — recency-weighted slope + damped *and clamped* acceleration (a least-squares parabola's endpoint slope reverses on "ramp-then-flat", so slope comes from a linear fit; curvature is fed forward only as a bounded, saturating bend). Pure, 15 tests. | #46 |
| **7-day burn warning** | `BurnRate.projectRecencyWeighted` (estimator, weekly lookback, **acceleration off** — it didn't help and added false alarms) returns the same `Projection` shape so 5h+7d share one warning path. The shipped 5h **linear** path is unchanged. | #47 |
| **End-of-day projection** | `ActivityProfile` hour-of-day shape: scale spend-so-far by "you've usually done X% by now", blended with naive early in the day. p90 error 89%→68%. | #48 |
| **Monthly projection** | `ActivityProfile` day-of-week weights reshape the remaining-days projection. Mean error 59%→48%. | #48 |

**Not done / deliberately deferred:**

- The **displayed** 5-hour rate-limit ETA tile (`HeroStripCard`) is unchanged
  (linear `BurnRate.project`) — on this data the estimator gives no benefit
  for the short window, and it's a shared displayed surface.
- Real Core ML — out of scope, as planned.

**Done after the initial pass:** the **displayed** 7-day pace tile
(`HeroStripCard`) now also uses `projectRecencyWeighted` (#50) over a 3-day
query, so it matches the 7-day warning's data + math — they can no longer
disagree. The 5-hour tile stays linear.

The acceleration term lives in `TrendEstimator` (built, tested, clamped) but
no shipped surface uses it; it's available if a future signal proves it out.

## Why now

Every projection Pacer shows today is a naive first-derivative
extrapolation. Each is individually reasonable but they share the same
blind spot — they assume the most recent rate continues flat, so they
overshoot during a ramp-up and undershoot during a wind-down, and none
of them know that you don't code at 3am or on Sundays.

The three live surfaces:

| Surface | Where | Current math | Failure mode |
|---|---|---|---|
| **End-of-day cost** | `App/Views/LiveActivityCard.swift` → `projectedEndOfDay` (~line 132) | `todaySoFar + costLastHour × hoursLeftInDay` | Mid-ramp it multiplies a hot last hour across the whole evening → wild overshoot. After you stop, last-hour rate ≈ 0 so it collapses to "today so far" (OK-ish). Ignores time-of-day shape. |
| **Rate-limit ETA** | `PacerCore/.../RateLimit/BurnRate.swift` → `BurnRate.project` | First-to-last linear slope over a 90-min lookback → time to 100% | An early spike in the 90-min window tilts the whole slope; no recency weighting; no acceleration term, so a ramp reads too slow and a taper too fast. Consumed by `HeroStripCard` + pace widgets. |
| **Monthly total** | `PacerCore/.../Forecast/MonthlyForecast.swift` → `compute` | `monthSoFar + avgDailyCost × daysRemaining` (avg over days-with-data) | Flat average ignores trend and weekday/weekend shape; a heavy first week projects a heavy month even if you always taper. Consumed by `MonthlyForecastCard`. |

## The plan

Build **one** pure, tested estimator in `PacerCore` and feed it to both
a new warning and (after sign-off) the three projections. Don't fork the
math per surface — one source of truth, same way `PaceBand`/`BurnRate`
are shared today.

### 1. Shared trend estimator (the foundation)

A pure function over a `(time, value)` series that returns **level,
recency-weighted slope, and a damped acceleration term**:

- **Recency-weighted slope** — weight recent samples more (EWMA of slope,
  or weighted least-squares with an exponential kernel). This alone fixes
  most of the "an old spike distorts the line" problem and implicitly
  bends the projection toward what's happening *now*.
- **Damped acceleration (the 2nd derivative)** — estimate Δslope and
  extrapolate with it, but **decay the acceleration over the horizon** so
  a quadratic doesn't explode ("at this acceleration you'll spend $40k by
  midnight"). Concretely: project with `slope(t) = slope₀ + accel₀ ·
  e^(−t/τ)` style damping, or cap the acceleration's contribution to a
  fraction of the linear term. The damping constant τ is the main knob to
  tune against real data.

Keep it source-agnostic and `Date`-free internally (take `now` as a
param) so it unit-tests like `BurnRate`/`MonthlyForecast` do. Put it in
`PacerCore/Sources/PacerCore/Forecast/` (or `RateLimit/` if it ends up
rate-limit-shaped). Mirror the `BurnRate.Sample` value-type pattern.

### 2. Acceleration warning (new feature — lower risk)

A new alert that fires on the **second derivative**, not the level:
"you're not just ahead of pace, you're *accelerating* toward the cap."
Distinct from the existing `PaceBand` (which is level-vs-linear-pace).
Trigger when acceleration is strongly positive AND the damped projection
crosses the limit before the window resets. This is genuinely new
surface, so it has more latitude than changing displayed numbers — but
still agree thresholds before shipping. Wire through
`NotificationCoordinator` + a `PacerSettings` opt-in, same shape as the
other alerts (and the new `notifyGlobalReset`).

### 3. Personal pattern shaping (optional, "self-learning lite")

For end-of-day and monthly, weight *remaining time* by the user's own
empirical **hour-of-day** and **day-of-week** activity profiles built
from `HourlyAggregate` / `DailyAggregate` history — e.g. "you typically
do 70% of a day's spend by noon" scales the remaining-day projection
instead of flat clock-hours-left. This is the "self-learning on patterns"
ask in a simple, debuggable, non-ML form. Real on-device ML (Core ML)
stays a *later* step — empirical profiles get ~90% of the value with none
of the model-lifecycle cost.

## Constraints / process

- **Predictions are a shared, displayed surface.** Per the standing rule
  (see `memory/feedback_show_evidence_protect_shared_views.md`): do NOT
  silently swap the displayed projection math. Prototype new-vs-old **on
  real data, render before/after**, and get sign-off before changing
  `HeroStripCard` / `LiveActivityCard` / `MonthlyForecastCard` / widgets.
- The estimator + acceleration warning can be built and proven first
  (they don't alter existing displayed numbers); swap the displayed
  projections in a second, sign-off-gated step.
- Reuse, don't duplicate: `BurnRate` already owns lookback/slope plumbing
  and has tests — the new estimator should likely subsume or sit beside
  it, not parallel it.

## Open decision (asked, deferred)

How far to go in the first pass:

1. **Damped 2nd-deriv estimator + warning + swap all three projections**
   (recommended — the direct "2nd derivative now" path).
2. Same, **plus** personal time-of-day/day-of-week shaping.
3. Estimator + warning **only**; leave displayed projections untouched
   until the estimator is proven in the wild.

Owner deferred the choice to the session that picks this up. Default
recommendation if still unspecified: option 1, with the before/after
shown before the displayed swap.

## Files to touch

- New: `PacerCore/Sources/PacerCore/Forecast/TrendEstimator.swift` (+ tests).
- `PacerCore/.../RateLimit/BurnRate.swift` — fold into / call the estimator.
- `PacerCore/.../Forecast/MonthlyForecast.swift` — use the estimator + optional pattern shaping.
- `App/Views/LiveActivityCard.swift` — `projectedEndOfDay` → estimator.
- `App/Notifications/NotificationCoordinator.swift` + `App/Views/SettingsView.swift` + `PacerCore/.../Settings/PacerPreferenceKeys.swift` — acceleration-warning opt-in (mirror `notifyGlobalReset`).
