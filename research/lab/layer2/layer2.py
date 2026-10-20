"""The second layer: given every base candidate's prediction for every case,
decide (or combine) walk-forward, the way the app's record would.

For a case at t_cut the second layer may learn only from cases of cycles that
RESET by t_cut: their candidates' predictions and their truths. "acct" learns
from the case's own account only, "pooled" from every account, "hier" from the
account once it has `HIER_MIN` cycles of record and from the pool before that.

Strategies (each writes preds/l2-<name>.parquet):
  sel-<scope>-<gran>         pick the candidate with the lowest headline error
                             (median on 5h, mean on 7d) over the training cases
                             in the same granularity: all cuts, same half
                             (cut < 0.5), or same cut; ties within 5% go to the
                             earlier-listed (simpler) candidate.
  comb-med<k>-<scope>-<gran> median of the k best candidates' shown values
  comb-invw<k>-...           mean of the k best weighted by 1/error²
  comb-med-all               median of every candidate (no learning)
  stack-nnls-<scope>-<gran>  non-negative least squares over candidates, refit
  stack-gbm                  LightGBM on candidates + context → truth − used_now
  route-gbm                  LightGBM predicting each candidate's |error| from
                             context; take the predicted best
  meta-<margin>              a third layer: the strategy above with the best
                             trailing record, switching only when better by
                             <margin>

Base candidates: every preds/*.parquet except rule-*, l2-*, *.choices (pass
--include to narrow, e.g. --include engine-).
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.optimize import nnls

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lab  # noqa: E402

HIER_MIN = 10          # cycles of own record before an account stops borrowing the pool
TIE = 0.05
MIN_TRAIN = 8          # training cases a decision needs, else fall back to rule-current


def load_matrix(include: list[str]) -> tuple[pd.DataFrame, list[str]]:
    c = lab.cases().sort_values(["t_cut", "case_id"]).reset_index(drop=True)
    names = sorted(p.stem for p in lab.PREDS.glob("*.parquet")
                   if not p.stem.startswith(("rule-", "l2-")) and not p.stem.endswith(".choices")
                   and (not include or any(p.stem.startswith(i) for i in include)))
    # Simpler first: the engine's complexity order, then everything else.
    order = ["engine-recent-rate", "engine-linear-recent", "engine-recency-weighted", "engine-saturating",
             "engine-diurnal-rate", "engine-damped-acceleration", "engine-kalman-trend"]
    names = [n for n in order if n in names] + [n for n in names if n not in order]
    for n in names:
        p = lab.read_preds(n)[["case_id", "pred"]].rename(columns={"pred": n})
        c = c.merge(p, on="case_id", how="left")
    rc = lab.read_preds("rule-current")[["case_id", "pred"]].rename(columns={"pred": "rule-current"})
    c = c.merge(rc, on="case_id", how="left")
    for n in names + ["rule-current"]:
        c[n] = np.clip(c[n], c["used_now"], 100.0)
    return c, names


def stat(err: np.ndarray, is_weekly: bool) -> float:
    if err.size == 0:
        return np.inf
    return float(np.nanmean(err) if is_weekly else np.nanmedian(err))


def run(window: str, c: pd.DataFrame, names: list[str], log) -> dict[str, np.ndarray]:
    g = c[c["window"] == window].reset_index(drop=True)
    is_weekly = lab.weekly(window)
    n = len(g)
    P = g[names].to_numpy()                       # n × m shown values (NaN = declined)
    truth = g["truth"].to_numpy()
    used = g["used_now"].to_numpy()
    E = np.abs(P - truth[:, None])
    fallback = g["rule-current"].to_numpy()
    reset = g["resets_at"].to_numpy()
    tcut = g["t_cut"].to_numpy()
    acct = g["account"].to_numpy()
    cut = g["cut"].to_numpy()
    half = cut >= 0.5
    cycles_by_acct = g.groupby("account")["resets_at"].apply(lambda s: np.sort(s.unique())).to_dict()
    out: dict[str, np.ndarray] = {}

    def train_mask(i: int, scope: str, gran: str) -> np.ndarray:
        m = reset <= tcut[i]
        if scope == "acct" or (scope == "hier" and np.searchsorted(cycles_by_acct[acct[i]], tcut[i], "right") >= HIER_MIN):
            m = m & (acct == acct[i])
        if gran == "half":
            m = m & (half == half[i])
        elif gran == "cut":
            m = m & (cut == cut[i])
        return m

    def ranked(i: int, m: np.ndarray) -> tuple[list[int], np.ndarray]:
        errs = np.array([stat(E[m, j][~np.isnan(E[m, j])], is_weekly) for j in range(len(names))])
        avail = [j for j in np.argsort(errs, kind="stable") if not np.isnan(P[i, j]) and np.isfinite(errs[j])]
        return avail, errs

    t0 = time.time()
    for scope in ("acct", "pooled", "hier"):
        for gran in ("all", "half", "cut"):
            sel = np.full(n, np.nan)
            med = {k: np.full(n, np.nan) for k in (2, 3, 5)}
            invw = {k: np.full(n, np.nan) for k in (3, 5)}
            stack = np.full(n, np.nan)
            for i in range(n):
                m = train_mask(i, scope, gran)
                if m.sum() < MIN_TRAIN:
                    continue
                avail, errs = ranked(i, m)
                if not avail:
                    continue
                best = errs[avail[0]]
                # Tie: the first-listed (simpler) candidate within 5% of the best.
                tied = [j for j in sorted(avail) if errs[j] <= best * (1 + TIE)]
                sel[i] = P[i, tied[0]]
                for k in med:
                    med[k][i] = np.median(P[i, avail[:k]])
                for k in invw:
                    w = 1.0 / np.maximum(errs[avail[:k]], 0.25) ** 2
                    invw[k][i] = np.sum(w * P[i, avail[:k]]) / np.sum(w)
                # NNLS on rows where every candidate predicted (declines filled
                # with the fallback so the system stays square).
                A = np.where(np.isnan(P[m]), fallback[m][:, None], P[m])
                if A.shape[0] >= 3 * len(names):
                    wts, _ = nnls(A, truth[m])
                    x = np.where(np.isnan(P[i]), fallback[i], P[i])
                    stack[i] = float(x @ wts)
            out[f"sel-{scope}-{gran}"] = sel
            for k, v in med.items():
                out[f"comb-med{k}-{scope}-{gran}"] = v
            for k, v in invw.items():
                out[f"comb-invw{k}-{scope}-{gran}"] = v
            out[f"stack-nnls-{scope}-{gran}"] = stack
            log(f"  {window} {scope}/{gran} done ({time.time() - t0:.0f}s)")
    out["comb-med-all"] = np.nanmedian(P, axis=1)

    # Learned second layers, retrained on a schedule (pooled, account as a feature).
    import lightgbm as lgb
    hour = (tcut % 86400) / 3600.0
    ctx = np.column_stack([cut, used, 100 - used, np.sin(hour / 24 * 2 * np.pi), np.cos(hour / 24 * 2 * np.pi),
                           pd.factorize(acct)[0]])
    step = (7 if is_weekly else 2) * 86400
    stack_gbm = np.full(n, np.nan)
    route = np.full(n, np.nan)
    Pf = np.where(np.isnan(P), fallback[:, None], P)
    next_train, model_s, model_r = -np.inf, None, None
    for i in range(n):
        if tcut[i] >= next_train:
            m = reset <= tcut[i]
            if m.sum() >= 40:
                X = np.column_stack([ctx[m], Pf[m] - used[m][:, None]])
                model_s = lgb.LGBMRegressor(objective="l1", n_estimators=200, learning_rate=0.05, num_leaves=15,
                                            min_child_samples=10, verbose=-1, n_jobs=4).fit(X, truth[m] - used[m])
                # Router: long format, one row per (case, candidate): predict |error|.
                rows = np.repeat(np.where(m)[0], len(names))
                cand = np.tile(np.arange(len(names)), m.sum())
                Xr = np.column_stack([ctx[rows], cand, Pf[rows, cand] - used[rows]])
                yr = np.abs(Pf[rows, cand] - truth[rows])
                model_r = lgb.LGBMRegressor(objective="l1", n_estimators=200, learning_rate=0.05, num_leaves=15,
                                            min_child_samples=10, verbose=-1, n_jobs=4).fit(Xr, yr)
            next_train = tcut[i] + step
        if model_s is not None:
            stack_gbm[i] = used[i] + model_s.predict(np.column_stack([ctx[i:i + 1], Pf[i:i + 1] - used[i]]))[0]
            Xq = np.column_stack([np.repeat(ctx[i:i + 1], len(names), axis=0), np.arange(len(names)),
                                  Pf[i] - used[i]])
            route[i] = Pf[i, int(np.argmin(model_r.predict(Xq)))]
    out["stack-gbm"] = stack_gbm
    out["route-gbm"] = route
    log(f"  {window} learned layers done ({time.time() - t0:.0f}s)")

    # Fill undecided cases with the shipping rule, then the third layer.
    for k in out:
        out[k] = np.where(np.isnan(out[k]), fallback, np.clip(out[k], used, 100))
    strat_names = list(out)
    S = np.column_stack([out[k] for k in strat_names])
    SE = np.abs(S - truth[:, None])
    for margin in (0.0, 0.05, 0.10):
        meta = np.copy(fallback)
        incumbent = strat_names.index("sel-acct-half") if "sel-acct-half" in strat_names else 0
        for i in range(n):
            m = (reset <= tcut[i]) & (acct == acct[i]) & (half == half[i])
            if m.sum() >= MIN_TRAIN * 2:
                errs = np.array([stat(SE[m, j], is_weekly) for j in range(len(strat_names))])
                best = int(np.argmin(errs))
                if errs[best] < errs[incumbent] * (1 - margin):
                    incumbent = best
            meta[i] = S[i, incumbent]
        out[f"meta-{int(margin * 100)}pct"] = meta
    log(f"  {window} meta done ({time.time() - t0:.0f}s)")
    return {"case_id": g["case_id"].to_numpy(), **out}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--include", nargs="*", default=[])
    ap.add_argument("--tag", default="", help="suffix for output names, e.g. -engine")
    a = ap.parse_args()
    c, names = load_matrix(a.include)
    print(f"{len(names)} base candidates: {', '.join(names)}")
    results: dict[str, list] = {}
    for window in lab.WINDOWS:
        r = run(window, c, names, print)
        ids = r.pop("case_id")
        for k, v in r.items():
            results.setdefault(k, []).append(pd.DataFrame({"case_id": ids, "pred": v}))
    for k, parts in results.items():
        lab.write_preds(f"l2-{k}{a.tag}", pd.concat(parts, ignore_index=True))
    print(f"wrote {len(results)} strategies")


if __name__ == "__main__":
    main()
