"""Zero-mass calibration layer for meter forecasts.

A meter that has not moved yet reads exactly its current value; polls arrive
every minute or so whether or not the user is working, so at short and medium
leads a large share of the truth points sit exactly at the current level
(0.14-0.8 at +30 min across months of the visible tier). A continuous
forecaster has no such mass, so its truth falls below the whole forecast.

`flat_share` estimates P(meter unchanged at lead L) from this meter's own
history: past reading times weighted by (a) how long since the meter last
rose, (b) how much it rose over the last hour, (c) optionally hour of day,
(d) recency. The child's paths are then remapped: levels below the flat share
read the current level, the rest read the child's quantile function over the
remaining probability.
"""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, Target, TargetForecast
from kit.fm.series import meter_series
from kit.ml.paths import sorted_samples

MIN_MS = 60_000
HOUR_MS = 3_600_000
WINDOW_FOR = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day", Target.METER_SCOPED: "weekly_scoped"}
LEADS_MIN = np.array([0.5, 1, 2, 3, 5, 10, 20, 30, 60, 120, 240, 480, 960, 1920, 3840, 7680, 10080], dtype=np.float64)


def flat_share(s, now: int, reset_at: int, cfg: dict) -> np.ndarray | None:
    """P(meter reading at lead L == reading now) for LEADS_MIN, nonincreasing."""
    t, u, rs, act = s.times, s.cycle_util, s.reset, s.active
    n = len(t)
    if n < 20 or reset_at is None:
        return None
    dur = s.duration
    # cycle id: new cycle when the active reset moves half a window
    idx_act = np.where(act, np.arange(n), -1)
    prev = np.concatenate(([-1], np.maximum.accumulate(idx_act)[:-1]))
    prev_r = np.where(prev >= 0, rs[np.maximum(prev, 0)], -1)
    newc = act & ((prev < 0) | (np.abs(rs - prev_r) >= dur / 2))
    cid = np.cumsum(newc)
    u_prev = np.where(prev >= 0, u[np.maximum(prev, 0)], 0.0)
    rise = act & ~newc & (u > u_prev + 1e-9)
    marker = np.where(newc | rise, t, -(10 ** 15)).astype(np.float64)
    last_rise = np.maximum.accumulate(marker)
    since = (t - last_rise) / MIN_MS                                  # minutes since last rise / cycle start
    # rise over the trailing hour within the cycle
    j60 = np.searchsorted(t, t - HOUR_MS, side="right") - 1
    j60 = np.maximum(j60, 0)
    same = cid[j60] == cid
    r60 = np.where(same, u - u[j60], u)                               # cycle's first hour counts from 0
    r60 = np.maximum(r60, 0.0)
    # state now
    cur = act & (np.abs(rs - reset_at) < dur / 2)
    if not cur.any():
        return None
    ic = int(np.flatnonzero(cur)[-1])
    s_now = (now - last_rise[ic]) / MIN_MS
    jn = max(int(np.searchsorted(t, now - HOUR_MS, side="right")) - 1, 0)
    r_now = max(u[ic] - (u[jn] if cid[jn] == cid[ic] else 0.0), 0.0)
    # candidate sample points: active readings, thinned
    cand = np.flatnonzero(act)
    cand = cand[t[cand] >= now - 120 * 86_400_000]
    mx = int(cfg.get("max_samples", 6000))
    if len(cand) > mx:
        cand = cand[np.linspace(0, len(cand) - 1, mx).round().astype(int)]
    stale = int(cfg.get("stale_min", 120)) * MIN_MS
    tau = float(cfg.get("tau_d", 14.0)) * 86_400_000
    w = np.exp(-(now - t[cand]) / tau)
    hs, hr = float(cfg.get("h_since", 0.8)), float(cfg.get("h_rate", 0.8))
    w = w * np.exp(-0.5 * ((np.log1p(since[cand]) - np.log1p(s_now)) / hs) ** 2) \
          * np.exp(-0.5 * ((np.log1p(r60[cand]) - np.log1p(r_now)) / hr) ** 2)
    tod = float(cfg.get("tod_h", 0.0))
    if tod > 0:
        dh = ((t[cand] - now) / HOUR_MS + 12.0) % 24.0 - 12.0
        w = w * np.exp(-0.5 * (dh / tod) ** 2)
    n0 = float(cfg.get("n0", 3.0))
    pooled_w = np.exp(-(now - t[cand]) / tau)
    out = np.full(len(LEADS_MIN), np.nan)
    flat_all = np.full(len(LEADS_MIN), np.nan)
    for k, L in enumerate(LEADS_MIN):
        te = t[cand] + int(L * MIN_MS)
        ok = (te <= now) & (te <= rs[cand])
        j = np.searchsorted(t, te, side="right") - 1
        j = np.maximum(j, 0)
        ok &= (j > cand) & (te - t[j] <= stale) & act[j] & (cid[j] == cid[cand])
        if ok.sum() < 5:
            continue
        flat = (u[j] <= u[cand] + 1e-9).astype(np.float64)
        pw = pooled_w[ok]
        flat_all[k] = (pw * flat[ok]).sum() / pw.sum()
        ww = w[ok]
        out[k] = ((ww * flat[ok]).sum() + n0 * flat_all[k]) / (ww.sum() + n0)
    good = np.isfinite(out)
    if good.sum() < 2:
        return None
    # extend to unsupported long leads with the last supported value, and enforce monotone
    xs = np.log(LEADS_MIN[good])
    res = np.interp(np.log(LEADS_MIN), xs, out[good])
    return np.minimum.accumulate(np.clip(res, 0.0, 1.0))


def remap(x: np.ndarray, b: float, pi: np.ndarray, pi_c: np.ndarray) -> np.ndarray:
    """x [m, G] sorted child samples; pi [G] target flat share; pi_c [G] the
    child's own mass at b. Quantile levels below pi read b; above, the child's
    quantile function over its non-flat mass."""
    m, G = x.shape
    lv = (np.arange(m) + 0.5) / m
    lv_src = np.concatenate(([0.0], lv, [1.0]))
    top = np.minimum(x[-1] + (x[-1] - x[-2]), 100.0)
    src = np.vstack([np.full((1, G), b), x, top[None, :]])
    out = np.empty_like(x)
    for j in range(G):
        q = np.clip((lv - pi[j]) / max(1.0 - pi[j], 1e-6), 0.0, 1.0)
        q = pi_c[j] + q * (1.0 - pi_c[j])
        out[:, j] = np.interp(q, lv_src, src[:, j])
    out[lv[:, None] <= pi[None, :]] = b
    return np.clip(out, b, 100.0)


class Model:
    def __init__(self, ctx):
        self.ctx = ctx
        self.cfg = dict(ctx.config)
        self.history = None
        self.kids = dict(self.cfg.get("child", {}))

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    def forecast(self, request):
        now = int(request.now)
        out = {}
        by_child: dict[str, list] = {}
        for tr in request.targets:
            wk = WINDOW_FOR.get(tr.target)
            if wk is None:
                continue
            by_child.setdefault(str(self.kids.get(wk)), []).append(tr)
        for child, trs in by_child.items():
            sub = type(request)(request.now, request.scope, tuple(trs))
            try:
                fc = self.ctx.model(child).forecast(sub)
            except Exception as e:  # noqa: BLE001
                self.ctx.log(f"child {child} failed: {type(e).__name__}: {str(e)[:200]}")
                continue
            for tr in trs:
                tf = fc.by_key.get(tr.key)
                if tf is None:
                    continue
                out[tr.key] = self._layer(tr, tf, now)
        return Forecast(out)

    def _layer(self, tr, tf, now):
        P = np.asarray(tf.paths, dtype=np.float64)
        wk = WINDOW_FOR[tr.target]
        s = meter_series(self.history.table("meter_readings"), tr.accounts[0], wk,
                         tr.cap if tr.target is Target.METER_SCOPED else None, now)
        if tr.reset_at is None or wk in set(self.cfg.get("passthrough", [])):
            return tf
        b = s.used_now(tr.reset_at)
        pi_L = flat_share(s, now, int(tr.reset_at), self.cfg)
        if b is None or pi_L is None:
            return tf
        grid = np.asarray(tr.grid, dtype=np.float64)
        lead_min = np.maximum((grid - now) / MIN_MS, 0.5)
        pi = np.interp(np.log(lead_min), np.log(LEADS_MIN), pi_L)
        m = max(P.shape[0], 100)
        X = sorted_samples(P, m)
        pi_c = (X <= b + float(self.cfg.get("delta", 0.5))).mean(axis=0)
        pi = np.maximum(pi, pi_c)               # never less mass at b than the child already has
        pi = np.clip(pi * float(self.cfg.get("pi_scale", 1.0)), pi_c, 0.98)
        Q = remap(X, float(b), pi, pi_c)
        if Q.shape[0] != P.shape[0]:
            Q = sorted_samples(Q, P.shape[0])
        return TargetForecast(Q)
