"""Shared plumbing: per-account cumulative burn grid, contexts per case, quantiles -> pred/q10/q90.
Leak-free: a case's context ends at t_cut and only uses readings with t <= t_cut."""
from __future__ import annotations
import math, sys, time
from pathlib import Path
import numpy as np, pandas as pd

LAB = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(LAB))
import lab  # noqa: E402

STEP = {"five_hour": 300.0, "seven_day": 900.0}
STALE = 2 * 3600.0
# (5h context, 7d context) in grid steps; labels used in output names
CTX = {
    "1d_1w": {"five_hour": 288, "seven_day": 7 * 96},
    "2d_2w": {"five_hour": 576, "seven_day": 14 * 96},
    "1w_4w": {"five_hour": 2016, "seven_day": 28 * 96},
}
# extra shorter contexts, run only for Timestral (issue #271: shorter beat longer)
CTX_SHORT = {
    "6h_3d": {"five_hour": 72, "seven_day": 3 * 96},
    "12h_3d": {"five_hour": 144, "seven_day": 3 * 96},
}
CTX.update(CTX_SHORT)


def cumulative(window: str) -> dict[str, tuple[np.ndarray, np.ndarray]]:
    s = lab.samples()
    s = s[s["window"] == window].sort_values("t")
    out = {}
    for acct, g in s.groupby("account"):
        ats, cs = [], []
        c, prev_key, prev_used = 0.0, None, 0.0
        for t, used, reset in zip(g["t"].to_numpy(), g["pct"].to_numpy(), g["resets_at"].to_numpy()):
            key = None if (reset is None or np.isnan(reset)) else round(reset / 60.0) * 60.0
            if key is None:
                prev_key, prev_used = None, 0.0
            elif key == prev_key:
                if used > prev_used:
                    c += used - prev_used
                    prev_used = used
            else:
                c += used
                prev_key, prev_used = key, used
            ats.append(t); cs.append(c)
        out[acct] = (np.asarray(ats), np.asarray(cs))
    return out


def contexts(window: str, n: int):
    """Returns cases df (this window), ctx (N,n) float32 with NaN gaps, h (N,) steps ceil, steps (N,) fractional."""
    c = lab.cases()
    c = c[c["window"] == window].reset_index(drop=True)
    cum = cumulative(window)
    step = STEP[window]
    ctx = np.full((len(c), n), np.nan, dtype=np.float32)
    for i, (acct, now) in enumerate(zip(c["account"], c["t_cut"])):
        if acct not in cum:
            continue
        ats, cs = cum[acct]
        t = now - step * np.arange(n - 1, -1, -1)
        idx = np.searchsorted(ats, t, side="right") - 1
        ok = idx >= 0
        ok[ok] &= (t[ok] - ats[idx[ok]]) <= STALE
        row = np.full(n, np.nan, dtype=np.float32)
        row[ok] = cs[idx[ok]]
        ctx[i] = row
    steps = ((c["resets_at"] - c["t_cut"]) / step).to_numpy()
    h = np.maximum(1, np.ceil(steps)).astype(int)
    return c, ctx, h, steps


def to_preds(c, ctx, h, steps, qfun, levels, batch=64, label="", order_by_h=True, prep=None):
    """qfun(ctx_batch (B,n), H) -> (B,H,Q) quantile trajectories of cumulative burn at `levels`."""
    levels = np.asarray(levels)
    i10, i50, i90 = (int(np.argmin(abs(levels - q))) for q in (0.1, 0.5, 0.9))
    N = len(c)
    pred = np.zeros(N); q10 = np.zeros(N); q90 = np.zeros(N)
    order = np.argsort(h) if order_by_h else np.arange(N)
    used = c["used_now"].to_numpy()
    t0 = time.perf_counter()
    for b0 in range(0, N, batch):
        ids = order[b0:b0 + batch]
        H = int(h[ids].max())
        q = qfun(prep(ctx[ids]) if prep else ctx[ids], H)
        for k, i in enumerate(ids):
            v = ctx[i]; good = v[~np.isnan(v)]
            c_last = float(good[-1]) if good.size and not np.isnan(v[-1]) else None
            st, hh = steps[i], int(h[i])
            if c_last is None:               # no usable context: no forecast beyond used_now
                pred[i] = q10[i] = q90[i] = used[i]; continue
            lo_i, hi_i = max(0, math.floor(st) - 1), hh - 1
            w = st - math.floor(st) if hi_i != lo_i else 0.0
            qh = q[k, lo_i] * (1 - w) + q[k, hi_i] * w if st >= 1 else c_last + (q[k, 0] - c_last) * st
            burn = np.maximum(np.maximum.accumulate(qh - c_last), 0.0)
            pred[i] = used[i] + burn[i50]; q10[i] = used[i] + burn[i10]; q90[i] = used[i] + burn[i90]
        if (b0 // batch) % 10 == 0:
            print(f"  {label} {b0}/{N} {time.perf_counter()-t0:.0f}s", flush=True)
    return pd.DataFrame({"case_id": c["case_id"], "pred": np.clip(pred, used, 100), "q10": np.clip(q10, used, 100), "q90": np.clip(q90, used, 100)})


def fill_gaps(x: np.ndarray) -> np.ndarray:
    """For models that cannot take NaN: interpolate inner gaps linearly, backfill leading ones (burn was flat/unknown)."""
    out = x.astype(np.float32).copy()
    for r in out:
        ok = ~np.isnan(r)
        if ok.all() or not ok.any():
            continue
        idx = np.arange(len(r))
        r[:] = np.interp(idx, idx[ok], r[ok])
    return out
