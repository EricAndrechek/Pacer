"""LightGBM quantile regression of the meter's remaining rise.

Training (at the first forecast, from the history only): every past cutoff
on a fixed lattice where a cycle of the window kind was active, on every
visible account, described by the as-of features of `kit.ml.features` and
labelled with the rise to several leads (fractions of the time then left to
the reset) that were already known at `now` (`kit.ml.walkforward`). The
(cutoff, lead) pairs are stacked, with the lead's own features (its fraction,
its hours, the burn and the activity profile carried over it), and one
booster per quantile level is fitted on them.

Calibration: quantile boosters fitted in-sample are too narrow out of
sample (neighbouring cutoffs of one cycle are near copies). So the spread of
each level around the median is rescaled by the factor that minimizes its
pinball loss out of fold, with folds of whole cycles in time blocks
(`calibrate_folds`; 0 turns it off).

Forecast: the boosters' quantiles at 15 anchor leads, rescaled, sorted (no
crossing), made non-decreasing in lead and bounded by the headroom, then
read on the grid and turned into comonotone paths (`kit.ml.paths`).
"""
from __future__ import annotations

import numpy as np

from kit.ml.meter_model import LearnedMeterModel
from kit.ml.paths import rise_paths

SCALES = np.linspace(0.5, 4.0, 36)


def pinball(y: np.ndarray, q: np.ndarray, a: float) -> float:
    d = y - q
    return float(np.mean(np.maximum(a * d, (a - 1) * d)))


class Model(LearnedMeterModel):
    name = "ml-gbm-quantile"

    def _params(self, kind):
        weekly = kind != "five_hour"
        c = self.cfg
        return dict(n_estimators=int(c.get("n_estimators", 150)), learning_rate=float(c.get("learning_rate", 0.05)),
                    num_leaves=int(c.get("weekly_num_leaves" if weekly else "num_leaves", 7 if weekly else 15)),
                    min_child_samples=int(c.get("weekly_min_child_samples" if weekly else "min_child_samples",
                                                10 if weekly else 20)),
                    subsample=0.8, subsample_freq=1, colsample_bytree=0.8, reg_lambda=1.0,
                    # One thread, coarse bins: measured several times faster than two
                    # threads on these small sets (and a worker has two CPUs).
                    n_jobs=1, max_bin=63, force_col_wise=True, verbose=-1,
                    random_state=int(self.ctx.seed % (2 ** 31)))

    def _fit(self, X, y, levels, kw):
        import lightgbm as lgb
        return [lgb.LGBMRegressor(objective="quantile", alpha=float(a), **kw).fit(X, y) for a in levels]

    def train(self, ts, kind):
        X, y, r = ts.stacked()
        kw = self._params(kind)
        levels = np.asarray(self.cfg.get("levels", [0.03, 0.1, 0.25, 0.5, 0.75, 0.9, 0.97]), dtype=np.float64)
        # Out-of-fold scales, shrunk toward a prior (`default_scale`, one per
        # level) by `prior_cycles` pseudo-cycles; the prior alone when there are
        # too few cycles to fold.
        prior = np.asarray(self.cfg.get("default_scale", [1.0] * len(levels)), dtype=np.float64)
        n0 = float(self.cfg.get("prior_cycles", 10))
        scale = prior.copy()
        k = int(self.cfg.get("calibrate_folds", 3))
        n_cyc = int(ts.cycle.max()) + 1 if len(ts) else 0
        if k >= 2 and n_cyc >= 3 * k:
            # Folds of whole cycles in time blocks (a cycle's cutoffs are near copies of each other).
            first = np.array([ts.reset[ts.cycle == c].min() for c in range(n_cyc)])
            rank = np.empty(n_cyc, dtype=np.int64)
            rank[np.argsort(first, kind="stable")] = np.arange(n_cyc)
            fold = (rank * k // n_cyc)[ts.cycle[r]]
            oof = np.full((len(levels), len(y)), np.nan)
            for f in range(k):
                tr, te = fold != f, fold == f
                if tr.sum() < 50 or te.sum() == 0:
                    continue
                for j, b in enumerate(self._fit(X[tr], y[tr], levels, kw)):
                    oof[j, te] = b.predict(X[te])
            ok = np.isfinite(oof).all(axis=0)
            if ok.sum() >= 50:
                med = np.median(oof[:, ok], axis=0) if 0.5 not in levels else oof[list(levels).index(0.5), ok]
                yy = y[ok]
                for j, a in enumerate(levels):
                    if a == 0.5:
                        continue
                    losses = [pinball(yy, med + s * (oof[j, ok] - med), a) for s in SCALES]
                    scale[j] = (n_cyc * SCALES[int(np.argmin(losses))] + n0 * prior[j]) / (n_cyc + n0)
        self.ctx.log(f"{self.name} {kind}: {n_cyc} cycles, spread scale "
                     + " ".join(f"{a:g}:{x:.2f}" for a, x in zip(levels, scale)))
        return {"levels": levels, "boosters": self._fit(X, y, levels, kw), "scale": scale}

    def predict(self, state, row, lead_X, fracs, grid_fracs, used, n_paths, rng):
        X = np.concatenate([np.repeat(row[None, :], len(fracs), axis=0), lead_X], axis=1)
        q = np.stack([b.predict(X) for b in state["boosters"]])           # [levels, anchors]
        lv = state["levels"]
        med = q[list(lv).index(0.5)] if 0.5 in lv else np.median(q, axis=0)
        q = med[None, :] + state["scale"][:, None] * (q - med[None, :])
        return rise_paths(lv, q, fracs, grid_fracs, used, n_paths, rng)
