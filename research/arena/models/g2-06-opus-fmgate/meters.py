"""Meter targets: a pretrained forecaster on the cumulative burn, recalibrated
on the user's own past (`fmcal`), read at the request's grid as meter paths.
"""
from __future__ import annotations

import math

import numpy as np

from arena.types import Target, TargetForecast
from kit.fm.backends import get_backend
from kit.fm.paths import burn_quantiles, monotone_meter
from kit.fm.series import DAY_MS, MIN_MS, meter_series, regular_grid, resample_last

import fmcal

WINDOW_FOR = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day", Target.METER_SCOPED: "weekly_scoped"}


class MeterFM:
    def __init__(self, cfg: dict, rng, log):
        self.cfg = cfg
        self.rng = rng
        self.log = log
        self._backend = None
        self._cal: dict = {}

    @property
    def backend(self):
        if self._backend is None:
            th = int(self.cfg.get("threads", 2))
            main = get_backend(self.cfg.get("backend", "timestral"), self.cfg["weights"], th)
            extra = list(self.cfg.get("ensemble", []))          # [[backend, weights spec, weight], ...]
            if extra:
                members = [main] + [get_backend(b, wt, th) for b, wt, _ in extra]
                ws = [float(self.cfg.get("main_weight", 1.0))] + [float(x) for _, _, x in extra]
                self._backend = fmcal.EnsembleBackend(members, ws)
            else:
                self._backend = main
        return self._backend

    def _short_backend(self, sb):
        if getattr(self, "_sbe", None) is None:
            self._sbe = get_backend(sb["backend"], sb["weights"], int(self.cfg.get("threads", 2)))
        return self._sbe

    def _c(self, name, wk, default):
        v = self.cfg.get(name, {})
        return v.get(wk, default) if isinstance(v, dict) else v

    def forecast(self, history, now: int, tr) -> TargetForecast:
        wk = WINDOW_FOR[tr.target]
        cap = tr.cap if tr.target is Target.METER_SCOPED else None
        acct = tr.accounts[0]
        s = meter_series(history.table("meter_readings"), acct, wk, cap, now)
        used = s.used_now(tr.reset_at) if tr.reset_at is not None else None
        if used is None:
            used = float(s.cycle_util[s.active][-1]) if s.active.any() else 0.0
        grid = np.asarray(tr.grid, dtype=np.int64)
        step = int(self._c("step_min", wk, 5 if wk == "five_hour" else 15)) * MIN_MS
        ctx_n = int(self._c("context_steps", wk, 144 if wk == "five_hour" else 288))
        stale = int(self.cfg.get("stale_min", 120)) * MIN_MS
        ctx_v = resample_last(s.times, s.cum, regular_grid(now, step, ctx_n), stale)
        c_last = ctx_v[-1]
        if not np.isfinite(c_last) or used >= 100.0:
            return TargetForecast.point(np.full(len(grid), min(used, 100.0)), tr.n_paths)
        H = max(1, int(math.ceil((int(grid[-1]) - now) / step)))
        lvq, q = self.backend.quantiles(ctx_v[None, None, :], H)
        burn = burn_quantiles(q[0, 0], c_last)
        burn = np.vstack([np.zeros((1, burn.shape[1])), burn])           # [H+1, Q] at t_rel
        lv, bq = fmcal.ext_levels(lvq, burn)
        t_rel = step * np.arange(0, H + 1, dtype=np.float64)
        g_rel = (grid - now).astype(np.float64)
        # forecaster quantiles at each grid time
        bq_g = np.stack([np.interp(g_rel, t_rel, bq[:, k]) for k in range(bq.shape[1])], axis=1)  # [G, Q+2]
        mq = np.clip(used + bq_g, used, 100.0)                              # meter quantiles at lv
        if self.cfg.get("calibrate", True):
            dur = s.duration
            phase = 1.0 - (int(tr.reset_at) - now) / dur if tr.reset_at is not None else 0.5
            cal = self._calibration(history, s, now, wk, acct, cap, step, ctx_n, stale, used, phase)
            lev = cal.levels(np.maximum(g_rel / MIN_MS, 0.5))                  # [G, A]
        else:
            lev = np.repeat(fmcal.ALPHA[None, :], len(grid), axis=0)
        out = np.empty((len(grid), len(fmcal.ALPHA)))
        for j in range(len(grid)):
            out[j] = np.interp(lev[j], lv, mq[j])
        out = np.sort(out, axis=1)
        k = float(self._c("spread_k", wk, 1.0))
        if k != 1.0:
            # widen around the median (out of sample the calibrated tails stay thin)
            med = out[:, out.shape[1] // 2][:, None]
            out = np.clip(med + k * (out - med), used, 100.0)
        sb = self.cfg.get("short", {}).get(wk) if isinstance(self.cfg.get("short"), dict) else None
        if sb:
            # the first minutes from a forecaster that tracks the current burn more closely
            near = g_rel <= float(sb.get("max_lead_min", 5)) * MIN_MS
            if near.any():
                be = self._short_backend(sb)
                Hs = max(1, int(math.ceil(g_rel[near].max() / step)))
                lv2, q2 = be.quantiles(ctx_v[None, None, :], Hs)
                b2 = burn_quantiles(q2[0, 0], c_last)
                b2 = np.vstack([np.zeros((1, b2.shape[1])), b2])
                lv2, b2 = fmcal.ext_levels(lv2, b2)
                t2 = step * np.arange(0, Hs + 1, dtype=np.float64)
                for j in np.flatnonzero(near):
                    row = np.array([np.interp(g_rel[j], t2, b2[:, kk]) for kk in range(b2.shape[1])])
                    out[j] = np.clip(used + np.interp(fmcal.ALPHA, lv2, row), used, 100.0)
        out = np.maximum.accumulate(out, axis=0)                            # [G, A], monotone in t and level
        n = tr.n_paths
        idx = np.linspace(0, len(fmcal.ALPHA) - 1, n).round().astype(int)
        paths = out[:, idx].T                                      # [n, G]
        paths = paths[self.rng.permutation(n)]
        paths = monotone_meter(paths, used)
        if self.cfg.get("ration", True) and used < 99.5:
            paths = self._ration(paths, s, tr.reset_at, used)
        return TargetForecast(paths)

    def _ration(self, paths, s, reset_at, used):
        """A user near the limit often stops short of it. Of the past cycles
        (of this meter) that came within `ration_band` points of 100, the
        share that stopped short (Beta prior) is the chance a path that
        reaches the limit is held instead at a level those cycles stopped at."""
        band = float(self.cfg.get("ration_band", 5.0))
        maxes = []
        if len(s):
            m = s.active & (np.abs(s.reset - int(reset_at or 0)) >= s.duration / 2)
            if m.any():
                r = s.reset[m]
                u = s.cycle_util[m]
                # group by cycle: resets within half a window are one cycle
                order = np.argsort(r, kind="stable")
                r, u = r[order], u[order]
                brk = np.flatnonzero(np.diff(r) >= s.duration / 2) + 1
                for seg in np.split(np.arange(len(r)), brk):
                    maxes.append(float(u[seg].max()))
        maxes = np.asarray(maxes)
        near = maxes[maxes >= 100.0 - band]
        short = near[near < 100.0]
        a0, b0 = float(self.cfg.get("ration_prior_short", 1.0)), float(self.cfg.get("ration_prior_hit", 2.0))
        rho = (len(short) + a0) / (len(near) + a0 + b0)
        hit = (paths >= 99.5).any(axis=1)
        if not hit.any() or rho <= 0:
            return paths
        pool = short if len(short) else np.array([98.0, 99.0])
        held = hit & (self.rng.random(len(paths)) < rho)
        if held.any():
            lvl = np.maximum(self.rng.choice(pool, size=int(held.sum())), used)
            paths[held] = np.minimum(paths[held], lvl[:, None])
        return paths

    def _calibration(self, history, s, now, wk, acct, cap, step, ctx_n, stale, used, phase):
        refresh = int(self.cfg.get("cal_refresh_h", 24)) * 3_600_000
        key = (acct, wk, cap)
        bt, t_ref, recs = self._cal.get(key, (None, None, None))
        if bt is None:
            every = int(self._c("cal_every_min", wk, 60 if wk == "five_hour" else 240)) * MIN_MS
            bt = fmcal.SelfBacktest(wk, step, ctx_n, stale, every, int(self._c("cal_cuts", wk, 240)), s.duration)
        if t_ref is None or now - t_ref >= refresh:
            bt.refresh(self.backend, s, now)
            recs = bt.records(s, now, self.rng)
            t_ref = now
            self._cal[key] = (bt, t_ref, recs)
        pr = self.cfg.get("prior", {})
        k30 = max(1, int(round(30 * MIN_MS / step)))
        v = resample_last(s.times, s.cum, regular_grid(now, step, k30 + 1), stale)
        act = float(v[-1] - v[0]) if np.isfinite(v).all() else 0.0
        return fmcal.Calibration(bt.leads, recs, used, phase, self.cfg, pr.get(wk), pr.get("levels"), act)
