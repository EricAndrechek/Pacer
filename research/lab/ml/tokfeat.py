"""Token-derived features -> ml/tokfeatures.parquet (keyed by case_id).

Weights (pp per M tokens, per model family x token kind) are fit by NNLS on
meter-rise intervals whose END is <= the retrain time T of the case's epoch
(same epoch grid as run.py: 5h 2 days, 7d 1 day, anchored at the window's first
resets_at). Per account when it has >= 200 such intervals, else pooled.
Features use turns with t <= t_cut only.

Run from research/lab:  uv run python ml/tokfeat.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.optimize import nnls

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE.parent / "tokens"))
import lab  # noqa: E402
import meter_from_tokens as mt  # noqa: E402

PERIOD = {"five_hour": 2 * 86400.0, "seven_day": 86400.0}
LB = {"five_hour": [0.25, 1.0, 3.0], "seven_day": [3.0, 12.0, 24.0]}
FAM = ("fable", "opus", "sonnet", "haiku", "other")


def main() -> None:
    tok = pd.read_parquet(lab.DATA / "tokens.parquet").sort_values("t").reset_index(drop=True)
    tok["family"] = tok["model"].map(mt.family)
    cols = [f"{f}:{k}" for f in FAM for k in mt.KINDS]
    M = np.zeros((len(tok), len(cols)))
    for j, col in enumerate(cols):
        f, k = col.split(":")
        M[:, j] = np.where(tok["family"] == f, tok[k].fillna(0).to_numpy(), 0.0) / 1e6
    tacct = tok["account"].to_numpy()
    tsess = tok["session"].to_numpy()
    tt_all = tok["t"].to_numpy()
    per = {}
    for a in np.unique(tacct):
        idx = np.where(tacct == a)[0]
        per[a] = dict(t=tt_all[idx], M=M[idx], cum=np.vstack([np.zeros(M.shape[1]), np.cumsum(M[idx], 0)]),
                      sess=tsess[idx])
    F = pd.read_parquet(HERE / "features.parquet")[["case_id", "window", "account", "t_cut", "resets_at", "cycle_start",
                                                    "used_now", "rate_l2", "remaining_h"]]
    cases_all = lab.cases()
    out = []
    for window in lab.WINDOWS:
        iv = mt.intervals(window)
        X, _ = mt.token_features(iv)
        y = iv["rise"].to_numpy()
        t1 = iv["t1"].to_numpy()
        ia = iv["account"].to_numpy()
        sub = F[F["window"] == window].copy()
        t_first = sub["resets_at"].min()
        sub["k"] = np.floor((sub["t_cut"] - t_first) / PERIOD[window]).astype(int)
        sa = lab.samples()
        sa = sa[sa["window"] == window].sort_values("t")
        sarr = {a: g for a, g in sa.groupby("account")}
        wcache = {}
        for k, g in sub.groupby("k"):
            T = t_first + k * PERIOD[window]
            m_all = t1 <= T
            wp = nnls(X[m_all], y[m_all])[0] if m_all.sum() >= 200 else None
            W = {}
            for a in g["account"].unique():
                m = m_all & (ia == a)
                W[a] = nnls(X[m], y[m])[0] if m.sum() >= 200 else wp
            for r in g.itertuples(index=False):
                f = dict(case_id=r.case_id)
                w = W.get(r.account)
                d = per.get(r.account)
                if w is None or d is None:
                    out.append(f)
                    continue
                tc = r.t_cut
                t, cum = d["t"], d["cum"]
                hi = np.searchsorted(t, tc, "right")

                def pts(t0):
                    lo = np.searchsorted(t, t0, "right")
                    return float((cum[hi] - cum[lo]) @ w) if hi > lo else 0.0
                for i, h in enumerate(LB[window], 1):
                    f[f"tok_l{i}"] = pts(tc - h * 3600)
                    f[f"tok_rate_l{i}"] = f[f"tok_l{i}"] / h
                f["tok_cycle"] = pts(r.cycle_start)
                # nowcast: tokens since the meter's last reading before the cut
                s = sarr[r.account]
                ks = np.searchsorted(s["t"].to_numpy(), tc, "right")
                t_last = s["t"].to_numpy()[ks - 1] if ks else tc
                f["tok_nowcast_gap"] = pts(t_last)
                f["tok_nowcast_h"] = (tc - t_last) / 3600
                f["tok_nowcast"] = min(r.used_now + f["tok_nowcast_gap"], 100.0)
                # concurrency
                for mins in (10, 30):
                    lo = np.searchsorted(t, tc - mins * 60, "right")
                    ss = d["sess"][lo:hi]
                    f[f"sess_{mins}m"] = float(len(set(ss)))
                    f[f"sess_burn_{mins}m"] = float((cum[hi] - cum[lo]) @ w) / (mins / 60) if hi > lo else 0.0
                lo = np.searchsorted(t, tc - 3600, "right")
                f["sess_60m"] = float(len(set(d["sess"][lo:hi])))
                lo = np.searchsorted(t, tc - 1800, "right")
                act = set(d["sess"][lo:hi])
                if act:
                    first = {}
                    # first turn of each active session on this account (<= tc by construction)
                    for sid in act:
                        first[sid] = t[d["sess"] == sid].min()
                    ages = np.array([(tc - v) / 3600 for v in first.values()])
                    f["sess_age_mean_h"], f["sess_age_max_h"] = float(ages.mean()), float(ages.max())
                else:
                    f["sess_age_mean_h"] = f["sess_age_max_h"] = 0.0
                # calibration: token-implied vs observed meter over the cycle so far
                f["tok_calib"] = f["tok_cycle"] / max(r.used_now, 1.0)
                f["tok_unexplained"] = r.used_now - f["tok_cycle"]
                f["tok_proj"] = f["tok_rate_l2"] * r.remaining_h
                f["tok_vs_meter_rate"] = f["tok_rate_l2"] - r.rate_l2
                out.append(f)
    T = pd.DataFrame(out)
    T.to_parquet(HERE / "tokfeatures.parquet", index=False)
    print(T.shape, T.isna().mean().round(3).to_dict())


if __name__ == "__main__":
    main()
