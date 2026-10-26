"""LightGBM quantile regression for meters with improved regularization.

Based on ml-gbm-quantile's proven approach but with:
1. Stronger regularization for weekly meters (fewer leaves, higher lambda)
2. Better hyperparameters (lower learning rate, more trees)
3. Same OOF spread-scaling calibration that works well

This model focuses on reliability over novelty - the GBM quantile approach
is sound, and the improvements are in the tuning.
"""
from __future__ import annotations

import numpy as np

from kit.ml.meter_model import LearnedMeterModel
from kit.ml.paths import rise_paths

SCALES = np.linspace(0.5, 8.0, 76)


def pinball(y, q, a):
    d = y - q
    return float(np.mean(np.maximum(a * d, (a - 1) * d)))


class Model(LearnedMeterModel):
    name = "g1-04-opus-gbm-conformal"

    def _params(self, kind):
        weekly = kind != "five_hour"
        c = self.cfg
        if weekly:
            return dict(
                n_estimators=int(c.get("weekly_n_estimators", 120)),
                learning_rate=float(c.get("learning_rate", 0.04)),
                num_leaves=int(c.get("weekly_num_leaves", 5)),
                min_child_samples=int(c.get("weekly_min_child_samples", 10)),
                subsample=0.7, subsample_freq=1, colsample_bytree=0.6,
                reg_lambda=3.0, reg_alpha=0.5,
                n_jobs=1, max_bin=63, force_col_wise=True, verbose=-1,
                random_state=int(self.ctx.seed % (2 ** 31)),
            )
        return dict(
            n_estimators=int(c.get("n_estimators", 180)),
            learning_rate=float(c.get("learning_rate", 0.04)),
            num_leaves=int(c.get("num_leaves", 12)),
            min_child_samples=int(c.get("min_child_samples", 15)),
            subsample=0.8, subsample_freq=1, colsample_bytree=0.8,
            reg_lambda=1.5,
            n_jobs=1, max_bin=63, force_col_wise=True, verbose=-1,
            random_state=int(self.ctx.seed % (2 ** 31)),
        )

    def _fit_quantile(self, X, y, levels, kw):
        import lightgbm as lgb
        return [lgb.LGBMRegressor(objective="quantile", alpha=float(a), **kw).fit(X, y) for a in levels]

    def train(self, ts, kind):
        X, y, r = ts.stacked()
        kw = self._params(kind)
        levels = np.asarray(self.cfg.get("levels",
            [0.03, 0.1, 0.25, 0.5, 0.75, 0.9, 0.97]), dtype=np.float64)

        prior = np.asarray(self.cfg.get("default_scale",
            [1.2, 1.2, 1.1, 1.0, 1.3, 1.7, 2.0]), dtype=np.float64)
        n0 = float(self.cfg.get("prior_cycles", 10))
        scale = prior.copy()

        k = int(self.cfg.get("calibrate_folds", 3))
        n_cyc = int(ts.cycle.max()) + 1 if len(ts) else 0

        if k >= 2 and n_cyc >= 3 * k:
            first = np.array([ts.reset[ts.cycle == c].min() for c in range(n_cyc)])
            rank = np.empty(n_cyc, dtype=np.int64)
            rank[np.argsort(first, kind="stable")] = np.arange(n_cyc)
            fold = (rank * k // n_cyc)[ts.cycle[r]]
            oof = np.full((len(levels), len(y)), np.nan)
            for f in range(k):
                tr_m, te_m = fold != f, fold == f
                if tr_m.sum() < 50 or te_m.sum() == 0:
                    continue
                for j, b in enumerate(self._fit_quantile(X[tr_m], y[tr_m], levels, kw)):
                    oof[j, te_m] = b.predict(X[te_m])
            ok = np.isfinite(oof).all(axis=0)
            if ok.sum() >= 50:
                med = oof[list(levels).index(0.5), ok] if 0.5 in levels else np.median(oof[:, ok], axis=0)
                yy = y[ok]
                for j, a in enumerate(levels):
                    if a == 0.5:
                        continue
                    losses = [pinball(yy, med + s * (oof[j, ok] - med), a) for s in SCALES]
                    scale[j] = (n_cyc * SCALES[int(np.argmin(losses))] + n0 * prior[j]) / (n_cyc + n0)

        y_std = float(np.std(y)) if len(y) > 10 else 0.0
        self.ctx.log(f"{self.name} {kind}: {n_cyc} cyc, {len(X)} rows, y_std={y_std:.2f}, "
                     f"scale={' '.join(f'{a:.2g}:{s:.2f}' for a, s in zip(levels, scale))}")
        return {"levels": levels, "boosters": self._fit_quantile(X, y, levels, kw), "scale": scale,
                "y_std": y_std, "kind": kind}

    def predict(self, state, row, lead_X, fracs, grid_fracs, used, n_paths, rng):
        X = np.concatenate([np.repeat(row[None, :], len(fracs), axis=0), lead_X], axis=1)
        q = np.stack([b.predict(X) for b in state["boosters"]])
        lv = state["levels"]
        med_idx = list(lv).index(0.5) if 0.5 in lv else len(lv) // 2
        med = q[med_idx]
        q = med[None, :] + state["scale"][:, None] * (q - med[None, :])

        y_std = state.get("y_std", 0.0)
        kind = state.get("kind", "five_hour")
        if kind == "seven_day":
            min_spread_frac = float(self.cfg.get("min_spread_7d", 3.0))
        elif kind != "five_hour":
            min_spread_frac = float(self.cfg.get("min_spread_scoped", 1.0))
        else:
            min_spread_frac = 0.0
        if y_std > 0 and min_spread_frac > 0:
            for j in range(len(fracs)):
                f = max(fracs[j], 0.01)
                min_half = min_spread_frac * y_std * np.sqrt(f)
                for i, a in enumerate(lv):
                    if a < 0.5:
                        q[i, j] = min(q[i, j], med[j] - min_half * (0.5 - a) / 0.5)
                    elif a > 0.5:
                        q[i, j] = max(q[i, j], med[j] + min_half * (a - 0.5) / 0.5)

        return rise_paths(lv, q, fracs, grid_fracs, used, n_paths, rng)
