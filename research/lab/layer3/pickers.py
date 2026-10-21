"""A stronger second layer (p2-*) and a picker of pickers (p3-*), walk-forward.

The night's second layer (layer2/layer2.py) was a quick pass; the plain median
beat every learned picker in it. This is the serious attempt, on a curated pool
of ~20 good base candidates per window.

Second layer, p2-* (each case decides from cases of cycles reset before it):
  trim<k>             trimmed mean: drop the k highest and k lowest answers
  medbias-<scope>     median + the median residual at this cut over training cases
  ewinvw5-<H>-<scope> top 5 by an exponentially weighted error (half-life H
                      windows of that account's record), weighted 1/err²
  ewsel-<H>-<scope>   the single best by that recency-weighted error
  shrink<a>-<scope>   NNLS blend weights, normalised, shrunk toward equal
                      weights by a (the forecast-combination puzzle's fix)
  median              the plain median of the pool (the bar to beat)
scope: acct (own account), pooled (every account), hier (own once it has
HIER_MIN windows, pooled before). Decisions are per half of the window.

Third layer, p3-*: picks one second-layer strategy per case, from a curated
set that includes the median, by each strategy's recent record. Variants:
trailing window (last K completed windows, or a half-life), scope, per half,
and a switching margin (hysteresis). p3-oracle is the best strategy per case
in hindsight: the ceiling no real picker can reach.

  uv run layer3/pickers.py
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.optimize import nnls

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lab  # noqa: E402

HIER_MIN = 10
POOL = {
    "five_hour": ["engine-recent-rate", "engine-linear-recent", "engine-recency-weighted", "engine-saturating",
                  "engine-diurnal-rate", "engine-damped-acceleration", "engine-kalman-trend",
                  "tokc-decay-30m", "tokc-rate-30m-cal", "tok-decay-30m", "tok-rate-30m-cal",
                  "fm-timestral-5m-6h_3d", "fm-timestral-28m-6h_3d", "fm-timestral-123m-6h_3d",
                  "fm-timestral-209m-1d_1w", "fm-toto-151m-2d_2w", "fm-tirex-35m-1d_1w", "fm-timesfm25-200m-2d_2w",
                  "ml-linqr-delta-pooled-acct-stacked-tok-cal", "ml-lgbm-delta-pooled-acct-stacked-tok-cal"],
    "seven_day": ["engine-recent-rate", "engine-linear-recent", "engine-recency-weighted", "engine-saturating",
                  "engine-diurnal-rate", "engine-damped-acceleration", "engine-kalman-trend",
                  "tokc-rate-1d-cal", "tokc-rate-6h-cal", "tokc-decay-6h", "tokc-decay-1d", "tok-rate-1d-cal",
                  "fm-timestral-5m-1w_4w", "fm-timestral-28m-1w_4w", "fm-timestral-209m-1w_4w", "fm-toto-151m-1w_4w",
                  "ml-linqr-frac-pooled-acct-stacked-cal", "ml-lgbm-frac-pooled-tok-cal"],
}


def stat(e: np.ndarray, weekly: bool, w: np.ndarray | None = None) -> float:
    e = np.asarray(e, float)
    ok = ~np.isnan(e)
    if not ok.any():
        return np.inf
    e = e[ok]
    if w is None:
        return float(e.mean() if weekly else np.median(e))
    w = w[ok]
    if weekly:
        return float(np.sum(w * e) / np.sum(w))
    o = np.argsort(e)
    cw = np.cumsum(w[o])
    return float(e[o][np.searchsorted(cw, cw[-1] / 2)])           # weighted median


class Walk:
    """Training-set masks for one window: cases of cycles reset before t_cut."""

    def __init__(self, g: pd.DataFrame):
        self.reset = g["resets_at"].to_numpy()
        self.tcut = g["t_cut"].to_numpy()
        self.acct = g["account"].to_numpy()
        self.half = g["cut"].to_numpy() >= 0.5
        self.cut = g["cut"].to_numpy()
        self.cycles = {a: np.sort(x.unique()) for a, x in g.groupby("account")["resets_at"]}
        # Each case's cycle index within its account (recency weights count windows).
        self.cyc_idx = np.array([np.searchsorted(self.cycles[a], r) for a, r in zip(self.acct, self.reset)])

    def mask(self, i: int, scope: str, by_half: bool = True) -> np.ndarray:
        m = self.reset <= self.tcut[i]
        own = np.searchsorted(self.cycles[self.acct[i]], self.tcut[i], "right")
        if scope == "acct" or (scope == "hier" and own >= HIER_MIN):
            m = m & (self.acct == self.acct[i])
        if by_half:
            m = m & (self.half == self.half[i])
        return m


def second_layer(window: str, g: pd.DataFrame, names: list[str], log) -> dict[str, np.ndarray]:
    weekly = lab.weekly(window)
    P = np.clip(g[names].to_numpy(), g["used_now"].to_numpy()[:, None], 100)
    truth, used = g["truth"].to_numpy(), g["used_now"].to_numpy()
    E = np.abs(P - truth[:, None])
    n, k = P.shape
    wk = Walk(g)
    dur = lab.WINDOWS[window]
    out: dict[str, np.ndarray] = {}
    med = np.nanmedian(P, axis=1)
    out["median"] = med
    srt = np.sort(np.where(np.isnan(P), np.nan, P), axis=1)
    cnt = (~np.isnan(P)).sum(axis=1)
    for t in (1, 2, 3):
        v = np.full(n, np.nan)
        for i in range(n):
            row = srt[i, :cnt[i]]
            if len(row) > 2 * t:
                v[i] = row[t:len(row) - t].mean()
        out[f"trim{t}"] = v
    t0 = time.time()
    for scope in ("acct", "pooled", "hier"):
        mb = np.full(n, np.nan)
        res = {H: (np.full(n, np.nan), np.full(n, np.nan)) for H in (10, 30)}
        shr = {a: np.full(n, np.nan) for a in (0.25, 0.5, 0.75)}
        for i in range(n):
            m = wk.mask(i, scope)
            if m.sum() < 16:
                continue
            same_cut = m & (wk.cut == wk.cut[i])
            if same_cut.sum() >= 8:
                mb[i] = med[i] + np.median(truth[same_cut] - med[same_cut])
            # Recency weights: this account's windows count back in windows,
            # other accounts' cases by elapsed time in window lengths.
            own = wk.acct[m] == wk.acct[i]
            age = np.where(own, np.searchsorted(wk.cycles[wk.acct[i]], wk.tcut[i], "right") - wk.cyc_idx[m],
                           (wk.tcut[i] - wk.reset[m]) / dur)
            avail = ~np.isnan(P[i])
            for H in (10, 30):
                w = 0.5 ** (np.maximum(age, 0) / H)
                errs = np.array([stat(E[m, j], weekly, w) if avail[j] else np.inf for j in range(k)])
                order = np.argsort(errs)
                top = [j for j in order[:5] if np.isfinite(errs[j])]
                if top:
                    ww = 1.0 / np.maximum(errs[top], 0.25) ** 2
                    res[H][0][i] = np.sum(ww * P[i, top]) / ww.sum()
                    res[H][1][i] = P[i, top[0]]
            A = np.where(np.isnan(P[m]), med[m][:, None], P[m])
            if A.shape[0] >= 3 * k:
                wts, _ = nnls(A, truth[m])
                s = wts.sum()
                if s > 0:
                    wts = wts / s
                    x = np.where(np.isnan(P[i]), med[i], P[i])
                    for a in shr:
                        shr[a][i] = x @ ((1 - a) * wts + a / k)
        out[f"medbias-{scope}"] = mb
        for H, (iv, sl) in res.items():
            out[f"ewinvw5-{H}-{scope}"] = iv
            out[f"ewsel-{H}-{scope}"] = sl
        for a, v in shr.items():
            out[f"shrink{int(a * 100)}-{scope}"] = v
        log(f"  {window} p2 {scope} ({time.time() - t0:.0f}s)")
    Pf = np.where(np.isnan(P), med[:, None], P)
    for scope in ("acct", "pooled", "hier"):
        for eta in (0.3, 1.0, 3.0):
            for alpha in (0.0, 0.02, 0.1):
                tag = "hedge" if alpha == 0 else f"fs{int(alpha * 100)}"
                a, p, _ = online_experts(Pf, truth, wk, scope, eta, alpha)
                out[f"{tag}-avg-e{eta:g}-{scope}"] = a
                out[f"{tag}-pick-e{eta:g}-{scope}"] = p
    log(f"  {window} p2 online experts ({time.time() - t0:.0f}s)")
    for key in out:
        out[key] = np.where(np.isnan(out[key]), med, np.clip(out[key], used, 100))
    return out


def online_experts(M: np.ndarray, truth: np.ndarray, wk: Walk, scope: str, eta: float, alpha: float,
                   by_half: bool = True) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Hedge (alpha 0) and Fixed-Share (alpha > 0) over the columns of M,
    updated once per completed window with that window's losses.

    Hedge is the textbook way to choose among forecasters online: its
    cumulative loss provably stays within O(sqrt(T log k)) of the best single
    forecaster in hindsight. Fixed-Share mixes a share alpha of the weight back
    to uniform after every update, so it can follow a best forecaster that
    changes over time instead of locking on to an early leader.

    Loss is the absolute miss in units of 10 pp, capped at 3, summed over the
    window's cases (per half when by_half). Returns (weighted average, pick of
    the heaviest) for every case, each computed only from windows that had
    reset before the case's cut."""
    n, k = M.shape
    loss = np.minimum(np.abs(M - truth[:, None]) / 10.0, 3.0)
    halves = (False, True) if by_half else (None,)
    avg = np.full(n, np.nan)
    pick = np.full(n, np.nan)
    chosen = np.zeros(n, int)
    keys = {"acct": sorted(set(wk.acct)), "pooled": [None]}
    states: dict = {}
    for a in keys["acct"] + [None]:
        for h in halves:
            sel = np.ones(n, bool) if a is None else (wk.acct == a)
            if h is not None:
                sel &= wk.half == h
            ev_reset, ev_rows = [], []
            for (acct_, r), idx in pd.Series(np.where(sel)[0]).groupby([wk.acct[sel], wk.reset[sel]]):
                ev_reset.append(r)
                ev_rows.append(idx.to_numpy())
            order = np.argsort(ev_reset, kind="stable")
            ev_reset = np.asarray(ev_reset)[order]
            w = np.full(k, 1.0 / k)
            W = np.empty((len(order), k))
            for t, o in enumerate(order):
                w = w * np.exp(-eta * loss[ev_rows[o]].sum(axis=0))
                w = w / w.sum()
                if alpha:
                    w = (1 - alpha) * w + alpha / k
                W[t] = w
            states[(a, h)] = (ev_reset, W)
    for i in range(n):
        own = np.searchsorted(wk.cycles[wk.acct[i]], wk.tcut[i], "right")
        a = wk.acct[i] if scope == "acct" or (scope == "hier" and own >= HIER_MIN) else None
        ev_reset, W = states[(a, wk.half[i] if by_half else None)]
        t = np.searchsorted(ev_reset, wk.tcut[i], "right") - 1
        w = W[t] if t >= 0 else np.full(k, 1.0 / k)
        avg[i] = w @ M[i]
        chosen[i] = int(np.argmax(w))
        pick[i] = M[i, chosen[i]]
    return avg, pick, chosen


def hindsight(M: np.ndarray, g: pd.DataFrame, weekly: bool) -> dict[str, np.ndarray]:
    """Ceilings no real picker can reach: the best single strategy in
    hindsight overall, per account, and per account and half."""
    truth = g["truth"].to_numpy()
    E = np.abs(M - truth[:, None])
    n = len(g)
    out = {}
    for name, groups in (("all", np.zeros(n, int)), ("acct", pd.factorize(g["account"])[0]),
                         ("acct-half", pd.factorize(g["account"].astype(str) + (g["cut"] >= 0.5).astype(str))[0])):
        p = np.empty(n)
        for gid in np.unique(groups):
            m = groups == gid
            best = int(np.argmin([stat(E[m, j], weekly) for j in range(M.shape[1])]))
            p[m] = M[m, best]
        out[f"hindsight-{name}"] = p
    out["hindsight-case"] = M[np.arange(n), np.argmin(E, axis=1)]
    return out


def third_layer(window: str, g: pd.DataFrame, S: dict[str, np.ndarray], log,
                choices: dict | None = None) -> dict[str, np.ndarray]:
    """Pick one strategy per case by its recent record. `choices` collects,
    for the report, which strategy the Hedge pickers chose in each case."""
    weekly = lab.weekly(window)
    names = list(S)
    M = np.column_stack([S[nm] for nm in names])
    truth = g["truth"].to_numpy()
    SE = np.abs(M - truth[:, None])
    n = len(g)
    wk = Walk(g)
    dur = lab.WINDOWS[window]
    base = names.index("median")
    out: dict[str, np.ndarray] = {}
    out["oracle"] = M[np.arange(n), np.argmin(SE, axis=1)]           # hindsight ceiling
    out.update(hindsight(M, g, weekly))
    t0 = time.time()
    for scope in ("acct", "pooled", "hier"):
        for eta in (0.3, 1.0, 3.0):
            for alpha in (0.0, 0.02, 0.1):
                tag = "hedge" if alpha == 0 else f"fs{int(alpha * 100)}"
                a, p, ch = online_experts(M, truth, wk, scope, eta, alpha)
                out[f"{tag}-avg-e{eta:g}-{scope}"] = a
                out[f"{tag}-pick-e{eta:g}-{scope}"] = p
                if choices is not None and eta == 1.0 and alpha in (0.0, 0.1):
                    choices[f"{tag}-pick-e1-{scope}"] = [names[j] for j in ch]
        for look in ("all", "last10", "last25", "hl10", "hl30"):
            picks = {mg: np.full(n, base) for mg in (0.0, 0.05, 0.10)}
            incumbent = {mg: {} for mg in picks}
            for i in range(n):
                m = wk.mask(i, scope)
                if m.sum() < 16:
                    continue
                own = wk.acct[m] == wk.acct[i]
                age = np.where(own, np.searchsorted(wk.cycles[wk.acct[i]], wk.tcut[i], "right") - wk.cyc_idx[m],
                               (wk.tcut[i] - wk.reset[m]) / dur)
                w = None
                mm = m.copy()
                if look.startswith("last"):
                    K = int(look[4:])
                    keep = age <= K
                    if keep.sum() >= 16:
                        idx = np.where(m)[0][keep]
                        mm = np.zeros(n, bool)
                        mm[idx] = True
                        age = age[keep]
                elif look.startswith("hl"):
                    w = 0.5 ** (np.maximum(age, 0) / int(look[2:]))
                errs = np.array([stat(SE[mm, j], weekly, w) for j in range(len(names))])
                best = int(np.argmin(errs))
                key = (wk.acct[i], wk.half[i])
                for mg in picks:
                    inc = incumbent[mg].get(key, base)
                    if errs[best] < errs[inc] * (1 - mg):
                        inc = best
                    incumbent[mg][key] = inc
                    picks[mg][i] = inc
            for mg, p in picks.items():
                out[f"{scope}-{look}-m{int(mg * 100)}"] = M[np.arange(n), p]
        log(f"  {window} p3 {scope} ({time.time() - t0:.0f}s)")
    return out


def main() -> None:
    c = lab.cases().sort_values(["t_cut", "case_id"]).reset_index(drop=True)
    results: dict[str, list] = {}
    picks: dict = {}
    for window, names in POOL.items():
        names = [nm for nm in names if (lab.PREDS / f"{nm}.parquet").exists()]
        g = c[c["window"] == window].reset_index(drop=True)
        for nm in names:
            g = g.merge(lab.read_preds(nm)[["case_id", "pred"]].rename(columns={"pred": nm}), on="case_id", how="left")
        print(f"{window}: {len(names)} base candidates, {len(g)} cases")
        S = second_layer(window, g, names, print)
        # The third layer chooses among a curated set of genuinely different
        # pickers, the median included, plus the shipping rule and the best
        # single model of the window.
        rc = g[["case_id"]].merge(lab.read_preds("rule-current")[["case_id", "pred"]], on="case_id", how="left")["pred"].to_numpy()
        best_single = "tokc-decay-30m" if window == "five_hour" else "tokc-rate-1d-cal"
        curated = {k: S[k] for k in ("median", "trim2", "medbias-hier", "ewinvw5-30-hier", "ewsel-30-hier",
                                     "shrink50-pooled") if k in S}
        curated["rule-current"] = np.clip(rc, g["used_now"], 100)
        curated[best_single] = np.clip(g[best_single].to_numpy(), g["used_now"], 100)
        # A gap in any input would make an averaged pick a gap too, and a
        # strategy scored on the easier subset it does answer looks better
        # than it is; the median's answer stands in, as in the second layer.
        curated = {k: np.where(np.isnan(v), S["median"], v) for k, v in curated.items()}
        ch: dict = {}
        T = third_layer(window, g, curated, print, ch)
        picks[window] = {"strategies": list(curated), "fold": g["fold"].tolist(), "account_record":
                         [int(np.searchsorted(np.sort(g.loc[g["account"] == a, "resets_at"].unique()), t, "right"))
                          for a, t in zip(g["account"], g["t_cut"])], "choices": ch}
        for k, v in S.items():
            results.setdefault(f"p2-{k}", []).append(pd.DataFrame({"case_id": g["case_id"], "pred": v}))
        for k, v in T.items():
            results.setdefault(f"p3-{k}", []).append(pd.DataFrame({"case_id": g["case_id"], "pred": v}))
    for k, parts in results.items():
        lab.write_preds(k, pd.concat(parts, ignore_index=True))
    (lab.HERE / "reports").mkdir(exist_ok=True)
    (lab.HERE / "reports" / "picks.json").write_text(__import__("json").dumps(picks))
    print(f"wrote {len(results)} strategies")


if __name__ == "__main__":
    main()
