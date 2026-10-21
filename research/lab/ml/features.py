"""Build ml/features.parquet: one row per case, every feature computed from
readings with t <= t_cut and from cycles that had RESET by t_cut. No row
looks at anything after its own cut except the label columns (truth, kept
for training rows only, and gated by resets_at at training time).

Run from research/lab:  uv run python ml/features.py
"""
from __future__ import annotations

import sys
import time as _time
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lab  # noqa: E402

OUT = Path(__file__).resolve().parent / "features.parquet"
LOOKBACKS = {"five_hour": [0.25, 0.5, 1.0, 2.0], "seven_day": [3.0, 12.0, 24.0, 48.0]}  # hours
XLOOK = {"five_hour": [12.0, 48.0], "seven_day": [3.0, 12.0]}  # other window's lookbacks (h)
OTHER = {"five_hour": "seven_day", "seven_day": "five_hour"}


def interp_rate(t: np.ndarray, p: np.ndarray, t_end: float, hours: float) -> float:
    """pp/hour over the last `hours` ending at t_end (step-free linear interp,
    clamped to the first reading); 0 when there is no span."""
    if len(t) == 0:
        return 0.0
    t0 = max(t_end - hours * 3600, t[0])
    te = min(t_end, t[-1])
    if te <= t0:
        return 0.0
    v0, v1 = np.interp(t0, t, p), np.interp(te, t, p)
    return float(max(v1 - v0, 0.0) / ((te - t0) / 3600))


def hour_weights(t0: float, t1: float, grid) -> float:
    """Sum of the 7x24 activity prior over [t0, t1], fractional hours."""
    total, t = 0.0, t0
    while t < t1:
        lt = _time.localtime(t)
        nxt = min(t1, t - (lt.tm_min * 60 + lt.tm_sec) + 3600)
        wd = (lt.tm_wday + 1) % 7
        total += grid[wd][lt.tm_hour] * (nxt - t) / 3600
        t = nxt
    return total


def main() -> None:
    c = lab.cases().sort_values("t_cut").reset_index(drop=True)
    s = lab.samples()
    grids = lab.grids()
    by = {k: g.sort_values("t") for k, g in s.groupby(["window", "account"])}
    arr = {k: (g["t"].to_numpy(), g["pct"].to_numpy(), g["resets_at"].to_numpy()) for k, g in by.items()}
    # one row per completed cycle (labels known once resets_at has passed)
    cyc = c.drop_duplicates(["window", "account", "resets_at"])[["window", "account", "cycle_start", "resets_at", "truth"]]
    cyc = cyc.sort_values("resets_at")
    # same-cut label table for "what did this cut look like in past cycles"
    c["delta"] = c["truth"] - c["used_now"]
    c["frac"] = np.where(c["used_now"] < 99.5, c["delta"] / (100 - c["used_now"]).clip(lower=0.5), 0.0)

    rows = []
    for r in c.itertuples(index=False):
        w, a, tc = r.window, r.account, r.t_cut
        dur = lab.WINDOWS[w]
        t, p, rs = arr[(w, a)]
        lo, hi = np.searchsorted(t, r.cycle_start, "left"), np.searchsorted(t, tc, "right")
        m = np.abs(rs[lo:hi] - r.resets_at) < dur / 2
        tt, pp = t[lo:hi][m], p[lo:hi][m]
        f = dict(case_id=r.case_id, window=w, account=a, cut=r.cut, t_cut=tc, resets_at=r.resets_at,
                 cycle_start=r.cycle_start, used_now=r.used_now, truth=r.truth, fold=r.fold)
        f["headroom"] = 100 - r.used_now
        f["elapsed_h"] = (tc - r.cycle_start) / 3600
        f["remaining_h"] = (r.resets_at - tc) / 3600
        rates = [interp_rate(tt, pp, tc, h) for h in LOOKBACKS[w]]
        for i, v in enumerate(rates):
            f[f"rate_l{i+1}"] = v
        f["rate_cycle"] = r.used_now / max(f["elapsed_h"], 1e-3)
        f["accel"] = rates[0] - rates[2]
        f["accel_long"] = rates[1] - rates[3]
        f["proj_cycle"] = f["rate_cycle"] * f["remaining_h"]
        f["proj_l2"] = rates[1] * f["remaining_h"]
        f["n_read"] = len(tt)
        f["since_last_h"] = (tc - tt[-1]) / 3600 if len(tt) else np.nan
        # share of the last 2 lookback-windows' span with zero movement (idleness)
        span = LOOKBACKS[w][2] * 3600
        mk = tt >= tc - span
        f["idle_share"] = float(np.mean(np.diff(pp[mk]) <= 0)) if mk.sum() > 2 else np.nan
        # trajectory shape: meter at fractions of the elapsed span
        for j, q in enumerate((0.25, 0.5, 0.75, 1.0), 1):
            f[f"traj{j}"] = float(np.interp(r.cycle_start + (tc - r.cycle_start) * q, tt, pp)) if len(tt) else 0.0
        # time features (local time, as the activity prior is)
        lt = _time.localtime(tc)
        hod = lt.tm_hour + lt.tm_min / 60
        wd = (lt.tm_wday + 1) % 7
        f["hod_s"], f["hod_c"] = np.sin(2 * np.pi * hod / 24), np.cos(2 * np.pi * hod / 24)
        f["wd_s"], f["wd_c"] = np.sin(2 * np.pi * wd / 7), np.cos(2 * np.pi * wd / 7)
        g = grids.get(a, grids[""])
        f["act_remaining"] = hour_weights(tc, r.resets_at, g)
        f["act_elapsed"] = hour_weights(r.cycle_start, tc, g)
        f["act_ratio"] = r.used_now / max(f["act_elapsed"], 0.05)
        f["proj_act"] = f["act_ratio"] * f["act_remaining"]
        f["act_frac_left"] = f["act_remaining"] / max(f["act_remaining"] + f["act_elapsed"], 1e-6)
        # account history: cycles that RESET by t_cut
        pc = cyc[(cyc.window == w) & (cyc.account == a) & (cyc.resets_at <= tc)]
        fin = pc["truth"].to_numpy()
        f["n_past"] = len(fin)
        f["past_mean"] = fin.mean() if len(fin) else np.nan
        f["past_median"] = np.median(fin) if len(fin) else np.nan
        f["past_hit"] = float((fin >= 99).mean()) if len(fin) else np.nan
        f["past_prev"] = fin[-1] if len(fin) else np.nan
        f["past_last5"] = fin[-5:].mean() if len(fin) else np.nan
        # mean final of past cycles that started at a similar hour of day (+-3h circular)
        if len(pc):
            sh = np.array([_time.localtime(x).tm_hour for x in pc["cycle_start"]])
            d = np.abs(sh - _time.localtime(r.cycle_start).tm_hour)
            d = np.minimum(d, 24 - d)
            f["past_hod_mean"] = fin[d <= 3].mean() if (d <= 3).any() else np.nan
        else:
            f["past_hod_mean"] = np.nan
        # same-cut history (same account): what happened from this cut onward
        sc = c[(c.window == w) & (c.account == a) & (c.cut == r.cut) & (c.resets_at <= tc)]
        f["past_cut_delta"] = sc["delta"].mean() if len(sc) else np.nan
        f["past_cut_frac"] = sc["frac"].mean() if len(sc) else np.nan
        pa = cyc[(cyc.window == w) & (cyc.resets_at <= tc)]
        f["pool_past_mean"] = pa["truth"].mean() if len(pa) else np.nan
        # cross-window: the other window of the same account at the same cut
        ow = OTHER[w]
        ot, op, ors = arr.get((ow, a), (np.array([]),) * 3)
        k = np.searchsorted(ot, tc, "right")
        if k:
            stale = ors[k - 1] <= tc
            f["x_level"] = 0.0 if stale else op[k - 1]
            odur = lab.WINDOWS[ow]
            f["x_elapsed_frac"] = np.nan if stale else 1 - (ors[k - 1] - tc) / odur
            sl = max(0, k - 400)
            seg_t, seg_p = ot[sl:k], op[sl:k]
            for i, h in enumerate(XLOOK[w], 1):
                f[f"x_rate_l{i}"] = interp_rate(seg_t, seg_p, tc, h) if not stale else 0.0
            f["x_age_h"] = (tc - ot[k - 1]) / 3600
        else:
            for kx in ("x_level", "x_elapsed_frac", "x_rate_l1", "x_rate_l2", "x_age_h"):
                f[kx] = np.nan
        # concurrent burn on the OTHER accounts, same window, same lookback as l2
        oth = 0.0
        for a2 in {k2[1] for k2 in arr if k2[0] == w and k2[1] != a}:
            t2, p2, _ = arr[(w, a2)]
            k2 = np.searchsorted(t2, tc, "right")
            sl = max(0, k2 - 200)
            oth += interp_rate(t2[sl:k2], p2[sl:k2], tc, LOOKBACKS[w][1])
        f["others_rate_l2"] = oth
        rows.append(f)
    F = pd.DataFrame(rows)
    # engine predictions as (leak-free) delta features
    eng = None
    for pth in sorted(lab.PREDS.glob("engine-*.parquet")):
        e = lab.read_preds(pth.stem)[["case_id", "pred"]].rename(columns={"pred": "e"})
        e = e.merge(F[["case_id", "used_now"]], on="case_id")
        e[pth.stem.replace("engine-", "eng_d_").replace("-", "_")] = np.clip(e["e"], e["used_now"], 100) - e["used_now"]
        e = e.drop(columns=["e", "used_now"])
        eng = e if eng is None else eng.merge(e, on="case_id", how="outer")
    F = F.merge(eng, on="case_id", how="left")
    ec = [x for x in F.columns if x.startswith("eng_d_")]
    F["eng_med"], F["eng_min"], F["eng_max"] = F[ec].median(axis=1), F[ec].min(axis=1), F[ec].max(axis=1)
    F["eng_spread"] = F["eng_max"] - F["eng_min"]
    F["delta"] = F["truth"] - F["used_now"]
    F["is_7d"] = (F["window"] == "seven_day").astype(float)
    for i, a in enumerate(sorted(F["account"].unique())):
        F[f"acct{i}"] = (F["account"] == a).astype(float)
    F.to_parquet(OUT, index=False)
    print(F.shape, "->", OUT)
    print(F.isna().mean().sort_values(ascending=False).head(12).to_string())


if __name__ == "__main__":
    main()
