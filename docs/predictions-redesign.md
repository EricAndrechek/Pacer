# Predictions redesign — slope/acceleration warnings + 2nd-derivative estimates

> Status: **planned, not started.** Parked here so a fresh session can
> pick it up cold. Owner decision still open (see "Open decision").
> Originating idea: Pacer's projections feel less sensible than Claude
> God's because they extrapolate the *current slope* only; Claude God's
> daily-total estimates look better because they account for the second
> derivative (acceleration), and ideally would self-learn on personal
> usage patterns.

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
