"""A generative simulator for a per-model weekly cap (the Fable cap),
mixed in one process with a recent-burn decay ensemble.

The scoped meter only moves when the capped family is used, and that use is
extremely bursty: in the visible tier account A1 has Fable turns in only ~290
distinct hours over three months, with gaps of up to twenty days. So the
honest forecast of "how far will this cap climb before it resets" is mostly a
question about *whether the user touches that model again at all*, and the
answer has a large point mass at "no".

Three ideas, none of which the earlier leaders use:

1. **Circular block bootstrap of the capped family's own spend series.**
   Instead of extrapolating the meter (a handful of past cycles to learn
   from), resample the account's history of capped-family dollars at
   five-minute resolution. For each path, pick an anchor time in the past and
   replay what actually happened from that anchor onward over the time left
   in the cycle. Anchors are kernel-weighted by local hour of day, weekday vs
   weekend, recency, and — most importantly — *how busy the account was just
   before the anchor* compared with how busy it is right now. That carries
   the burst structure, the diurnal shape, the weekly shape and the point
   mass at zero for free, and it needs only the usage series, so it works for
   any cap on any account. When the time left is longer than the usable
   history, the series is replayed circularly over a whole number of days, so
   the hour-of-day phase still lines up.

2. **Integer readings with an unknown carry.** The server reports whole
   points: truth is an integer. A continuous forecast therefore pays CRPS for
   spread it should not have. Every path here is
   `floor(reading + carry + converted future spend)` with a carry drawn
   inside the bracket the readings and the spend since them imply
   (`kit.spend`'s `LiveMeter.carry` logic, but sampled over the bracket
   instead of fixed at one position). With no future spend every path is
   exactly the last reading, which is what usually happens.

3. **The conversion as a random variable.** Points per dollar is estimated
   three ways (this cycle so far, a recency-weighted ratio over recent
   reading intervals, the app's own daily NNLS fit), blended by how much
   evidence each has, and drawn per path from a lognormal around the blend.
   Conversion error is a real and separate source of spread, and it scales
   with the size of the predicted rise rather than being added to it.

Fallback: with too little capped-family history to bootstrap, the centre is
the recency-decayed burn faded over the time left and the spread a lognormal
on it (the shape the earlier decay models use).
"""
from __future__ import annotations

import numpy as np
import polars as pl

from arena.snapshot.cycles import window_ms
from arena.types import Forecast, Target, TargetForecast
from kit import baselines as B
from kit import spend

MIN_MS = 60_000
HOUR_MS = 3_600_000
DAY_MS = 24 * HOUR_MS
WEEK_MS = 7 * DAY_MS
FAMILIES = list(spend.FAMILIES)


def _cap_family(scope_model):
    """Which family's spend moves this meter (None: every family)."""
    if not scope_model:
        return None
    s = str(scope_model).strip().lower()
    for f in FAMILIES[:-1]:
        if f in s:
            return f
    return None


class Model:
    def __init__(self, ctx):
        c = ctx.config
        self.rng = ctx.rng
        self.log = ctx.log
        self.bin_ms = int(c.get("bin_min", 5)) * MIN_MS
        self.hist_days = float(c.get("hist_days", 75))
        self.bw_hour = float(c.get("bw_hour", 2.5))
        self.bw_hour_per_day = float(c.get("bw_hour_per_day", 3.0))
        self.weekend_mismatch = float(c.get("weekend_mismatch", 0.6))
        self.recency_days = float(c.get("recency_days", 45))
        self.state_wins_h = tuple(float(x) for x in c.get("state_wins_h", (1.5, 24.0)))
        self.bw_state = float(c.get("bw_state", 0.9))
        self.bw_gap = float(c.get("bw_gap", 1.0))
        self.p_flat = float(c.get("p_flat", 0.0))
        self.damp = float(c.get("damp", 0.0))
        self.p_decay = float(c.get("p_decay", 0.0))
        self.other_account = float(c.get("other_account", 0.25))
        self.sigma_scale = float(c.get("sigma_scale", 0.30))
        self.sigma_k = float(c.get("sigma_k", 0.22))
        self.k_prior_rise = float(c.get("k_prior_rise", 15.0))
        self.carry_jitter = bool(c.get("carry_jitter", True))
        self.discretize = bool(c.get("discretize", True))
        self.min_anchors = int(c.get("min_anchors", 24))
        self.fallback_tau_h = float(c.get("fallback_tau_h", 16.0))
        self.fallback_sigma = float(c.get("fallback_sigma", 0.7))
        self.history = None
        self._cache = {}
        self._sercache = {}

    def fit(self, history):
        self.history = history
        self._cache = {}

    def update(self, events):
        self.history = self.history.extend(events)
        self._cache = {}

    def forecast(self, request):
        out = {}
        for tr in request.targets:
            if tr.target in B.WINDOW_OF:
                try:
                    out[tr.key] = self._meter(tr)
                except Exception as e:                      # noqa: BLE001
                    self.log(f"{tr.key}: {type(e).__name__}: {e}")
                    m = B.meter_now(self.history, tr)
                    out[tr.key] = TargetForecast.point(np.full(len(tr.grid), m.latest), tr.n_paths)
        return Forecast(out)

    # ------------------------------------------------------------------
    def _meter(self, tr):
        h = self.history
        acct = tr.accounts[0]
        m = B.meter_now(h, tr)
        fam = _cap_family(m.scope_model)
        n, npaths = len(tr.grid), tr.n_paths
        now = h.now
        lead = (tr.grid.astype(np.float64) - now)
        reset = m.reset

        k_hat, k_evidence = self._conversion(acct, m, fam)
        # dollars of counted spend since the latest reading
        since = self._spent(acct, m.latest_t, now, fam)

        # future converted rise, in points, per path  [npaths, n]
        rise, ok = self._rise(acct, fam, now, lead, reset, npaths, k_hat)
        if not ok:
            rise = self._fallback_rise(acct, fam, m, now, lead, npaths, k_hat)
        elif self.p_decay > 0:
            # A share of the paths comes from the other family of answer: the
            # recent burn faded over the time left, the shape the decay
            # models on the gen-1 board use. Two differently-built ensembles
            # mixed in one process score like a pool of two models without
            # the cost (and the scorer's timeout) of a second child.
            dec = self._fallback_rise(acct, fam, m, now, lead, npaths, k_hat)
            take = self.rng.random(npaths) < self.p_decay
            rise = np.where(take[:, None], dec, rise)

        # conversion uncertainty: multiplicative, on everything converted
        sk = self.sigma_k / np.sqrt(max(k_evidence, 1.0) / self.k_prior_rise + 1.0)
        kf = np.exp(self.rng.normal(0.0, min(sk, 1.2), size=npaths) - 0.5 * min(sk, 1.2) ** 2)
        added = kf[:, None] * (rise + k_hat * since)
        if self.p_flat > 0:
            # a share of paths says "this cap is done for the week": pure
            # persistence, the mixture component the bootstrap cannot express
            # when every comparable moment in the past was followed by use
            added = np.where(self.rng.random(npaths)[:, None] < self.p_flat, 0.0, added)

        base = float(m.latest)
        if self.damp > 0:
            # Users slow down (or are blocked) as the cap fills, so let the
            # converted rise bend toward an asymptote instead of blowing
            # past 100: f(x) = c(1 − e^(−x/c)), c = damp × the room left.
            # f'(0) = 1, so small rises are untouched; a path only reaches
            # 100 when its raw rise is well over the room left.
            c = max(100.0 - base, 1e-6) * self.damp
            added = c * (1.0 - np.exp(-added / c))
        if self.discretize and abs(base - round(base)) < 1e-9 and base < 100.0:
            lo, hi = self._carry_bracket(acct, m, fam, k_hat)
            carry = lo + self.rng.random(npaths) * max(hi - lo, 0.0) if self.carry_jitter else \
                np.full(npaths, 0.5 * (lo + hi))
            paths = np.floor(round(base) + carry[:, None] + added)
        else:
            paths = base + added
        paths = np.clip(paths, base, 100.0)
        paths = np.maximum.accumulate(paths, axis=1)      # non-decreasing in time

        tf = TargetForecast(paths)
        grid = tr.grid.astype(np.float64)
        before = grid <= (reset if reset is not None else grid[-1])
        reached = paths >= 99.5
        tf.extras["p_hit_limit"] = float(np.mean(reached[:, before].any(axis=1))) if before.any() else 0.0
        first = np.where(reached.any(axis=1), reached.argmax(axis=1), -1)
        ttl = np.where(first >= 0, grid[np.maximum(first, 0)], np.nan)
        tf.extras["time_to_limit"] = ttl
        return tf

    # ------------------------------------------------------------------
    # conversion: points per dollar of the counted family
    # ------------------------------------------------------------------
    def _conversion(self, acct, m, fam):
        """(points per dollar, evidence in points of rise behind it)."""
        h = self.history
        cands = []                                    # (k, weight_in_points)

        # (a) this cycle so far: total rise over the spend that produced it
        if len(m.util) >= 2:
            u = m.util
            # ignore a mid-cycle re-base (the meter falls): take the rise over
            # the last non-falling stretch
            drop = np.flatnonzero(np.diff(u) < -0.5)
            i0 = int(drop[-1] + 1) if len(drop) else 0
            rise = float(u[-1] - u[i0])
            t0 = int(m.t[i0]) if i0 > 0 else int(m.start)
            sp = self._spent(acct, t0, int(m.t[-1]), fam)
            if rise > 1.0 and sp > 0:
                cands.append((rise / sp, rise))

        # (b) recency-weighted ratio over this meter's recent reading intervals
        iv = spend.intervals(h, acct, m.window_kind, m.scope_model)
        if len(iv):
            w = np.exp(-(h.now - iv.t1) / (self.recency_days * DAY_MS))
            sp = iv.spend[:, FAMILIES.index(fam)] if fam else iv.spend.sum(axis=1)
            num, den = float(w @ iv.rise), float(w @ sp)
            if den > 0 and num > 0:
                cands.append((num / den, min(float(w @ iv.rise), 60.0)))

        # (c) the app's own daily fit
        d = spend.fit_details(h, acct, m.window_kind, m.scope_model)
        if d is not None:
            r = float(d.rates[FAMILIES.index(fam)]) if fam else float(np.mean(d.rates))
            if not np.isfinite(r) or r <= 0:
                r = float(d.pooled)
            if r > 0:
                cands.append((r, min(float(d.rise), 60.0)))

        if not cands:
            return 0.0, 0.0
        ks = np.array([c[0] for c in cands])
        ws = np.array([max(c[1], 0.5) for c in cands])
        return float(np.exp((ws @ np.log(ks)) / ws.sum())), float(ws.max())

    def _carry_bracket(self, acct, m, fam, k):
        """[lo, hi) within the latest whole point, from the readings of this
        cycle and the spend between them (`kit.spend`'s LiveMeter.carry)."""
        if len(m.util) == 0 or k <= 0:
            return 0.0, 1.0
        t, u = m.t, m.util
        keep = t >= t[-1] - 6 * HOUR_MS
        t, u = t[keep], u[keep]
        # one vectorized range-sum for every consecutive pair, not one call
        # per reading: a six-hour window can hold hundreds of readings
        if len(t) > 1:
            sp = spend.spent_between(self.history, acct, t[:-1], t[1:])
            mv = k * (sp[:, FAMILIES.index(fam)] if fam else sp.sum(axis=1))
        else:
            mv = np.zeros(0)
        lo, hi = float(u[0]), float(u[0]) + 1.0
        for i in range(1, len(t)):
            moved = None
            if t[i] - t[i - 1] <= HOUR_MS and u[i] >= u[i - 1]:
                moved = float(mv[i - 1])
            p = float(u[i])
            if moved is not None and lo + moved < p + 1 and hi + moved > p:
                lo, hi = max(lo + moved, p), min(hi + moved, p + 1)
            else:
                lo, hi = p, p + 1.0
        last = float(u[-1])
        lo = min(max(lo - last, 0.0), 1.0 - 1e-6)
        hi = min(max(hi - last, lo + 1e-6), 1.0 - 1e-6)
        return lo, hi

    # ------------------------------------------------------------------
    # the bootstrap
    # ------------------------------------------------------------------
    def _spent(self, acct, t0, t1, fam):
        if t1 <= t0:
            return 0.0
        s = spend.spent_between(self.history, acct, int(t0), int(t1))[0]
        return float(s[FAMILIES.index(fam)] if fam else s.sum())

    def _series(self, acct, fam, lo, hi):
        """Capped-family dollars per bin over [lo, hi). Bins sit on an
        absolute lattice and the cache survives `update`, so a checkpoint
        only ever recomputes the tail that is new."""
        b = self.bin_ms
        lo = (lo // b) * b
        hi = -(-hi // b) * b
        key = (acct, fam)
        hit = self._sercache.get(key)
        if hit is not None and hit[0] <= lo:
            lo0, arr = hit
            # Turns become known with a lag, so the bins just before the
            # previous `now` can still be filling in: drop the last few and
            # recompute them with the tail.
            drop = min(int(6 * HOUR_MS / b), max(len(arr) - 1, 0))
            if drop:
                arr = arr[:-drop]
            end = lo0 + len(arr) * b
            if hi > end:
                edges = np.arange(end, hi + b, b, dtype=np.int64)
                sp = spend.spent_between(self.history, acct, edges[:-1] - 1, edges[1:] - 1)
                tail = sp[:, FAMILIES.index(fam)] if fam else sp.sum(axis=1)
                arr = np.concatenate([arr, tail])
                self._sercache[key] = (lo0, arr)
            i0 = (lo - lo0) // b
            return arr[int(i0):int((hi - lo0) // b)]
        edges = np.arange(lo, hi + b, b, dtype=np.int64)
        sp = spend.spent_between(self.history, acct, edges[:-1] - 1, edges[1:] - 1)
        v = sp[:, FAMILIES.index(fam)] if fam else sp.sum(axis=1)
        self._sercache[key] = (lo, v)
        return v

    def _anchor_weights(self, times, now, lead_total, state_now, gap_now, series, nb_state):
        """Kernel weights for candidate anchor times."""
        tz = spend.tz_offset_ms(self.history)
        loc = (times + tz) / HOUR_MS
        hod = loc % 24.0
        hod_now = ((now + tz) / HOUR_MS) % 24.0
        dh = np.abs(hod - hod_now)
        dh = np.minimum(dh, 24.0 - dh)
        bw = self.bw_hour + self.bw_hour_per_day * (lead_total / DAY_MS)
        w = np.exp(-0.5 * (dh / bw) ** 2)

        dow = np.floor(loc / 24.0) % 7
        dow_now = np.floor(((now + tz) / HOUR_MS) / 24.0) % 7
        we = (dow >= 5)
        we_now = bool(dow_now >= 5)
        mism = self.weekend_mismatch ** (1.0 / (1.0 + lead_total / DAY_MS))
        w = w * np.where(we == we_now, 1.0, mism)

        w = w * np.exp(-(now - times) / (self.recency_days * DAY_MS))

        c = np.concatenate(([0.0], np.cumsum(series)))
        idx = np.arange(len(times))
        for nb, s_now in zip(nb_state, state_now):
            s = c[idx + 1] - c[np.maximum(idx + 1 - nb, 0)]
            z = np.log1p(s) - np.log1p(max(s_now, 0.0))
            w = w * np.exp(-0.5 * (z / self.bw_state) ** 2)

        # How long since the capped family was last touched: "idle two hours"
        # and "idle two weeks" look identical in the windows above, and they
        # are the strongest signal of whether the cap moves again at all.
        if self.bw_gap > 0:
            used = np.flatnonzero(series > 0)
            if len(used):
                prev = np.maximum.accumulate(np.where(series > 0, idx, -1))
                gap_h = np.where(prev >= 0, (idx - prev) * self.bin_ms / HOUR_MS, 1e4)
                z = np.log1p(gap_h) - np.log1p(max(gap_now, 0.0))
                w = w * np.exp(-0.5 * (z / self.bw_gap) ** 2)
        return w

    def _rise(self, acct, fam, now, lead, reset, npaths, k_hat):
        """[npaths, len(lead)] of converted future rise, or (None, False)."""
        h = self.history
        L = float(lead[-1])
        bins = self.bin_ms
        lo = int(now - self.hist_days * DAY_MS)
        first = self._first_counted(acct, fam)
        if first is None:
            return None, False
        lo = max(lo, int(first))
        span = now - lo
        if span < max(2 * L, 3 * DAY_MS) and span < 2 * DAY_MS:
            return None, False
        # replay period: a whole number of days (weeks when there is room)
        period_ms = int(span // DAY_MS) * DAY_MS
        if period_ms >= 2 * WEEK_MS:
            period_ms = int(span // WEEK_MS) * WEEK_MS
        if period_ms < DAY_MS or period_ms < L / 4:
            return None, False
        lo = int(now - period_ms)
        series = self._series(acct, fam, lo, now)
        M = len(series)
        if M < self.min_anchors or series.sum() <= 0:
            return None, False

        groups = [(acct, series, 1.0)]
        for a in h.accounts:
            if a == acct or self.other_account <= 0:
                continue
            o = self._series(a, fam, lo, now)
            if len(o) == M and o.sum() > 0:
                sc = float(np.clip(series.sum() / o.sum(), 0.2, 5.0))
                groups.append((a, o * sc, self.other_account))

        nb_state = [max(int(w * HOUR_MS / bins), 1) for w in self.state_wins_h]
        times = lo + (np.arange(M) + 1) * bins          # bin end times
        st_now = [self._spent(acct, now - w * HOUR_MS, now, fam) for w in self.state_wins_h]
        gap_now = self._gap_now(acct, fam, now, series, lo, bins)
        W, S, A = [], [], []
        for a, ser, gw in groups:
            w = self._anchor_weights(times, now, L, st_now, gap_now, ser, nb_state)
            W.append(w * gw)
            S.append(ser)
            A.append(np.full(M, len(S) - 1))
        w = np.concatenate(W)
        gidx = np.concatenate(A)
        tot = w.sum()
        if not np.isfinite(tot) or tot <= 0:
            return None, False
        w = w / tot
        pick = self.rng.choice(len(w), size=npaths, replace=True, p=w)
        j = pick % M
        g = gidx[pick]

        x = np.asarray(lead, dtype=np.float64) / bins
        out = np.empty((npaths, len(lead)))
        xp = np.arange(2 * M + 1, dtype=np.float64)
        cums = []
        for a, ser, gw in groups:
            cums.append(np.concatenate(([0.0], np.cumsum(np.concatenate([ser, ser])))))
        for i in range(npaths):
            c = cums[int(g[i])]
            out[i] = np.interp(j[i] + x, xp, c) - c[j[i]]
        sc = np.exp(self.rng.normal(0.0, self.sigma_scale, size=npaths) - 0.5 * self.sigma_scale ** 2)
        return k_hat * sc[:, None] * out, True

    def _gap_now(self, acct, fam, now, series, lo, bins):
        """Hours since the capped family was last used, from the series (and
        1e4 when it was never used inside the replayed span)."""
        used = np.flatnonzero(series > 0)
        if not len(used):
            return 1e4
        return (now - (lo + (int(used[-1]) + 1) * bins)) / HOUR_MS

    def _first_counted(self, acct, fam):
        key = ("first", acct, fam)
        if key in self._cache:
            return self._cache[key]
        t = self.history.table("turns")
        if fam:
            t = t.filter(pl.col("model_family") == fam)
        v = None if t.height == 0 else int(t["t_event"].dt.epoch("ms").min())
        self._cache[key] = v
        return v

    # ------------------------------------------------------------------
    def _fallback_rise(self, acct, fam, m, now, lead, npaths, k_hat):
        """Recency-decayed burn, faded over the time left; lognormal spread."""
        span = min(DAY_MS, max(now - m.start, HOUR_MS))
        burn = self._spent(acct, now - span, now, fam) / span        # $/ms
        tau = self.fallback_tau_h * HOUR_MS
        centre = k_hat * burn * tau * (1.0 - np.exp(-np.asarray(lead) / tau))
        mult = np.exp(self.rng.normal(0.0, self.fallback_sigma, size=npaths)
                      - 0.5 * self.fallback_sigma ** 2)
        return mult[:, None] * centre[None, :]
