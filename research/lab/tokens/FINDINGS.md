# What moves the meter (2026-10-20, owner's store)

Reading intervals (consecutive meter readings of one cycle) regressed on what
was spent in between; fit on the first 70% of time, scored hour by hour on the
rest (`pricing_vs_meter.py`, `meter_from_tokens.py`, `factor_over_time.py`).

- **Spend explains the meter almost completely.** Hourly out-of-sample R²
  0.96 pooled on the 5-hour meter, 0.97 on the weekly one.
- **API-equivalent cost vs raw tokens.** One cost→% factor per account matches
  or beats 25 token weights on the 5-hour meter where data is plentiful (busiest
  account: cost 0.964 vs tokens 0.863; pooled 0.961 vs 0.962). On the weekly
  meter tokens do better (pooled 0.973 vs 0.892), and per-model factors on cost
  recover most of that (0.958).
- **Per-model drain.** Pooled, Fable 5.1 moves the weekly all-models meter
  ~2.5× more per dollar than average (consistent with its own weekly cap);
  Opus 5 ~0.5×. But models were used in different weeks, so model and period
  are confounded (next point).
- **The factor drifts over time, ±30%.** Busiest account, points of the 5-hour
  meter per API $: 0.18–0.25 in May–July (Opus 4.7/4.8), 0.11–0.14 in August
  (Opus 5 — the most generous stretch), 0.16–0.20 late Sept–Oct (Opus 5.5). It
  also rose within the Opus 5 weeks, so it isn't the model alone. The weekly
  meter consistently equals ~4–5 five-hour windows of spend.
- **Time of day / weekend.** No robust off-peak generosity. On the busiest
  account 21:00–03:00 local moved the 5-hour meter 20–30% MORE per dollar, but
  hour factors don't improve the out-of-sample fit. Weekends: ~25% cheaper per
  dollar on two smaller accounts, no different on the busiest. Not reliable
  enough to model.
- **Consequence for forecasting:** convert spend to meter points with a factor
  recalibrated on recent data and on the cycle so far (`tok-rate-*-cal`,
  `tok-decay-*`), which is where the token models' gain comes from.
