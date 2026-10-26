"""Account-state gating of meter paths.

A meter only rises while its account is in use. Turns are known seconds
after they happen, so at `now` we know how long the account has been idle
(`d`), whether another account of the user is busy, and whether the account
is blocked (a window at 100 % until its reset). From the account's own past
idle stretches we draw, per path, when its use resumes (`tau`): the residual
of past idle stretches that had already lasted about `d`, weighted by
recency, local hour and whether another account was busy then. A base
model's path is then held at the current value until `tau` and follows the
base's own rise afterwards (time-shifted or increment-cut, by config).
"""
from __future__ import annotations

import numpy as np
import polars as pl

from arena.pricing import SYNTHETIC_MODEL

MIN = 60_000
HOUR = 60 * MIN
DAY = 24 * HOUR
INF = np.inf

FAMILY_OF_CAP = {"fable": "fable", "opus": "opus", "sonnet": "sonnet", "haiku": "haiku"}


def cap_family(cap):
    if not cap:
        return None
    c = str(cap).lower()
    for k, v in FAMILY_OF_CAP.items():
        if k in c:
            return v
    return None


class TurnBook:
    """Turn times per account (and per family), from one History."""

    def __init__(self, history):
        t = history.table("turns")
        self.by = {}
        if t.height:
            t = t.filter(pl.col("model") != SYNTHETIC_MODEL).select(
                "account", "model_family", pl.col("t_event").dt.epoch("ms").alias("t"))
            for (a, f), g in t.group_by(["account", "model_family"]):
                self.by[(a, f)] = np.sort(g["t"].to_numpy().astype(np.int64))
        self.accounts = sorted({k[0] for k in self.by if k[0] is not None})

    def times(self, account, family=None):
        if family is not None:
            return self.by.get((account, family), np.zeros(0, np.int64))
        parts = [v for k, v in self.by.items() if k[0] == account]
        return np.sort(np.concatenate(parts)) if parts else np.zeros(0, np.int64)

    def others(self, account):
        parts = [v for k, v in self.by.items() if k[0] != account and k[0] is not None]
        return np.sort(np.concatenate(parts)) if parts else np.zeros(0, np.int64)


def idle_ms(T, now):
    i = np.searchsorted(T, now, side="right") - 1
    return float(now - T[i]) if i >= 0 else INF


def local_hour(t, tz_ms):
    return ((np.asarray(t, dtype=np.float64) + tz_ms) % DAY) / HOUR


def sample_resume(T, other, now, d, tz_ms, n, rng, cfg):
    """Draw `n` waits (ms from now) until the account's next own turn, given
    it has been idle `d` ms. Empirical residuals of past gaps longer than d,
    weighted; the account's own gaps only (the ongoing gap is excluded)."""
    if len(T) < 20 or not np.isfinite(d):
        return None
    g0 = T[:-1]
    gap = np.diff(T).astype(np.float64)
    keep = gap > d
    if keep.sum() < int(cfg.get("min_gaps", 8)):
        return None
    s = g0[keep].astype(np.float64)
    resid = gap[keep] - d
    at = s + d                                   # the moment matching `now` in each past gap
    age_d = (now - at) / DAY
    w = np.exp(-np.maximum(age_d, 0) / float(cfg.get("recency_days", 30)))
    hd = np.abs(local_hour(at, tz_ms) - local_hour(now, tz_ms))
    hd = np.minimum(hd, 24 - hd)
    w = w * np.exp(-0.5 * (hd / float(cfg.get("bw_hour", 2.5))) ** 2)
    # long gaps: weight by the gap's log-closeness too (idle 5 min vs 5 h differ)
    if len(other) and cfg.get("other_weight", 3.0) != 1.0:
        busy_now = idle_ms(other, now) < float(cfg.get("other_busy_min", 10)) * MIN
        j = np.searchsorted(other, at, side="right") - 1
        busy_then = (j >= 0) & ((at - other[np.maximum(j, 0)]) < float(cfg.get("other_busy_min", 10)) * MIN)
        w = w * np.where(busy_then == busy_now, float(cfg.get("other_weight", 3.0)), 1.0)
    if w.sum() <= 0 or not np.isfinite(w.sum()):
        return None
    p = w / w.sum()
    idx = rng.choice(len(resid), size=n, p=p)
    # jitter within the residual's scale so ties don't stack exactly
    r = resid[idx] * np.exp(rng.normal(0, float(cfg.get("jitter", 0.15)), n))
    return r


def blocked_until(history, account, now, windows=("five_hour", "seven_day")):
    """The latest reset among this account's windows that read ~100 % now
    (a reading in the current cycle); 0 when none blocks."""
    r = history.table("meter_readings")
    if not r.height:
        return 0
    r = r.filter((pl.col("account") == account) & pl.col("window_kind").is_in(list(windows))
                 & (pl.col("state") == "active"))
    if not r.height:
        return 0
    r = r.with_columns(pl.col("t_event").dt.epoch("ms").alias("te"),
                       pl.col("resets_at").dt.epoch("ms").alias("rs"))
    out = 0
    for wk in windows:
        g = r.filter(pl.col("window_kind") == wk).sort("te")
        if not g.height:
            continue
        last = g.tail(1)
        u, rs, te = float(last["util_pct"][0]), last["rs"][0], last["te"][0]
        if rs is None or rs <= now or now - te > 2 * HOUR:
            continue
        if u >= 99.5:
            out = max(out, int(rs))
    return out


def gate_paths(base, grid, now, u0, tau, mode="shift"):
    """Hold each path at u0 until now+tau[i]; afterwards follow the base.

    shift: the base's rise trajectory starts at tau (delayed);
    cut:   only the base's increments after tau count."""
    P = np.asarray(base, dtype=np.float64)
    n, m = P.shape
    g = grid.astype(np.float64)
    out = np.empty_like(P)
    D = np.maximum(P - u0, 0.0)
    for i in range(n):
        ti = tau[i % len(tau)]
        if not np.isfinite(ti):
            out[i] = u0
            continue
        if ti <= 0:
            out[i] = P[i]
            continue
        if mode == "shift":
            # the rise from now (0 at now) replayed tau later
            gx = np.concatenate(([float(now)], g))
            dx = np.concatenate(([0.0], D[i]))
            vals = np.interp(g - ti, gx, dx, left=0.0)
        else:
            at = np.interp(now + ti, np.concatenate(([float(now)], g)), np.concatenate(([0.0], D[i])))
            vals = np.maximum(D[i] - at, 0.0)
        vals[g < now + ti] = 0.0
        out[i] = u0 + vals
    return np.clip(out, 0.0, 100.0)
