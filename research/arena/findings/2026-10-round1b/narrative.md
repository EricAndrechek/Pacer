## The short version

Round 1 ranked about 130 forecasters, but its lockbox had few five-hour cases and one cluster of models looked better than it was. Round 1b is the decisive re-run: the same hidden final weeks, a new seed (13), many more cases, and only the models that mattered. It confirms that **several models beat what Pacer ships by about a quarter on the 5-hour meter and by a third on the weekly meter**, and it shows that the round-1 five-hour leader was partly noise.

- **5-hour meter (100 episodes, 9 models).** Six models are statistically tied for best: Timestral-5M (+26.5%), Timestral-123M (+26.4%), a gradient-boosted quantile model (+25.7%), spend-decay-30m (+25.4%), the Fable burst model (+25.0%) and the Fable analog model (+19.5%). Pacer's shipping rule is **outside** that set. Its 80% ranges cover the truth only 61% of the time; spend-decay's cover 81%, Timestral-5M's 83%, the gradient-boosted model's only 65%.
- **Weekly meter (60 episodes, 11 models).** Six models tied for best: the Haiku-written Timestral-209M (+38.0%), spend-decay-6h (+37.2%), the analog model (+33.7%), a Sonnet calibration ensemble (+32.8%), an Opus Timestral model (+29.2%) and an Opus gated ensemble (+27.3%). Timestral-5M (+22%) and 123M (+19%) are **not** in the set. The rule's weekly 80% ranges cover 66%.
- **Spend-decay is the only model tied for best on both meters** and it needs no pretrained weights, so it is the recommended first port (`docs/port-spec.md`). It was the weekly leader on reset-time error.

Numbers are the lockbox reports in `results.md` (this folder).

## What changed from round 1

- Round 1's analog-model lead on the 5-hour meter was based on 57 test cases; with 100 it is last of the tied six, still better than the rule but not the winner.
- Round 1 said Timestral-5M matched the bigger models. That holds on the 5-hour meter and not on the weekly one.
- The live meter and a flat forecast are far worse than the rule here (roughly -70% on 5-hour, -50% on weekly): they are baselines, not candidates.
- Wider ranges were not the answer on the lockbox: the weekly winners' ranges are *too wide* (cover80 of 0.94 to 0.98), the rule's too narrow. That is the case the calibration layer is meant for.

## The calibration layer: what was and was not measured

The calibration layer (`kit/calib.py`, spec in `docs/port-spec.md`) recalibrates a forecaster's ranges from its own recent backtests without moving its median. It was built after the lockbox weeks were frozen. It was validated on the visible tier and on synthetic data, paired wrapper against base on identical cases. **It was not scored on the lockbox.** Doing so costs 170 to 660 seconds per model and episode (the wrapper backtests its base at every checkpoint), about 35 to 40 hours for 100 five-hour episodes at two jobs, so it was stopped. The cheaper way to answer the question is the prospective re-run (`RUNBOOK.md` section 6) with the `calib-*` models.

What the builder's validation found (CRPS change in percent, wrapper vs base, plus or minus one standard error; positive is better; pit_tv is distance from a flat PIT, lower is better):

| base | meter | visible CRPS | visible cover80 / pit_tv, base to wrapper | synthetic CRPS | synthetic cover80 / pit_tv |
|---|---|---|---|---|---|
| spend-decay-30m | 5-hour | -6.9 ± 7.0 | 0.63 to 0.60 / 0.285 to 0.225 | +3.8 ± 2.7 | 0.80 to 0.82 / 0.158 to 0.159 |
| spend-decay-6h | weekly | -7.5 ± 5.9 | 0.45 to 0.55 / 0.377 to 0.279 | +1.8 ± 4.3 | 0.65 to 0.78 / 0.229 to 0.122 |
| analog | 5-hour | -0.8 ± 9.1 | pit_tv 0.140 to 0.144 | +3.6 ± 2.0 | |
| analog | weekly | -2.9 ± 3.0 | pit_tv 0.154 to 0.084 | +1.3 ± 1.2 | |
| Timestral-5M | 5-hour | +2.6 ± 2.2 | pit_tv 0.184 to 0.122 | -0.2 ± 0.6 | pit_tv 0.433 to 0.403 |
| Timestral-5M | weekly | -1.4 ± 2.1 | pit_tv 0.227 to 0.164 | -0.6 ± 3.3 | pit_tv 0.253 to 0.071 |
| Fable burst | 5-hour | +0.5 ± 3.2 | | -4.1 ± 4.1 | |
| Haiku Timestral-209M | weekly | -2.1 ± 3.1 | | +6.1 ± 3.6 | |
| Opus Timestral (g1-08) | weekly | +0.7 ± 0.6 | pit_tv 0.099 to 0.178 | +7.6 ± 5.3 | |
| Opus gated ensemble (g2-06) | weekly | +0.0 ± 0.8 | | +11.7 ± 6.8 | |

Reading it: the PIT got flatter for most bases, and CRPS stayed within about two standard errors of the base. Wrapping the two Opus models adds nothing; they already recalibrate themselves. The cover80 of the visible spend-decay rows moved the wrong way only because many readings sit exactly on the forecast's floor (the meter did not move), so read pit_tv, not cover80. The five-hour samples are small (6 to 12 cells per row). **The effect on the lockbox is untested.**

## What it means for the port

- Port **spend-decay** first: `-30m` for the 5-hour meter and `-6h` for the weekly and scoped meters. It ties for best on both, needs no weights and builds on the app's own spend fit.
- The calibration layer is optional on top. Its evidence is the visible and synthetic validation above, not the lockbox; ship it behind the same per-meter self-evaluation as everything else.
- The app does not need a shadow phase. It runs every top model for real, and each user's Pacer picks per meter from its own record (the engine's self-evaluation), falling back to the shipping rule when no model has a record yet. The tied sets above are why the choice is cheap: any member of a set is a defensible pick, and the data on the user's own machine breaks the tie.
- Timestral-5M is a 5-hour alternative only. The analog model is a pure-arithmetic alternative. The Fable burst model is tied on the 5-hour meter and has the widest honest ranges (cover80 0.91).

## Caveats

- One person's data and four accounts. The tied sets say which models cannot be told apart *here*.
- The lockbox runs scored the 5-hour meter on 100 episodes (6 timeouts recorded) and the weekly meter on 60 (none). Episodes are a handful of accounts' weeks, so confidence sets are wide.
- The engine's rule is excluded from the 5-hour tied set; on the weekly meter it is far from it.
- Calibration-layer claims above come from non-lockbox data.
