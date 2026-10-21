# ML forecasters for the prediction lab

Walk-forward LightGBM / linear quantile regression / kNN-analog models over the lab's 4,205-case table.
Predictions: `../preds/ml-*.parquet` (86 base configs, a `-cal` conformal-band twin of each, and 6 `ens-*` averages).
Full leaderboard: `leaderboard.txt` (`uv run score.py --match ml-`).

## Rerun (from research/lab)
    uv run python ml/features.py   # features.parquet (~10 s)
    uv run python ml/tokfeat.py    # tokfeatures.parquet, per-epoch NNLS token weights (~40 s)
    uv run python ml/run.py        # all configs, ~60 s each on a busy machine (--only <substr>, --force)
    uv run python ml/post.py       # -cal twins + ens-*
    uv run score.py --match ml-

## Features (`features.py`, `tokfeat.py`) — all computed at the cut from t <= t_cut
cut, used_now, headroom, elapsed/remaining h; burn rates over 4 lookbacks (5h: 15m/30m/1h/2h, 7d: 3h/12h/1d/2d), cycle-average rate, acceleration, projections;
trajectory shape (meter at 25/50/75/100% of elapsed); idleness; sin/cos of hour and weekday; remaining/elapsed activity from the account's 7x24 prior and the
activity-scaled projection; account history of cycles that had RESET by t_cut (mean/median/last/last-5 final, share >=99, same-hour-of-day mean, same-cut mean delta/headroom
fraction, pooled mean); cross-window (other window of the same account: level, elapsed fraction, two burn rates, age); concurrent burn on the other accounts.
`-stacked`: adds the 7 engine models' predictions (as deltas from used_now), their median/min/max/spread, and rule-current's prediction (all leak-free per the lab).
`-tok`: adds token features (`tokfeat.py`): turns converted to meter points with NNLS weights (model family x token kind; per account if >=200 intervals else pooled; separate
weights per window), over 3 lookbacks (5h 15m/1h/3h, 7d 3h/12h/1d) and since cycle start; NOWCAST (points since the last meter reading before the cut, and used_now + that);
sessions with a turn in the last 10/30/60 min, their burn rate, mean/max age of active sessions; token-vs-meter calibration ratio / unexplained residual; token projection.
Account one-hots only in `pooled-acct`; `is_7d` only in `joint`.

## Targets / models / regimes
Targets: `truth`, `delta` (truth-used_now), `frac` ((truth-used)/(100-used)); predictions mapped back to pct. Regimes: `acct` (one model per account), `pooled`, `pooled-acct` (one-hot),
`joint` (both windows, window flag). Models: `lgbm` (L1 point + quantile 0.1/0.9, 120 trees/15 leaves for 5h, 80/4 for 7d), `linqr` (sklearn QuantileRegressor, standardised, median-imputed, L1 0.01), `knn`
(k=9/5 nearest past cycles at the same cut by trajectory shape, 1/(d+0.5) weights; pooled-acct adds a distance penalty for other accounts), `lgbmtruthmono` (monotone in used_now on the point model only —
LightGBM refuses constraints with L1/quantile, so the point model is Huber).
`-cal`: CQR — band widened by the 80% quantile of earlier (resets_at <= t_cut) own residuals vs the band; >=30 needed.
`ens-*`: plain averages by name pattern (lgbm over the 3 targets; stacked; a mixed lgbm/linqr/knn set), fixed in `post.py` before looking at scores.

## Leakage safeguards
* Retrain epochs: 5h every 2 days, 7d every 1 day, anchored at the window's first `resets_at`. A case is predicted by the epoch with T <= t_cut; training rows are cases with `resets_at <= T`
  (asserted in code). Epochs with an identical training set share one fit (equivalent to retraining).
* Row features use only readings/turns <= that row's own t_cut and only cycles with resets_at <= t_cut. Token NNLS weights are fit only on meter-rise intervals ending <= T (per epoch).
* Cases with no usable training set (5h pooled 158, per-account 471; 7d pooled 46 (joint 10), per-account 92) fall back to rule-current's prediction (their bands are missing; see `fallbacks.json`).
* Known caveats: (1) the activity prior `grids.json` is built from the whole store (incl. the future) — a mild leak shared by every engine model, not removable here. (2) `rule-current` and engine
  predictions (stacked) are leak-free by the lab's construction. (3) The leaderboard is best-of-~170 files on the same cases: the top few picks are optimistically biased, and 7d has only ~34 cycles.
