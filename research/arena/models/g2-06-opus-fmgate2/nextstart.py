"""cycle.next_start: when an idle five-hour window starts again (the account's
next turn), as sampled start times, NaN for "not before the horizon".

Analogues from the account's own past: every moment m (on a 15-minute grid)
where the account had been idle at least as long as it has now (capped), and
whose next turn is known, gives a waiting time `next_turn(m) - m`. Each is
weighted by how alike m is to now: the local time of day (Gaussian kernel),
the same weekday, how recent, and whether another account was busy at the
time (the user may be working elsewhere). The paths are draws from that
weighted sample, lightly jittered. With little history the sample is pooled
with a broad prior (an exponential wait).
"""
from __future__ import annotations

import numpy as np
import polars as pl

HOUR_MS = 3_600_000
DAY_MS = 24 * HOUR_MS
MIN_MS = 60_000


def _turn_times(history, accounts=None) -> dict[str, np.ndarray]:
    t = history.table("turns").filter(pl.col("model") != "<synthetic>")
    if accounts is not None:
        t = t.filter(pl.col("account").is_in(list(accounts)))
    out = {}
    for (a,), g in t.group_by(["account"]):
        out[a] = np.sort(g["t_event"].dt.epoch("ms").to_numpy().astype(np.int64))
    return out


def forecast_next_start(history, now: int, tr, cfg: dict, rng) -> np.ndarray:
    acct = tr.accounts[0]
    horizon = int(tr.grid[-1])
    n = tr.n_paths
    turns = _turn_times(history)
    mine = turns.get(acct, np.zeros(0, np.int64))
    mine = mine[mine <= now]
    others = [v[v <= now] for a, v in turns.items() if a != acct]
    others = np.sort(np.concatenate(others)) if others else np.zeros(0, np.int64)
    tz = int(history.tz_offset_min or 0) * MIN_MS
    prior_mean_h = float(cfg.get("prior_mean_h", 8.0))
    max_h = (horizon - now) / HOUR_MS
    gap_now = (now - mine[-1]) if len(mine) else 10 * DAY_MS
    gap_cap = float(cfg.get("gap_cap_h", 8.0)) * HOUR_MS
    g_need = min(gap_now, gap_cap)
    other_busy_now = bool(len(others) and now - others[-1] < float(cfg.get("busy_min", 30)) * MIN_MS)
    waits, weights = np.zeros(0), np.zeros(0)
    if len(mine) >= 2:
        step = int(cfg.get("grid_min", 15)) * MIN_MS
        start = int(mine[0])
        m = np.arange(now - step, start, -step, dtype=np.int64)
        if len(m):
            j = np.searchsorted(mine, m, side="right")            # first turn after m
            prev = np.where(j > 0, mine[np.maximum(j - 1, 0)], start - 10 * DAY_MS)
            has_next = j < len(mine)
            nxt = np.where(has_next, mine[np.minimum(j, len(mine) - 1)], 0)
            idle_ok = (m - prev) >= g_need
            # censored: no turn after m seen by now; keep only if the wait already passes the horizon span
            span = (now - m)
            cens = ~has_next
            keep = idle_ok & (has_next | (span > max_h * HOUR_MS))
            wait = np.where(has_next, (nxt - m) / HOUR_MS, np.inf)
            wait = np.where(cens, np.inf, wait)
            # similarity
            tod_now = ((now + tz) % DAY_MS) / HOUR_MS
            tod_m = ((m + tz) % DAY_MS) / HOUR_MS
            d = np.abs(tod_m - tod_now)
            d = np.minimum(d, 24 - d)
            sig = float(cfg.get("tod_sigma_h", 1.0))
            w = np.exp(-0.5 * (d / sig) ** 2)
            dow_now = ((now + tz) // DAY_MS) % 7
            dow_m = ((m + tz) // DAY_MS) % 7
            w = w * np.where(dow_m == dow_now, float(cfg.get("same_dow_w", 2.0)), 1.0)
            age_d = (now - m) / DAY_MS
            w = w * np.exp(-age_d / float(cfg.get("age_tau_d", 21.0)))
            if len(others):
                jo = np.searchsorted(others, m, side="right")
                last_o = np.where(jo > 0, others[np.maximum(jo - 1, 0)], -10 * DAY_MS)
                busy = (m - last_o) < float(cfg.get("busy_min", 30)) * MIN_MS
                w = w * np.where(busy == other_busy_now, 1.0, float(cfg.get("busy_mismatch_w", 0.4)))
            waits, weights = wait[keep], w[keep]
    # prior: exponential wait, worth `prior_n` analogues
    prior_n = float(cfg.get("prior_n", 3.0))
    eff = weights.sum() ** 2 / max((weights ** 2).sum(), 1e-12) if len(weights) else 0.0
    p_prior = prior_n / (prior_n + eff)
    u = rng.random(n)
    out = np.empty(n)
    from_prior = u < p_prior
    out[from_prior] = rng.exponential(prior_mean_h, size=int(from_prior.sum()))
    k = int((~from_prior).sum())
    if k:
        p = weights / weights.sum()
        draw = waits[rng.choice(len(waits), size=k, p=p)]
        jit = rng.uniform(-0.25, 0.25, size=k) * float(cfg.get("jitter_h", 1.0))
        out[~from_prior] = np.maximum(draw + jit, 0.0)
    t = now + out * HOUR_MS
    t = np.where(out <= max_h, t, np.nan)
    return t[:, None]
