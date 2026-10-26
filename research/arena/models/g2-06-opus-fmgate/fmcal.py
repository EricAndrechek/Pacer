"""Recalibrated pretrained meter forecasts: the forecaster's quantiles of the
meter's cumulative burn, remapped by what the same forecaster got wrong on
this user's own past, in meter space.

**Self-backtest.** The cumulative burn series (`kit.fm.series.meter_series`:
burn summed across cycles, never reset) is the same object at every moment of
the history, so the forecaster is run at past cut points `c` exactly as it
runs now (`SelfBacktest`: one batched call per refresh for the cuts not yet
forecast; earlier cuts are kept). At each cut the meter read `used_c` in a
cycle resetting at `reset_c`; the forecast meter at lead L is
`clip(used_c + burn_q(L), used_c, 100)`, the same transformation the live
forecast uses. Every lead that ended before now and inside that cycle gives
the PIT of the meter as then read (randomised over ties: an idle stretch reads
exactly `used_c`, a capped one exactly 100).

**Quantile recalibration** (Kuleshov et al. 2018), conditional. The PITs are
weighted by how alike their cut is to now: the meter level (a user near the
limit rations; one with room to spare does not), the phase of the cycle and
age. Per lead, the weighted empirical quantile function of the PITs, `Q_L`,
shrunk toward the identity by the effective number of PITs (`n / (n + n0)`),
maps a nominal level `a` to the forecaster's level `Q_L(a)`: the calibrated
quantile is `F^-1(Q_L(a))`. Leads in between the backtest leads interpolate the
maps in log-lead; past the longest lead with PITs, the longest one's map.
"""
from __future__ import annotations

import math

import numpy as np

from kit.fm.paths import burn_quantiles, extend_tails, fix_crossing
from kit.fm.series import MIN_MS, regular_grid, resample_last

LEADS_MIN = {
    "five_hour": (0.5, 1, 2, 3, 5, 10, 20, 30, 60, 90, 120, 180, 240, 300),
    "seven_day": (1, 5, 15, 30, 60, 120, 240, 480, 720, 1440, 2160, 2880, 4320, 5760, 7200, 10080),
    "weekly_scoped": (1, 5, 15, 30, 60, 120, 240, 480, 720, 1440, 2160, 2880, 4320, 5760, 7200, 10080),
}
ALPHA = (np.arange(200) + 0.5) / 200          # output levels, one per stratified path


def ext_levels(levels, q):
    """Burn quantiles [..., Q] at `levels` -> with anchors at level 0 (burn 0)
    and level 1 (the top tail continued), so every PIT lands inside."""
    lv, q = extend_tails(levels, q)
    q = np.maximum(fix_crossing(q), 0.0)
    top = q[..., -1] + (q[..., -1] - q[..., -2]) * 1.5 + 1e-6
    lv = np.concatenate(([0.0], lv, [1.0]))
    q = np.concatenate((np.zeros(q.shape[:-1] + (1,)), q, top[..., None]), axis=-1)
    return lv, q


def pit(lv: np.ndarray, qrow: np.ndarray, r: float, u01: float) -> float:
    """Randomised PIT of r against one non-decreasing quantile row."""
    if r < qrow[0]:
        return 0.0
    if r > qrow[-1]:
        return 1.0
    lo_i = int(np.searchsorted(qrow, r, side="left"))     # first index with q >= r
    hi_i = int(np.searchsorted(qrow, r, side="right"))    # first index with q > r
    if hi_i > lo_i:                                       # r sits on tied levels
        a = lv[lo_i - 1] if lo_i > 0 else 0.0
        b = lv[hi_i] if hi_i < len(lv) else 1.0
        # the mass of the tie spans the levels up to the neighbours' midpoints
        a = 0.5 * (a + lv[lo_i]) if lo_i > 0 else 0.0
        b = 0.5 * (b + lv[hi_i - 1]) if hi_i < len(lv) else 1.0
        return float(a + u01 * (b - a))
    j = lo_i
    x0, x1 = qrow[j - 1], qrow[j]
    return float(lv[j - 1] + (lv[j] - lv[j - 1]) * (r - x0) / max(x1 - x0, 1e-12))


def wquantile(x: np.ndarray, w: np.ndarray, q: np.ndarray) -> np.ndarray:
    o = np.argsort(x)
    x, w = x[o], w[o]
    c = np.cumsum(w)
    c = (c - 0.5 * w) / c[-1]
    return np.interp(q, c, x)


class SelfBacktest:
    """The forecaster's quantiles at past cuts of one meter's series."""

    def __init__(self, wk: str, step: int, ctx_n: int, stale: int, every_ms: int, max_cuts: int,
                 duration: int):
        self.wk, self.step, self.ctx_n, self.stale = wk, step, ctx_n, stale
        self.every, self.max_cuts, self.duration = every_ms, max_cuts, duration
        self.leads = np.asarray(LEADS_MIN[wk], dtype=np.float64)
        self.H = int(math.ceil(self.leads.max() * MIN_MS / step))
        self.cuts: dict[int, tuple] = {}        # c -> (c_last, used_c, reset_c, phase, lv, bq [H+1, Q+2] float32)

    def refresh(self, backend, series, now: int):
        t0 = int(series.times[0]) if len(series) else now
        last = now - int(self.leads[0] * MIN_MS)
        # cut times on a fixed lattice (multiples of `every`), so refreshes reuse them
        hi = (last // self.every) * self.every
        cand = np.arange(hi, t0 + self.step * 12, -self.every, dtype=np.int64)[:self.max_cuts]
        new_c, ctxs, meta = [], [], []
        for c in cand:
            c = int(c)
            if c in self.cuts:
                continue
            j = int(np.searchsorted(series.times, c, side="right")) - 1
            if j < 0 or c - series.times[j] > self.stale or not series.active[j] or series.reset[j] <= c:
                self.cuts[c] = None
                continue
            v = resample_last(series.times, series.cum, regular_grid(c, self.step, self.ctx_n), self.stale)
            if not np.isfinite(v[-1]):
                self.cuts[c] = None
                continue
            new_c.append(c)
            ctxs.append(v)
            reset_c = int(series.reset[j])
            phase = 1.0 - (reset_c - c) / self.duration
            k30 = max(1, int(round(30 * MIN_MS / self.step)))
            act = float(v[-1] - v[-1 - k30]) if np.isfinite(v[-1 - k30]) else 0.0
            meta.append((float(v[-1]), float(series.cycle_util[j]), reset_c, phase, act))
        if new_c:
            X = np.stack(ctxs)[:, None, :]
            for b in range(0, len(new_c), 32):
                lvq, q = backend.quantiles(X[b:b + 32], self.H)
                for k in range(q.shape[0]):
                    i = b + k
                    burn = burn_quantiles(q[k, 0], meta[i][0])
                    burn = np.vstack([np.zeros((1, burn.shape[1])), burn])
                    lv, bq = ext_levels(lvq, burn)
                    self.cuts[new_c[i]] = (*meta[i], lv, bq.astype(np.float32))
        # forget cuts beyond the window kept
        keep = set(int(c) for c in cand)
        for c in list(self.cuts):
            if c not in keep:
                del self.cuts[c]

    def records(self, series, now: int, rng):
        """PIT records: arrays (lead index, pit, level, phase, age_ms)."""
        li, pits, lev, ph, age, acts = [], [], [], [], [], []
        for c, v in self.cuts.items():
            if v is None:
                continue
            c_last, used_c, reset_c, phase, act, lv, bq = v
            for i, L in enumerate(self.leads):
                te = c + int(L * MIN_MS)
                if te > now or te > reset_c:
                    break
                j = int(np.searchsorted(series.times, te, side="right")) - 1
                if j < 0 or te - series.times[j] > self.stale or not series.active[j]:
                    continue
                if abs(int(series.reset[j]) - reset_c) >= self.duration / 2:
                    continue
                realised = float(series.cycle_util[j])
                pos = L * MIN_MS / self.step
                j0 = min(int(math.floor(pos)), self.H)
                j1 = min(j0 + 1, self.H)
                f = pos - j0
                row = np.clip(used_c + (1 - f) * bq[j0].astype(np.float64) + f * bq[j1].astype(np.float64),
                              used_c, 100.0)
                li.append(i)
                pits.append(pit(lv, row, realised, float(rng.random())))
                lev.append(used_c)
                ph.append(phase)
                age.append(now - c)
                acts.append(act)
        return (np.asarray(li, dtype=np.int64), np.asarray(pits), np.asarray(lev), np.asarray(ph),
                np.asarray(age, dtype=np.float64), np.asarray(acts))


class Calibration:
    """Per-lead PIT quantile maps for one forecast (weighted toward cuts like now)."""

    def __init__(self, leads, recs, level_now: float, phase_now: float, cfg: dict, prior_rows=None,
                 prior_levels=None, act_now: float = 0.0):
        self.leads = np.asarray(leads, dtype=np.float64)
        li, p, lev, ph, age, acts = recs
        n0 = float(cfg.get("cal_n0", 30))
        sl = float(cfg.get("cal_sigma_level", 15.0))
        sp = float(cfg.get("cal_sigma_phase", 0.2))
        ta = float(cfg.get("cal_age_tau_d", 30.0)) * 86_400_000
        w_all = np.ones(len(p))
        if len(p):
            if sl > 0:
                w_all *= np.exp(-0.5 * ((lev - level_now) / sl) ** 2)
            if sp > 0:
                w_all *= np.exp(-0.5 * ((ph - phase_now) / sp) ** 2)
            if ta > 0:
                w_all *= np.exp(-age / ta)
            mm = float(cfg.get("cal_act_mismatch_w", 0.25))
            w_all *= np.where((acts > 0) == (act_now > 0), 1.0, mm)
        self.maps = np.repeat(ALPHA[None, :], len(self.leads), axis=0)
        self.n = np.zeros(len(self.leads))
        prior = ALPHA.copy()
        priors = None
        if prior_rows is not None and cfg.get("cal_prior", "offline") == "offline":
            pl_ = np.asarray(prior_levels, dtype=np.float64)
            k = float(cfg.get("prior_strength", 1.0))
            priors = [k * np.interp(ALPHA, pl_, np.asarray(r, dtype=np.float64)) + (1 - k) * ALPHA for r in prior_rows]
        if cfg.get("cal_prior", "offline") == "pooled" and len(p) >= 10 and w_all.sum() > 0:
            # one map over every lead (the forecaster's typical miscalibration),
            # itself shrunk toward the identity
            neff = w_all.sum() ** 2 / (w_all ** 2).sum()
            a = neff / (neff + n0)
            prior = a * wquantile(p, w_all, ALPHA) + (1 - a) * ALPHA
        last_ok = None
        for i in range(len(self.leads)):
            if priors is not None:
                pmin = float(cfg.get("prior_min_lead", 60))
                prior = priors[min(i, len(priors) - 1)] if self.leads[i] >= pmin else ALPHA
            m = li == i
            w = w_all[m]
            if m.sum() >= 3 and w.sum() > 0:
                neff = w.sum() ** 2 / (w ** 2).sum()
                emp = wquantile(p[m], w, ALPHA)
                a = neff / (neff + n0)
                self.maps[i] = a * emp + (1 - a) * prior
                self.n[i] = neff
                last_ok = i
            elif last_ok is not None and priors is None:
                self.maps[i] = self.maps[last_ok]
                self.n[i] = -self.n[last_ok]
            else:
                self.maps[i] = prior

    def levels(self, lead_min: np.ndarray) -> np.ndarray:
        """[len(lead_min), A]."""
        x = np.log(np.maximum(np.asarray(lead_min, dtype=np.float64), 1e-3))
        xs = np.log(self.leads)
        out = np.empty((len(x), len(ALPHA)))
        for a in range(len(ALPHA)):
            out[:, a] = np.interp(x, xs, self.maps[:, a])
        return np.clip(out, 0.0, 1.0)


COMMON_LEVELS = np.array([0.01, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5,
                          0.55, 0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95, 0.99])


class EnsembleBackend:
    """Several backends as one: each member's quantiles (tails extended to
    1 %/99 %) read at common levels and averaged level by level
    (Vincentization), with weights."""

    def __init__(self, members, weights=None):
        self.members = list(members)
        self.weights = np.asarray(weights if weights is not None else [1.0] * len(self.members), dtype=np.float64)
        self.weights = self.weights / self.weights.sum()

    def quantiles(self, context, horizon, past_cov=None, known_cov=None):
        acc = None
        for be, w in zip(self.members, self.weights):
            lv, q = be.quantiles(context, horizon, past_cov, known_cov)
            lv, q = extend_tails(lv, q)
            q = fix_crossing(q)
            flat = q.reshape(-1, q.shape[-1])
            on = np.stack([np.interp(COMMON_LEVELS, lv, row) for row in flat]).reshape(q.shape[:-1] + (len(COMMON_LEVELS),))
            acc = w * on if acc is None else acc + w * on
        return COMMON_LEVELS.copy(), acc
