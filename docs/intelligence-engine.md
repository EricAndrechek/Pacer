# The usage-intelligence engine

*Last rewritten overnight 2026-06-11 → 06-12. This is the reference for how
Pacer's predictions work, why they work that way, and what the evidence is.
Read this before touching anything under `PacerCore/Sources/PacerCore/Forecast/`.*

## What problem this actually is

Per-user, on-device forecasting of one person's Claude usage from **tiny,
violent data**: ~50 active days (gaps are real $0 days), a 269× day-to-day
cost spread ($5–$1,394), a 7× weekday/weekend activity regime, a strong
diurnal shape, ~80 completed 5-hour rate-limit cycles, ~5 seven-day cycles,
and exactly **one** historical cap-hit.

In the literature this is **"lumpy" intermittent demand** (Syntetos–Boylan–
Croston taxonomy) — except the zeros are calendar-predictable (weekends), so
the right frame is a *seasonal hurdle* process; the intraday question is
**"intraday updating"** from call-center forecasting / **"pickup"** from
revenue management; the rate-limit question is **first-passage estimation**
for a monotone cumulative process. The M4/M5 competition lessons apply
directly at this N: simple methods win, *combinations beat selection*, and
shrinkage/pooling beats per-cell fitting.

What this is **not**, at this data size: an ML problem. Gradient-boosted
trees, random forests, ridge/lasso/quantile regressors all lose to trivial
baselines here (measured three separate times). CreateML earns a seat at the
table at roughly 6+ months of history, via the scoreboard (below), where it
can only ever win its way in — never regress a user.

## Architecture: one engine, thin views

`UsageIntelligenceEngine` (a `@ModelActor` with its own `ModelContext`) is the
**single prediction authority**. It owns the whole dataset, refits per-user
models on each scan tick (throttled ≥20s; a full refit is ~0.5s off-main),
and answers typed questions. Views never compute forecasts and never pass
data in — they `ask` and render `Estimate`s (point + calibrated bands +
method + confidence + support), refreshing on `.pacerEngineDidRecompute`.

Surfaces wired to the engine: the hero strip's burn rows, the live-activity
projected-EOD tile, the monthly card's projection, the pace charts' forecast
overlay + compare-models sheet, the burn-rate notifications, and the
Usage-intelligence card.

```
store ──► EngineFeatures (pure builder: daily/hourly series, cumulative
          day curves + cached per-hour costs, rate-limit cycles,
          [7][24] P(active) activity grid, last-arrival)
      ──► self-eval: score newly-completed periods into EngineEvalOutcome
          (idempotent; one fetch per refit, sliced in memory)
      ──► selection from the record (pools per cut; per-window RL pick)
      ──► makeFit: calibrators + rosters + frequency facts
      ──► ask(...) → Estimate   /  burnOutlook(...)  /  trajectories(...)
```

## End-of-day cost

**Candidates** (`EngineSelfEval.eodCandidates`):
- `average-rate` — clock-linear pace (`soFar ÷ fraction-elapsed`). The
  baseline that's genuinely hard to beat before evening.
- `regime-gated-eod` — EB-shrunk weekday/weekend hour-of-day cumulative
  shape. Strong once most of the day is observed.
- `additive-pickup` — `soFar + median historical remainder` for the day-type
  (regime-matched, pooled fallback). The revenue-management answer to early
  -day ratio instability: both other methods *divide* by a small early
  denominator and amplify noise 3–4×; pickup *adds* a stable remainder.
  Validated: ~53% vs clock's ~88% at 6am; ~10% at 6pm; ~0% at 9pm.

**Point = median of the cut's trimmed pool** (combination over selection,
the M4 lesson): at each of six cut fractions, the candidates whose per-cut
record on *this user* is within 25% of the best — computed over a trailing
30-scored-day window (drift insurance: the all-time record let the shape,
strong in week-one mornings but weak in the current regime, re-enter morning
pools and drag the median). Cold start = median of everything.

**Band = `RemainderConformal`** — the rebuild's statistical centerpiece.
Nonconformity score `s = (final − spend) / R̂` with `R̂ = max(point − spend,
5%·point)`, one score per (day, cut), never pooling correlated within-day
residuals; asymmetric one-sided quantiles (the right tail is long); scores
are nonnegative by construction so **the band can never dip below
spend-so-far** (the old pooled multiplicative band could — a correctness bug,
not just width). Result on the real store: evening width/point fell ~2.8× →
~1.1 (6pm) and ~0.3 (9pm) at honest coverage, while dawn bands honestly
widened (the pooled band was secretly under-covering there, 0.64).

The **idle/done gate** still applies on top: when the rest of the day is
typically idle (activity grid) and nothing has arrived recently, hold at
spend-so-far.

Full-pipeline replay (last 22 days, leak-free): per-cut 80%-band coverage
0.73–0.95 (all within Beta noise of 0.80 at n=22); point medians ≈ clock at
morning cuts and far better from mid-afternoon on. Morning point error
(~40–50%) is a property of the 269× data, not a fixable modeling gap — the
arrival-count lever the earlier research hoped for was a measured null.

## Month-end cost

`MonthlyProjector` — forecast the *daily* series (recency-weighted, EB-shrunk
per-weekday means, zero-filled gaps; trend deliberately OFF) and sum.
Eligibility-gated with a flat-average fallback. Unchanged this rebuild apart
from presentation; its variance-sum band is the one remaining non-conformal
band (honest monthly conformal needs more complete months — revisit at ~5).

## Rate limits

- **Selection**: per-window roster (four simple curve fits + `DiurnalBurnModel`
  for 7d) picked from the persisted record (`bestMethod`), cold-backtest only
  when the record can't decide. The diurnal model — weekday×hour accrual shape
  EB-shrunk toward the activity-grid prior, one fitted level scalar —
  genuinely wins the 7-day window (23% median error vs 26–91%) and is
  load-bearing **only with the real activity grid**.
- **Bands**: stratified additive conformal, {early,late}×{weekday,weekend},
  pooled fallback under 10 scores. Early-weekday coverage moved 0.64 → 0.80.
- **`burnOutlook`**: descriptive recent slope + the selected model's first
  pre-reset 100% crossing, plus **earliest/latest plausible crossings** from
  the band-shifted curves (monotone inversion: P(hit by t) = P(U(t) ≥ 100)),
  plus natural-frequency facts (cycles observed / peak ≥90% / hit-100%).
  On the live store the night this shipped: at 84% of the 7-day window the
  old linear math said "cap at 5:28am" (overnight — when nothing ever burns);
  the diurnal model said Friday evening. That class of correction is the
  engine's whole point.
- **Warnings**: engine recompute is sequenced before the check; the crossing
  must hold for **two consecutive refits** (debounce), plus the existing ≥50%
  used floor and per-cycle dedup. P(hit) is never displayed as a precise
  number — one historical hit makes that unvalidatable; frequency counts only.

## The self-improving loop

Every completed period is scored once per candidate into `EngineEvalOutcome`
(`(surface, method, cut-bucket, period)` → predicted + truth; idempotent).
Selection — EOD pools, RL picks — reads the accumulated record, so the engine
*converges on whatever actually works for this user* and adapts when their
regime shifts. Nothing trained on any other user ships; the only shared
numbers are generic statistical bars (pool tolerance, minimum support).

Three layers close the loop end-to-end (2026-07):

- **Prediction trail** (`PredictionSnapshot`): every displayed answer is
  recorded with its band, conformal stratum + residual count, anchor shift,
  live state, and version tags — change-at-display-precision writes with a
  30-min heartbeat, 180-day retention, exported at
  `GET /v1/predictions/history`. The eval table says how methods did; the
  trail says what the user was actually shown, and why.
- **Versioned knobs** (`EngineParams`): all tuning constants live in one
  struct whose `versionTag` is derived from the values (FNV over a canonical
  string, bit-identical to the Python harness). The app never mutates its own
  parameters; changes arrive as reviewed code and re-tag the trail
  automatically.
- **Shadow candidates**: new models (`kalman-trend` everywhere, the diurnal
  model on 5h) score into the record from day one but can't be displayed
  until they clear `shadowPromotionMinPeriods` completed periods AND win on
  realized error — display is earned, never granted to a lucky thin record.
  Cold-start selection skips shadows entirely.

The tuning loop itself lives out-of-app in `research/harness` (Python/uv):
a walk-forward replay of this whole pipeline over the real store (~1s for
all history) scoring point error, **80%-band coverage**, pinball, and Brier,
plus a deterministic grid sweep whose adoption rule is the hysteresis — a
knob change is recommended only when fold-robust (≥3 of 4 time folds, ≥5%
median improvement, coverage within [0.70, 0.92]). First run (2026-07-06):
5h bands are honest (coverage 0.785 on 1032 cases); 7d bands under-cover
(0.589 on 70 cases) — a cycle-count problem, not a knob problem.

## Presentation rules (the research, distilled)

Uncertainty communication follows the weather/fintech evidence: a
plain-language pace sentence; a **gated** hero (no dollar projection until
half the day is observed and the band ≤2.5× the point — early-day shows
spend-so-far + pace instead); asymmetric anchors ("at least … could reach …"),
never a bare symmetric interval; natural-frequency risk copy ("topped 90% in
3 of 73 cycles — hit the cap 1×"), never fitted tail probabilities; counting
statements for anomalies; 2-significant-figure display with outward-rounded
bands; red reserved exclusively for a projected pre-reset cap hit; **no
next-day dollar number anywhere** (~60% APE for every method — the
battery-time-remaining lesson); the footer states the engine's *earned*
evening accuracy from its own record.

## Honest limits & the roadmap

- Morning point accuracy is data-limited. Don't chase it; the gate handles it.
- Monthly bands: conformal once ~5 complete months exist.
- Recency-weighted conformal calibration (Barber et al. weighted quantiles)
  is the principled next step if coverage drifts during regime changes; an
  online coverage tracker (P-control on alpha) is the safety net to add with it.
- CreateML tabular candidate joins the EOD roster via the scoreboard at ~6
  months of data.
- 5-hour window: diurnal structure was a measured null in 2026-06 (too short
  to straddle day/night) — now re-tested continuously as a promotion-gated
  shadow candidate instead of trusted forever. Cap-hit early-warning there
  has an information wall (44→100% in 12 minutes once observed); that one IS
  impossible, don't rebuild it.
