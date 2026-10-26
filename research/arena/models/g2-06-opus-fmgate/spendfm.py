"""spend.hourly / tokens.hourly: Timestral-28M with kit.fm.spend_model's
inputs (hourly series of the group, priced as of now, with calendar, meter,
session and prompt covariates), recalibrated on self-backtests.

All inputs are hourly arrays aligned to now, so one long array per series
serves every past cut: the context at a cut k hours before now is a slice.
Each cut's forecast is scored against the hours that followed it (known by
now) as randomised PITs per lead; per lead bucket the weighted PIT quantile
function (weights: age, and whether the series was active in the hour before
the cut, as now) remaps the live forecast's levels (shrunk toward identity
by n_eff / (n_eff + n0)). Paths: Gaussian copula with AR(1) correlation.
"""
from __future__ import annotations

import numpy as np

from arena.types import Target, TargetForecast
from kit.fm.backends import get_backend
from kit.fm.paths import extend_tails, fix_crossing, to_paths
from kit.fm.series import HOUR_MS, PriceCache, TurnFrame, calendar, meter_level_hourly, prompts_per_hour

import fmcal

def weekly_block(history, acct: str, now: int):
    """(block start, reset) when the account's 7-day meter reads at the limit
    now (a fresh reading), else None: the account cannot be used until then."""
    from kit import spend as kspend
    c = kspend.current_cycle(history, acct, "seven_day")
    if c is None:
        return None
    _, reset, rows = c
    if not rows.height or reset <= now:
        return None
    t = rows["t_event"].dt.epoch("ms").to_numpy()
    u = rows["util_pct"].to_numpy()
    if u[-1] < 99.5 or now - int(t[-1]) > 2 * HOUR_MS:
        return None
    below = np.flatnonzero(u < 99.5)
    start = int(t[below[-1] + 1]) if len(below) else int(t[0])
    return start, int(reset)


BUCKETS_H = np.array([1, 2, 3, 4, 6, 9, 12, 18, 24, 36, 48, 72, 120, 168])


class SpendFM:
    def __init__(self, cfg: dict, rng, log):
        self.cfg = cfg
        self.rng = rng
        self.log = log
        self._backend = None
        self._prices = PriceCache()
        self._recs: dict = {}

    @property
    def backend(self):
        if self._backend is None:
            self._backend = get_backend(self.cfg.get("backend", "timestral"), self.cfg["weights"],
                                        int(self.cfg.get("threads", 2)))
        return self._backend

    def forecast(self, history, now: int, trs) -> dict:
        T = int(self.cfg.get("context_hours", 336))
        span = int(self.cfg.get("cal_span_h", 24 * 14))
        every = int(self.cfg.get("cal_every_h", 3))
        accounts = sorted({a for tr in trs for a in tr.accounts})
        L = T + span
        tf = TurnFrame(history, L, accounts, self._prices)
        H_need = {tr.key: max(1, int(round((int(tr.grid[-1]) - now) / HOUR_MS))) for tr in trs}
        H = max(H_need.values())
        cov_names = list(self.cfg.get("covariates", ["calendar", "meter", "sessions", "prompts"]))
        ends = now + HOUR_MS * np.arange(-(L - 1), H + 1, dtype=np.int64)
        cal = calendar(ends, tf.tz_offset_min) if "calendar" in cov_names else None          # [4, L + H]
        past_by_group: dict = {}
        out = {}
        for tr in trs:
            what = "spend" if tr.target is Target.SPEND_HOURLY else "tokens"
            y = tf.hourly(tr.accounts, what, tr.family, L)                                    # [L]
            g = tuple(tr.accounts)
            if g not in past_by_group:
                rows = []
                if "meter" in cov_names:
                    for wk in ("five_hour", "seven_day"):
                        rows.append(meter_level_hourly(history, g, wk, now, L))
                if "sessions" in cov_names:
                    rows.append(tf.sessions_per_hour(g, L))
                if "prompts" in cov_names:
                    rows.append(prompts_per_hour(history, tf.session_set(g), now, L))
                past_by_group[g] = np.stack(rows) if rows else None
            past = past_by_group[g]
            blk = None
            if self.cfg.get("block", True):
                bl = [weekly_block(history, a, now) for a in tr.accounts]
                if bl and all(b is not None for b in bl):
                    blk = (max(b[0] for b in bl), min(b[1] for b in bl))
            out[tr.key] = self._one(tr, y, past, cal, T, L, H_need[tr.key], every, now, blk)
        return out

    def _inputs(self, y, past, cal, T, L, end_idx, H):
        """Context ending at array index end_idx (exclusive) and its covariates."""
        ctx = y[end_idx - T:end_idx]
        pc = past[:, end_idx - T:end_idx] if past is not None else None
        kc = cal[:, end_idx - T:end_idx + H] if cal is not None else None
        return ctx, pc, kc

    def _quant(self, ctxs, pcs, kcs, H):
        X = np.stack(ctxs)[:, None, :]
        P = np.stack(pcs) if pcs[0] is not None else None
        K = np.stack(kcs) if kcs[0] is not None else None
        out = []
        for b in range(0, len(ctxs), 32):
            lv, q = self.backend.quantiles(X[b:b + 32], H, None if P is None else P[b:b + 32],
                                           None if K is None else K[b:b + 32])
            out.append(q[:, 0])
        return lv, np.concatenate(out)                                                         # [B, H, Q]

    def _post(self, lv, q, ctx):
        """kit.fm.spend_model's quantile treatment, then anchors for PITs."""
        q = fix_crossing(np.maximum(q, 0.0))
        lv2, q = extend_tails(lv, q)
        q = np.maximum(q, 0.0)
        cap = float(self.cfg.get("cap_factor", 1.5))
        if cap > 0 and np.isfinite(ctx).any() and np.nanmax(ctx) > 0:
            q = np.minimum(q, cap * float(np.nanmax(ctx)))
        return _anchor(lv2, q)

    def _one(self, tr, y, past, cal, T, L, H, every, now, blk=None):
        ctx, pc, kc = self._inputs(y, past, cal, T, L, L, H)
        if blk is not None and self.cfg.get("block_mask", True):
            # the hours the account was held at its weekly limit say nothing
            # about how it is used: missing, not idle, to the forecaster
            ends = now - HOUR_MS * np.arange(T - 1, -1, -1, dtype=np.int64)
            ctx = np.where(ends > blk[0], np.nan, ctx)
        lv, q = self._quant([ctx], [pc], [kc], H)
        lva, qa = self._post(lv, q[0], np.nan_to_num(ctx))                                                   # [H, Q+2]
        steps = np.clip(np.round((np.asarray(tr.grid, dtype=np.int64) - now) / HOUR_MS).astype(int), 1, H)
        qg = qa[steps - 1]                                                                    # [G, Q+2]
        if self.cfg.get("calibrate", True):
            lev = self._levels(tr.key, now, y, past, cal, T, L, H, every, steps)
            vals = np.stack([np.interp(lev[j], lva, qg[j]) for j in range(len(steps))])      # [G, A]
            levels_out = fmcal.ALPHA
        else:
            vals, levels_out = qg, lva
        paths = to_paths(levels_out, vals, tr.n_paths, "ar1", rho=float(self.cfg.get("rho", 0.8)), rng=self.rng)
        if blk is not None:
            g = np.asarray(tr.grid, dtype=np.int64)
            open_frac = np.clip((g - blk[1]) / HOUR_MS, 0.0, 1.0)       # share of the hour after the reset
            paths = paths * open_frac[None, :]
        return TargetForecast(np.maximum(paths, 0.0))

    def _levels(self, key, now, y, past, cal, T, L, H, every, steps):
        """[G, A] forecaster levels to read, from PITs of past cuts (refreshed
        once per `cal_refresh_h`)."""
        refresh = float(self.cfg.get("cal_refresh_h", 24)) * HOUR_MS
        Hc = int(min(H, int(self.cfg.get("cal_max_lead_h", 168))))
        hit = self._recs.get(key)
        if hit is None or now - hit[0] >= refresh or hit[1] < Hc:
            hit = (now, Hc) + self._records(y, past, cal, T, L, Hc, every)
            self._recs[key] = hit
        t_ref, _, rb, rp, rk, rs = hit
        nb = len(BUCKETS_H)
        act_now = y[L - 1] > 0
        tau = float(self.cfg.get("cal_age_tau_h", 24 * 21))
        mismatch = float(self.cfg.get("cal_state_mismatch_w", 0.3))
        rw = np.exp(-(rk + (now - t_ref) / HOUR_MS) / tau) * np.where(rs == act_now, 1.0, mismatch)
        n0 = float(self.cfg.get("cal_n0", 30))
        maps = np.repeat(fmcal.ALPHA[None, :], nb, axis=0)
        last = None
        for b in range(nb):
            m = rb == b
            if m.sum() >= 5:
                w = rw[m]
                neff = w.sum() ** 2 / (w ** 2).sum()
                a = neff / (neff + n0)
                maps[b] = a * fmcal.wquantile(rp[m], w, fmcal.ALPHA) + (1 - a) * fmcal.ALPHA
                last = b
            elif last is not None:
                maps[b] = maps[last]
        if self.cfg.get("cal_lower_only", False):
            # correct only the mass at and near zero: below the median the
            # calibrated levels, above it the forecaster's own (joined at 0.5)
            lo = fmcal.ALPHA < 0.5
            m50 = maps[:, [int(np.searchsorted(fmcal.ALPHA, 0.5)) - 1]]
            maps = np.where(lo[None, :], np.minimum(maps, m50) * 0 + maps, fmcal.ALPHA[None, :])
            maps = np.maximum.accumulate(maps, axis=1)
        x = np.log(BUCKETS_H.astype(float))
        out = np.empty((len(steps), len(fmcal.ALPHA)))
        for a in range(len(fmcal.ALPHA)):
            out[:, a] = np.interp(np.log(steps.astype(float)), x, maps[:, a])
        return np.clip(out, 0.0, 1.0)

    def _records(self, y, past, cal, T, L, Hc, every):
        span = L - T
        ks = np.arange(every, span + 1, every)                       # cut k hours before now
        ctxs, pcs, kcs, meta = [], [], [], []
        for k in ks:
            e = L - int(k)
            if e - T < 0:
                continue
            c, p, kc = self._inputs(y, past, cal, T, L, e, Hc)
            ctxs.append(c)
            pcs.append(p)
            kcs.append(kc)
            meta.append((int(k), e))
        if not ctxs:
            z = np.zeros(0)
            return z.astype(int), z, z, z.astype(bool)
        lv, q = self._quant(ctxs, pcs, kcs, Hc)
        b_of = np.searchsorted(BUCKETS_H, np.arange(1, Hc + 1), side="left")   # lead h -> bucket
        rb, rp, rk, rs = [], [], [], []
        for i, (k, e) in enumerate(meta):
            lva, qa = self._post(lv, q[i], ctxs[i])
            st = bool(y[e - 1] > 0)
            for h in range(1, min(Hc, k) + 1):
                rb.append(b_of[h - 1])
                rp.append(fmcal.pit(lva, qa[h - 1], float(y[e + h - 1]), float(self.rng.random())))
                rk.append(k)
                rs.append(st)
        return np.asarray(rb, dtype=int), np.asarray(rp), np.asarray(rk, dtype=float), np.asarray(rs, dtype=bool)


def _anchor(lv, q):
    """Add level 0 (value 0) and level 1 (top continued) anchors."""
    top = q[..., -1] + (q[..., -1] - q[..., -2]) * 1.5 + 1e-9
    lv = np.concatenate(([0.0], lv, [1.0]))
    q = np.concatenate((np.zeros(q.shape[:-1] + (1,)), q, top[..., None]), axis=-1)
    return lv, q
