"""LightGBM quantile regression with ML-tuned spread scales.

Like ml-gbm-quantile but with:
1. More estimators for better fit quality
2. Wider fixed prior scales to address the systematic undercoverage in the
   existing model (ml-gbm-quantile has cover50=0.36 vs ideal 0.50)
3. Light calibration using out-of-fold predictions from the SAME cycles,
   focused on the median and tails separately

The key improvement: ml-gbm-quantile's cross-fold calibration underestimates
needed interval width because neighboring cutoffs of the same cycle are
near-copies. By using wider priors, we get better out-of-sample coverage
without risking calibration instability.
"""
from __future__ import annotations

import numpy as np

from kit.ml.meter_model import LearnedMeterModel
from kit.ml.paths import rise_paths

SCALES = np.linspace(0.5, 4.0, 36)


def _pinball(y: np.ndarray, q: np.ndarray, alpha: float) -> float:
    d = y - q
    return float(np.mean(np.maximum(alpha * d, (alpha - 1) * d)))


class Model(LearnedMeterModel):
    name = "g1-01-sonnet-cqr"

    def _params(self, kind):
        weekly = kind != "five_hour"
        c = self.cfg
        return dict(
            n_estimators=int(c.get("n_estimators", 150)),
            learning_rate=float(c.get("learning_rate", 0.05)),
            num_leaves=int(c.get("weekly_num_leaves" if weekly else "num_leaves", 10 if weekly else 20)),
            min_child_samples=int(
                c.get("weekly_min_child_samples" if weekly else "min_child_samples", 8 if weekly else 15)
            ),
            subsample=0.8, subsample_freq=1, colsample_bytree=0.8, reg_lambda=1.0,
            n_jobs=1, max_bin=63, force_col_wise=True, verbose=-1,
            random_state=int(self.ctx.seed % (2 ** 31)),
        )

    def train(self, ts, kind):
        import lightgbm as lgb

        levels = np.asarray(self.cfg.get("levels", [0.03, 0.1, 0.25, 0.5, 0.75, 0.9, 0.97]), dtype=np.float64)
        # Wider prior: ml-gbm-quantile has [1.2, 1.2, 1.1, 1.0, 1.3, 1.7, 2.0]
        # which gives cover50=0.36. We use significantly wider priors to target
        # cover50 closer to 0.50.
        prior = np.asarray(self.cfg.get("default_scale", [2.5, 2.0, 1.4, 1.0, 1.4, 2.0, 2.5]), dtype=np.float64)
        n0 = float(self.cfg.get("prior_cycles", 8))
        kw = self._params(kind)

        X, y, r = ts.stacked()
        n_cyc = int(ts.cycle.max()) + 1 if len(ts) else 0
        if len(y) < int(self.cfg.get("min_rows", 200)) or n_cyc < int(self.cfg.get("min_cycles", 20)):
            return None

        boosters = [lgb.LGBMRegressor(objective="quantile", alpha=float(a), **kw).fit(X, y) for a in levels]

        # Use out-of-fold cross-validation to calibrate scales chronologically.
        scale = prior.copy()
        k = int(self.cfg.get("calibrate_folds", 3))
        min_cyc = int(self.cfg.get("min_cycles", 20))

        if k >= 2 and n_cyc >= max(3 * k, min_cyc):
            # Chronological folds: each fold is a time block of cycles.
            fold = (ts.cycle[r] * k // n_cyc).astype(int)
            oof = np.full((len(levels), len(y)), np.nan)
            for f in range(k):
                tr_mask, te_mask = fold != f, fold == f
                if tr_mask.sum() < 50 or te_mask.sum() == 0:
                    continue
                for j, alpha in enumerate(levels):
                    b = lgb.LGBMRegressor(objective="quantile", alpha=float(alpha), **kw).fit(
                        X[tr_mask], y[tr_mask]
                    )
                    oof[j, te_mask] = b.predict(X[te_mask])

            ok = np.isfinite(oof).all(axis=0)
            if ok.sum() >= 50:
                med = oof[list(levels).index(0.5), ok] if 0.5 in levels else np.median(oof[:, ok], axis=0)
                yy = y[ok]
                for j, alpha in enumerate(levels):
                    if alpha == 0.5:
                        continue
                    losses = [_pinball(yy, med + s * (oof[j, ok] - med), alpha) for s in SCALES]
                    best_s = SCALES[int(np.argmin(losses))]
                    scale[j] = (n_cyc * best_s + n0 * prior[j]) / (n_cyc + n0)

        self.ctx.log(f"{self.name} {kind}: {n_cyc} cycles, scales: "
                     + " ".join(f"{a:g}:{x:.2f}" for a, x in zip(levels, scale)))
        return {"levels": levels, "boosters": boosters, "scale": scale}

    def predict(self, state, row, lead_X, fracs, grid_fracs, used, n_paths, rng):
        X = np.concatenate([np.repeat(row[None, :], len(fracs), axis=0), lead_X], axis=1)
        q = np.stack([b.predict(X) for b in state["boosters"]])  # [levels, anchors]
        lv = state["levels"]

        if 0.5 in lv:
            med = q[list(lv).index(0.5)]
        else:
            med = np.median(q, axis=0)
        q_adj = med[None, :] + state["scale"][:, None] * (q - med[None, :])

        return rise_paths(lv, q_adj, fracs, grid_fracs, used, n_paths, rng)
