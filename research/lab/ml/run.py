"""Walk-forward ML forecasters over the lab's case table.

  cd research/lab
  uv run python ml/features.py                 # once
  uv run python ml/run.py                      # every config  (or --only lgbm-delta)
  uv run python ml/post.py                     # conformal calibration + ensembles
  uv run score.py --match ml-

STRICT walk-forward: a case at t_cut is predicted by the model fit at the
latest retrain time T <= t_cut, on cases whose cycle RESET <= T (so on cycles
whose every reading precedes T). Features of each row use data <= its own cut.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import warnings
from pathlib import Path

import lightgbm as lgb
import numpy as np
import pandas as pd
from sklearn.linear_model import QuantileRegressor

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import lab  # noqa: E402

warnings.filterwarnings("ignore")
DAY = 86400.0
# retrain cadence (days) and minimum training rows per regime
PERIOD = {"five_hour": 2.0, "seven_day": 1.0, "joint": 2.0}
MIN_ROWS = {("five_hour", "pooled"): 150, ("five_hour", "acct"): 100,
            ("seven_day", "pooled"): 40, ("seven_day", "acct"): 24, ("joint", "pooled"): 150}

NON_FEATURES = {"case_id", "window", "account", "t_cut", "resets_at", "cycle_start", "truth", "fold", "delta", "frac"}


def load() -> pd.DataFrame:
    F = pd.read_parquet(HERE / "features.parquet")
    rule = lab.read_preds("rule-current").rename(columns={"pred": "rule"})
    F = F.merge(rule[["case_id", "rule"]], on="case_id", how="left")
    F["eng_d_rule"] = np.clip(F["rule"], F["used_now"], 100) - F["used_now"]
    tk = HERE / "tokfeatures.parquet"
    if tk.exists():
        F = F.merge(pd.read_parquet(tk), on="case_id", how="left")
    F["frac"] = np.where(F["used_now"] < 99.5, F["delta"] / (100 - F["used_now"]).clip(lower=0.5), 0.0)
    return F


def feature_cols(F: pd.DataFrame, stacked: bool, acct: bool, joint: bool, tok: bool = False) -> list[str]:
    cols = [c for c in F.columns if c not in NON_FEATURES and c != "rule"]
    cols = [c for c in cols if not c.startswith("acct") and c != "is_7d"]
    if not stacked:
        cols = [c for c in cols if not c.startswith("eng_")]
    if not tok:
        cols = [c for c in cols if not (c.startswith("tok_") or c.startswith("sess_"))]
    if acct:
        cols += [c for c in F.columns if c.startswith("acct")]
    if joint:
        cols += ["is_7d"]
    return cols


# ---- target transforms ------------------------------------------------------
def y_of(df: pd.DataFrame, target: str) -> np.ndarray:
    return {"truth": df["truth"], "delta": df["delta"], "frac": df["frac"]}[target].to_numpy()


def to_pct(v: np.ndarray, df: pd.DataFrame, target: str) -> np.ndarray:
    u = df["used_now"].to_numpy()
    if target == "truth":
        return v
    if target == "delta":
        return u + v
    return u + v * np.maximum(100 - u, 0.0)


# ---- models -----------------------------------------------------------------
class LGBM:
    def __init__(self, target, cols, window, mono=False):
        self.target, self.cols, self.mono = target, cols, mono
        small = window == "seven_day"
        self.kw = dict(n_estimators=80 if small else 120, learning_rate=0.06, num_leaves=4 if small else 15,
                       min_child_samples=8 if small else 25, subsample=0.8, subsample_freq=1, colsample_bytree=0.8,
                       reg_lambda=1.0, n_jobs=2, verbose=-1, random_state=7)

    def fit_predict(self, tr, te):
        X, Xt, y = tr[self.cols], te[self.cols], y_of(tr, self.target)
        mc = [1 if (self.mono and c == "used_now") else 0 for c in self.cols]
        out = {}
        for key, obj in (("pred", dict(objective="huber", alpha=3.0) if self.mono else dict(objective="l1")), ("q10", dict(objective="quantile", alpha=0.1)),
                         ("q90", dict(objective="quantile", alpha=0.9))):
            m = lgb.LGBMRegressor(**self.kw, **obj, monotone_constraints=mc if (self.mono and key == 'pred') else None)
            m.fit(X, y)
            out[key] = to_pct(m.predict(Xt), te, self.target)
        return out


class LinQR:
    def __init__(self, target, cols, window, mono=False):
        self.target, self.cols = target, cols

    def fit_predict(self, tr, te):
        X, Xt = tr[self.cols].to_numpy(float), te[self.cols].to_numpy(float)
        med = np.nanmedian(X, axis=0)
        med = np.where(np.isnan(med), 0.0, med)
        X, Xt = np.where(np.isnan(X), med, X), np.where(np.isnan(Xt), med, Xt)
        mu, sd = X.mean(0), X.std(0)
        sd = np.where(sd < 1e-9, 1.0, sd)
        X, Xt = np.clip((X - mu) / sd, -5, 5), np.clip((Xt - mu) / sd, -5, 5)
        y = y_of(tr, self.target)
        out = {}
        for key, q in (("pred", 0.5), ("q10", 0.1), ("q90", 0.9)):
            m = QuantileRegressor(quantile=q, alpha=0.01, solver="highs").fit(X, y)
            out[key] = to_pct(m.predict(Xt), te, self.target)
        return out


class KNN:
    """Analog forecast: the k past cycles, at the same cut, whose trajectory
    looks most like this one; their (delta | headroom fraction) carries over."""
    def __init__(self, target, cols, window, mono=False, acct_penalty=None, tok=False):
        self.target, self.k = target, (5 if window == "seven_day" else 9)
        self.shape = ["traj1", "traj2", "traj3", "used_now", "proj_l2"] + (["tok_nowcast", "tok_proj"] if tok else [])
        self.penalty = acct_penalty

    def fit_predict(self, tr, te):
        S = tr[self.shape].to_numpy(float)
        S = np.nan_to_num(S)
        scale = S.std(0)
        scale = np.where(scale < 1e-9, 1.0, scale)
        St = np.nan_to_num(te[self.shape].to_numpy(float))
        y = y_of(tr, self.target)
        cut_tr, acct_tr = tr["cut"].to_numpy(), tr["account"].to_numpy()
        res = {k: np.full(len(te), np.nan) for k in ("pred", "q10", "q90")}
        for i, (cut, acct) in enumerate(zip(te["cut"].to_numpy(), te["account"].to_numpy())):
            m = np.abs(cut_tr - cut) < 0.05
            if m.sum() < self.k:
                m = np.abs(cut_tr - cut) < 0.15
            if m.sum() < 3:
                continue
            idx = np.where(m)[0]
            d = np.sqrt((((S[idx] - St[i]) / scale) ** 2).sum(1))
            if self.penalty is not None:
                d = d + self.penalty * (acct_tr[idx] != acct)
            o = np.argsort(d)[: self.k]
            yy, w = y[idx][o], 1.0 / (d[o] + 0.5)
            vals = np.array([self._wq(yy, w, q) for q in (0.5, 0.1, 0.9)])
            res["pred"][i], res["q10"][i], res["q90"][i] = vals[0], vals[1], vals[2]
            res["pred"][i] = float((yy * w).sum() / w.sum())
        return {k: to_pct(v, te, self.target) for k, v in res.items()}

    @staticmethod
    def _wq(y, w, q):
        o = np.argsort(y)
        y, w = y[o], w[o]
        c = (np.cumsum(w) - 0.5 * w) / w.sum()
        return float(np.interp(q, c, y))


MODELS = {"lgbm": LGBM, "linqr": LinQR, "knn": KNN}


# ---- walk-forward driver ----------------------------------------------------
def walk_forward(F, model, target, regime, stacked, window, mono=False, tok=False):
    """Returns DataFrame(case_id, pred, q10, q90, fallback) for one window (or both if joint)."""
    joint = window == "joint"
    sub = F if joint else F[F["window"] == window]
    sub = sub.sort_values("t_cut").reset_index(drop=True)
    cols = feature_cols(F, stacked, acct=(regime == "pooled-acct"), joint=joint, tok=tok)
    period = PERIOD[window] * DAY
    t_first = sub["resets_at"].min()
    k_of = np.floor((sub["t_cut"].to_numpy() - t_first) / period).astype(int)
    out = pd.DataFrame({"case_id": sub["case_id"], "pred": np.nan, "q10": np.nan, "q90": np.nan})
    groups = [(None, sub)] if regime != "acct" else list(sub.groupby("account"))
    minrows = MIN_ROWS[(window, "acct" if regime == "acct" else "pooled")]
    for acct, g in groups:
        # Epochs whose training set is identical (no cycle reset in between) share one fit:
        # same model, same rows, so predicting them together is exactly retraining each time.
        pend, last_n, last_T = [], None, None

        def flush():
            if not pend or last_n is None or last_n < minrows:
                return
            te_idx = np.concatenate(pend)
            tr = g[g["resets_at"] <= last_T]
            assert len(tr) == last_n and (sub.loc[te_idx, "t_cut"] >= last_T).all()
            kw = dict(acct_penalty=(8.0 if regime == "pooled-acct" else None)) if model == "knn" else {}
            if mono:
                kw["mono"] = True
            if model == "knn" and tok:
                kw["tok"] = True
            mdl = MODELS[model](target, cols, "seven_day" if window == "seven_day" else "five_hour", **kw)
            p = mdl.fit_predict(tr, sub.loc[te_idx])
            for key in ("pred", "q10", "q90"):
                out.loc[te_idx, key] = p[key]

        for k in np.unique(k_of[g.index]):
            if k < 0:
                continue
            T = t_first + k * period
            n = int((g["resets_at"] <= T).sum())
            if n != last_n:
                flush()
                pend, last_n, last_T = [], n, T
            pend.append(g.index[k_of[g.index] == k].to_numpy())
        flush()
    return out


CONFIGS = []
for target in ("truth", "delta", "frac"):
    for regime in ("acct", "pooled", "pooled-acct"):
        for stacked in (False, True):
            CONFIGS.append(("lgbm", target, regime, stacked, False))
CONFIGS.append(("lgbm", "truth", "pooled", False, True))   # monotone in used_now
CONFIGS.append(("lgbm", "truth", "pooled", True, True))
for target in ("delta", "frac"):
    for regime in ("acct", "pooled", "pooled-acct"):
        for stacked in (False, True):
            CONFIGS.append(("linqr", target, regime, stacked, False))
        CONFIGS.append(("knn", target, regime, False, False))
JOINT = [("lgbm", t, "pooled-acct", s, False) for t in ("truth", "delta", "frac") for s in (False, True)]


def name_of(model, target, regime, stacked, mono, tok=False):
    t = target + ("mono" if mono else "")
    return f"ml-{model}-{t}-{regime}" + ("-stacked" if stacked else "") + ("-tok" if tok else "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    F = load()
    rule = F.set_index("case_id")["rule"]
    outdir = HERE / "out"
    outdir.mkdir(exist_ok=True)
    log = {}
    lp = HERE / "fallbacks.json"
    if lp.exists():
        log = json.loads(lp.read_text())
    base = CONFIGS + [("joint",) + j for j in JOINT]
    for cfg, tok in [(c, t) for c in base for t in (False, True) if not (t and c[0] != "joint" and c[4])]:
        if cfg[0] == "joint":
            model, target, regime, stacked, mono = cfg[1:]
            name = name_of(model, target, "joint", stacked, mono, tok)
            wins = ["joint"]
        else:
            model, target, regime, stacked, mono = cfg
            name = name_of(model, target, regime, stacked, mono, tok)
            wins = ["five_hour", "seven_day"]
        if a.only not in name:
            continue
        if (outdir / f"{name}.parquet").exists() and not a.force:
            continue
        t0 = time.time()
        parts = [walk_forward(F, model, target, regime, stacked, w, mono, tok) for w in wins]
        o = pd.concat(parts, ignore_index=True)
        o["fallback"] = o["pred"].isna()
        o = o.merge(F[["case_id", "window"]], on="case_id")
        o.to_parquet(outdir / f"{name}.parquet", index=False)   # raw, with NaN for not-yet-trainable
        filled = o.copy()
        filled["pred"] = filled["pred"].fillna(filled["case_id"].map(rule))
        lab.write_preds(name, filled)
        log[name] = {w: int(g["fallback"].sum()) for w, g in o.groupby("window")}
        lp.write_text(json.dumps(log, indent=1))
        print(f"{name:48s} {time.time()-t0:6.1f}s fallbacks {log[name]}", flush=True)


if __name__ == "__main__":
    main()
