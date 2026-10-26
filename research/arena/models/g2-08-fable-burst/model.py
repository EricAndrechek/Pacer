"""g2-08-fable-burst: the five-hour meter as a simulated burst process.

The five-hour meter climbs only while the user works, and work comes in
bursts: spells of turns separated by idle gaps whose length is the single
best predictor of whether the meter moves again before the reset (a user
idle for two hours rarely comes back inside the window; one who sent a turn
a minute ago almost always does). So the model simulates the activity
process explicitly and lets the burn ride on it:

1. **Activity.** The account's turn log is cut into 5-minute bins
   (active = any turn). Idle→active and active→idle hazards per bin depend
   on how long the current state has lasted (age buckets, estimated from the
   history's runs with weak prior pseudo-counts so three days of data still
   give a usable table) and, for idle→active, on the local hour of day (the
   account's own turn profile, shrunk toward flat when the history is
   short). The simulation starts in the state the account is in now, with
   the age it has now (minutes since the last turn, or the length of the
   current spell).

2. **Burn.** Each active bin burns `rate × noise` points, where the per-path
   rate is lognormal around a blend of the recent rate (burn over the last
   hour per active bin, from the readings and the converted spend) and the
   account's long-run points-per-active-bin; a small share of paths follow
   the long-run rate instead (a regime change). Idle bins burn nothing.
   Burn is never negative; the meter is capped at 100 (a user at the limit
   is blocked).

3. **Live start.** Readings are integers (floor), so the true meter sits in
   [u0, u0 + 1). Each path starts at u0 plus a uniform sub-point offset plus
   the spend since the last reading converted to points (kit.spend's fit of
   points per dollar by family), then is floored like the server's reading,
   so the dense head of the grid (+30 s … +5 min) predicts the next reading
   as the integer it will most likely be.

Everything is estimated inside `fit`/`forecast` from the history handed in;
the only shipped numbers are the prior hazard tables and the spread
parameters in model.toml, which were tuned on the visible tier.
"""
from __future__ import annotations

import math

import numpy as np
import polars as pl

from arena.types import Forecast, Target, TargetForecast
from kit import spend as kspend

MIN_MS = 60_000
HOUR_MS = 3_600_000
DAY_MS = 24 * HOUR_MS
WINDOW = "five_hour"
WINDOW_MS = 5 * HOUR_MS
SYNTHETIC = "<synthetic>"


class Model:
    def __init__(self, ctx):
        self.cfg = dict(ctx.config)
        self.rng = ctx.rng
        self.log = ctx.log
        self.history = None
        self._acct_cache: dict = {}
        self._price_cache = kspend.PriceCache()
        self.bin = int(self.cfg.get("bin_min", 5)) * MIN_MS
        self.edges = np.asarray(self.cfg.get("age_edges", [1, 2, 3, 4, 6, 9, 12, 18, 24, 36, 48, 72]), dtype=np.int64)
        self.prior_on = np.asarray(self.cfg.get("prior_h_on"), dtype=np.float64)
        self.prior_off = np.asarray(self.cfg.get("prior_h_off"), dtype=np.float64)

    # ------------------------------------------------------------------
    def fit(self, history):
        self.history = history
        self._acct_cache = {}

    def update(self, events):
        self.history = self.history.extend(events)
        self._acct_cache = {}

    def forecast(self, request):
        out = {}
        for tr in request.targets:
            if tr.target is not Target.METER_5H:
                continue
            try:
                out[tr.key] = self._five_hour(tr, int(request.now))
            except Exception as ex:  # never sink the whole request
                self.log(f"{tr.key}: fallback after {type(ex).__name__}: {ex}")
                out[tr.key] = self._flat(tr)
        return Forecast(out)

    # ------------------------------------------------------------------
    def _flat(self, tr):
        r = self._cycle_readings(tr.accounts[0], tr.reset_at, int(tr.grid[0]) - 1)
        u0 = float(r[1][-1]) if len(r[1]) else 0.0
        return TargetForecast.point(np.full(len(tr.grid), min(u0, 100.0)), tr.n_paths)

    def _readings(self, account):
        """One account's five-hour readings known by now: t, util, reset, active (event order)."""
        key = ("readings", account)
        if key not in self._acct_cache:
            r = kspend.meter_series(self.history, account, WINDOW)
            self._acct_cache[key] = r
        return self._acct_cache[key]

    def _cycle_readings(self, account, reset_at, now):
        """This cycle's readings known by now: the trailing run of active
        readings whose reset is within `reset_tol_min` of the latest one (the
        server's reset jitters by milliseconds; a jump of more than that is a
        new cycle even when the half-window rule would merge the two, which
        happens when an allowance is re-based while the old window still
        runs)."""
        r = self._readings(account)
        m = r["active"] & (r["t"] <= now)
        if reset_at is not None:
            m &= np.abs(r["reset"] - int(reset_at)) < WINDOW_MS / 2
        t, p, rs = r["t"][m], r["p"][m], r["reset"][m]
        if len(t) == 0:
            return t, p
        tol = float(self.cfg.get("reset_tol_min", 15)) * MIN_MS
        far = np.flatnonzero(np.abs(rs - rs[-1]) >= tol)
        if len(far):
            k = int(far[-1]) + 1
            t, p = t[k:], p[k:]
        return t, p

    def _bucket(self, age):
        return np.searchsorted(self.edges, np.asarray(age), side="right") - 1

    # ------------------------------------------------------------------
    def _activity(self, account):
        """Turn times (ms, sorted) of the account; falls back to the times the
        meter rose when the account has no turns in the history."""
        key = ("turns", account)
        if key in self._acct_cache:
            return self._acct_cache[key]
        t = self.history.table("turns")
        te = np.zeros(0, np.int64)
        if t.height:
            f = t.filter((pl.col("account") == account) & (pl.col("model") != SYNTHETIC)
                         & (pl.col("t_event").dt.epoch("ms") <= int(self.history.now)))
            te = np.sort(f["t_event"].dt.epoch("ms").to_numpy().astype(np.int64))
        proxy = False
        if len(te) < 20:
            r = self._readings(account)
            rose = np.flatnonzero(np.diff(r["p"]) > 0) + 1
            same = np.abs(np.diff(r["reset"])) < WINDOW_MS / 2
            rose = rose[same[rose - 1]] if len(rose) else rose
            te = np.sort(np.concatenate([te, r["t"][rose]])) if len(rose) else te
            proxy = True
        self._acct_cache[key] = (te, proxy)
        return te, proxy

    def _tz_ms(self):
        tz = getattr(self.history, "tz_offset_min", None)
        return int(tz) * MIN_MS if tz is not None else 0

    def _hazards(self, account, now):
        """Per-bin hazards by age bucket (idle->active, active->idle) and the
        hour-of-day multiplier of idle->active, from the account's activity
        bins over the whole history, blended with the prior pseudo-counts."""
        key = ("hazards", account)
        if key in self._acct_cache:
            return self._acct_cache[key]
        te, _ = self._activity(account)
        nbk = len(self.edges)
        ex_on = np.zeros(nbk); ev_on = np.zeros(nbk)
        ex_off = np.zeros(nbk); ev_off = np.zeros(nbk)
        hod_on = np.ones(24)
        hod_off = np.ones(24)
        if len(te) >= 2:
            origin = int(te[0]) - int(te[0]) % self.bin
            nb = int((now - origin) // self.bin) + 1
            if nb > 2_000_000:          # absurdly long history: keep the last ~7 years of bins
                origin = now - (2_000_000 - 1) * self.bin
                nb = 2_000_000
            b = np.zeros(nb, bool)
            k = ((te - origin) // self.bin).astype(np.int64)
            k = k[(k >= 0) & (k < nb)]
            b[k] = True
            ch = np.flatnonzero(np.diff(b)) + 1
            starts = np.concatenate(([0], ch)); ends = np.concatenate((ch, [nb]))
            age_all = np.zeros(nb, np.int64)
            for s, e in zip(starts, ends):
                L = int(e - s)
                ages = np.arange(1, L + 1)
                age_all[s:e] = ages
                bk = self._bucket(ages)
                if b[s]:
                    np.add.at(ex_off, bk, 1.0)
                    if e < nb:
                        ev_off[bk[-1]] += 1.0
                else:
                    np.add.at(ex_on, bk, 1.0)
                    if e < nb:
                        ev_on[bk[-1]] += 1.0
            # Hour-of-day modulation of idle->active: transitions per idle bin by local hour.
            tz = self._tz_ms()
            tb = origin + self.bin * np.arange(nb, dtype=np.int64)
            hod = (((tb + tz) % DAY_MS) // HOUR_MS).astype(np.int64)
            self._acct_cache[("bins", account)] = (b, age_all, hod, origin)
            idle = ~b
            shrink = float(self.cfg.get("hod_shrink_bins", 2000)) / 24.0
            trans = np.zeros(nb, bool); trans[:-1] = idle[:-1] & b[1:]
            n_idle = np.bincount(hod, weights=idle, minlength=24)[:24]
            n_tr = np.bincount(hod, weights=trans, minlength=24)[:24]
            base = trans.sum() / max(idle.sum(), 1.0)
            if base > 0:
                hod_on = (n_tr + shrink * base) / (n_idle + shrink) / base
                hod_on = np.clip(hod_on, 0.2, 3.0)
            # ... and of active->idle: spells end sooner at night.
            offt = np.zeros(nb, bool); offt[:-1] = b[:-1] & idle[1:]
            n_act = np.bincount(hod, weights=b, minlength=24)[:24]
            n_off = np.bincount(hod, weights=offt, minlength=24)[:24]
            base_off = offt.sum() / max(b.sum(), 1.0)
            if base_off > 0 and self.cfg.get("hod_off", True):
                hod_off = (n_off + shrink * base_off) / (n_act + shrink) / base_off
                hod_off = np.clip(hod_off, 0.33, 3.0)
        pw = float(self.cfg.get("prior_weight", 0.5)) * 288.0
        # Prior pseudo-exposure spread over buckets like a typical day's exposure.
        prior_ex_on = pw * np.array([0.03, 0.02, 0.015, 0.02, 0.02, 0.017, 0.027, 0.02, 0.037, 0.033, 0.055, 0.45])
        prior_ex_off = pw * np.array([0.12, 0.09, 0.07, 0.11, 0.12, 0.09, 0.13, 0.09, 0.1, 0.055, 0.055, 0.03])
        h_on = (ev_on + prior_ex_on * self.prior_on) / (ex_on + prior_ex_on)
        h_off = (ev_off + prior_ex_off * self.prior_off) / (ex_off + prior_ex_off)
        h_on = np.clip(h_on, 0.002, 0.95)
        h_off = np.clip(h_off, 0.01, 0.95)
        self._acct_cache[key] = (h_on, h_off, hod_on, hod_off)
        return h_on, h_off, hod_on, hod_off

    def _analog_activity(self, account, active0, age0, hod0, n_bins, n, rng):
        """Future activity sequences [n, n_bins] copied from the account's own
        past: bins in the same state with a similar age and local hour, whose
        following `n_bins` bins are all known. Tolerances widen until
        `min_analogs` candidates exist; None when even the widest fail."""
        got = self._acct_cache.get(("bins", account))
        if got is None:
            return None
        b, age_all, hod, origin = got
        nb = len(b)
        last = nb - 1 - n_bins          # the last start whose whole future is known
        if last < 10:
            return None
        k = np.arange(last + 1)
        same = b[:last + 1] == active0
        lage = np.log(age_all[:last + 1] + 0.5)
        la0 = math.log(age0 + 0.5)
        dh = np.abs(hod[:last + 1] - hod0); dh = np.minimum(dh, 24 - dh)
        min_n = int(self.cfg.get("min_analogs", 20))
        cand = None
        for age_tol, hod_tol in ((0.6, 2), (1.0, 3), (1.5, 5), (2.5, 8), (9.0, 12)):
            m = same & (np.abs(lage - la0) <= age_tol) & (dh <= hod_tol)
            if m.sum() >= min_n:
                cand = k[m]
                break
        if cand is None:
            cand = k[same] if same.sum() >= 5 else None
        if cand is None:
            return None
        pick = rng.choice(cand, size=n, replace=True)
        idx = pick[:, None] + 1 + np.arange(n_bins)[None, :]
        return b[idx]

    # ------------------------------------------------------------------
    def _long_run_rate(self, account, now):
        """Points per active bin over the history: total within-cycle rise of
        the meter divided by the number of active bins in the span where
        readings exist."""
        key = ("lr_rate", account)
        if key in self._acct_cache:
            return self._acct_cache[key]
        r = self._readings(account)
        te, _ = self._activity(account)
        rate = None
        m = r["active"] & (r["t"] <= now)
        if m.sum() >= 2:
            t, p, rs = r["t"][m], r["p"][m], r["reset"][m]
            same = np.abs(np.diff(rs)) < WINDOW_MS / 2
            inc = np.where(same, np.maximum(np.diff(p), 0.0), p[1:])
            rise = float(inc.sum())
            if len(te):
                k = np.unique(te[(te >= t[0]) & (te <= t[-1])] // self.bin)
                n_act = max(len(k), 1)
            else:
                n_act = max(int(np.sum(inc > 0)), 1)
            rate = rise / n_act
        self._acct_cache[key] = rate
        return rate

    def _conversion(self, account):
        """Points per USD per family (FAMILIES order), or None."""
        key = ("conv", account)
        if key in self._acct_cache:
            return self._acct_cache[key]
        rates = None
        try:
            d = kspend.fit_details(self.history, account, WINDOW)
            if d is not None and np.isfinite(d.rates).all() and d.rise >= 5:
                rates = np.asarray(d.rates, dtype=np.float64)
                if d.conversion.weak and d.pooled > 0:
                    rates = np.full(len(rates), float(d.pooled))
        except Exception as ex:
            self.log(f"conversion failed: {type(ex).__name__}: {ex}")
        self._acct_cache[key] = rates
        return rates

    def _spend_points(self, account, t0, t1, rates):
        if rates is None or t1 <= t0:
            return 0.0
        sp = kspend.spent_between(self.history, account, t0, t1)[0]
        return float(np.dot(sp, rates))

    # ------------------------------------------------------------------
    def _five_hour(self, tr, now):
        acct = tr.accounts[0]
        grid = np.asarray(tr.grid, dtype=np.int64)
        n_paths = int(tr.n_paths)
        reset = int(tr.reset_at) if tr.reset_at is not None else int(grid[-1])
        start = reset - WINDOW_MS
        t_c, u_c = self._cycle_readings(acct, tr.reset_at, now)
        if len(u_c):
            u0, t0 = float(u_c[-1]), int(t_c[-1])
            start = max(start, int(t_c[0]) - 2 * MIN_MS)
        else:
            u0, t0 = 0.0, start
        if u0 >= 100.0:
            return TargetForecast.point(np.full(len(grid), 100.0), n_paths)

        te, proxy = self._activity(acct)
        h_on, h_off, hod_on, hod_off = self._hazards(acct, now)
        rates = self._conversion(acct) if self.cfg.get("live_spend", True) else None

        # --- state now -------------------------------------------------
        te_now = te[te <= now]
        if len(te_now):
            last_turn = int(te_now[-1])
            idle_ms = now - last_turn
        else:
            last_turn, idle_ms = None, 10 * DAY_MS
        if idle_ms < self.bin:
            active0 = True
            # length of the current spell in bins (bins aligned to end at now)
            k = (now - te_now) // self.bin           # 0 = current bin
            present = np.zeros(int(k.max()) + 2, bool); present[k] = True
            run = 0
            while run < len(present) and present[run]:
                run += 1
            age0 = max(run, 1)
        else:
            active0 = False
            age0 = max(int(idle_ms // self.bin), 1)

        # --- rates -----------------------------------------------------
        lr = self._long_run_rate(acct, now)
        floor_rate = float(self.cfg.get("rate_floor", 0.3))
        if lr is None or not np.isfinite(lr) or lr <= 0:
            lr = 1.0
        lr = max(lr, floor_rate)
        # the readings lag the spend: converted spend since the last reading
        live_pts = self._spend_points(acct, t0, now, rates) if t0 < now else 0.0
        live_pts = min(max(live_pts, 0.0), 100.0 - u0)
        k_rec = float(self.cfg.get("k_recent", 3.0))
        eps = 0.15

        def window_rate(minutes):
            """(points per active bin over the last `minutes`, weight) from the readings."""
            w0 = max(now - int(minutes) * MIN_MS, start)
            if len(t_c):
                i = np.searchsorted(t_c, w0, side="right") - 1
                u_w0 = float(u_c[i]) if i >= 0 else 0.0
            else:
                u_w0 = 0.0
            b = max(u0 - u_w0, 0.0) + live_pts
            n = len(np.unique(te_now[te_now > w0] // self.bin)) if len(te_now) else 0
            if n == 0:
                return lr, 0.0, 0
            return b / n, n / (n + k_rec), n

        windows = self.cfg.get("recent_windows", [30, 90])
        ests = [window_rate(m) for m in windows]
        n_act_rec = max(e[2] for e in ests)
        r_rec = float(np.mean([e[0] for e in ests]))
        # whole-cycle rate so far
        n_act_cyc = len(np.unique(te_now[te_now > start] // self.bin)) if len(te_now) else 0
        burn_cyc = u0 + live_pts
        if n_act_cyc > 0:
            r_cyc = burn_cyc / n_act_cyc
        else:
            r_cyc = lr
        logs = []
        for r_w, w_w, _ in ests:
            w_c = (1 - w_w) * n_act_cyc / (n_act_cyc + 2 * k_rec) if n_act_cyc > 0 else 0.0
            w_l = 1.0 - w_w - w_c
            logs.append(w_w * math.log(r_w + eps) + w_c * math.log(r_cyc + eps) + w_l * math.log(lr + eps))
        log_r = float(np.mean(logs))
        r_hat = max(math.exp(log_r) - eps, floor_rate * 0.5) * float(self.cfg.get("rate_mult", 1.0))

        # --- simulate ----------------------------------------------------
        n_bins = int(math.ceil((grid[-1] - now) / self.bin))
        n_bins = max(n_bins, 1)
        rng = self.rng
        sigma = float(self.cfg.get("sigma_rate", 0.55))
        # the rate is less certain when it rests on few active bins of evidence
        sig_n = float(self.cfg.get("sigma_n", 0.0))
        if sig_n > 0:
            sigma = math.sqrt(sigma * sigma + sig_n * sig_n / max(n_act_rec, 1))
        p_reg = float(self.cfg.get("p_regime", 0.15))
        shape = float(self.cfg.get("gamma_shape", 1.5))
        regime = rng.random(n_paths) < p_reg
        base_rate = np.where(regime, lr, r_hat)
        rate = base_rate * np.exp(sigma * rng.standard_normal(n_paths) - 0.5 * sigma * sigma)
        # a burst regime (subagent fan-out, a heavier model): a share of paths run several times faster
        tail_p = float(self.cfg.get("tail_p", 0.1))
        tail_mult = float(self.cfg.get("tail_mult", 2.5))
        hot = rng.random(n_paths) < tail_p
        rate = np.where(hot, rate * tail_mult, rate)
        rate = np.maximum(rate, 0.0)
        tz = self._tz_ms()
        # frailty: futures differ in how busy they are; a persistent per-path factor
        # on the hazards (busy paths resume faster and stop slower) spreads the
        # active time across paths, which a homogeneous chain averages away
        fs = float(self.cfg.get("frailty_sd", 0.0))
        frail = np.exp(fs * rng.standard_normal(n_paths)) if fs > 0 else np.ones(n_paths)
        active = np.full(n_paths, active0)
        age = np.full(n_paths, age0, dtype=np.int64)
        # activity: a share of the paths copy the account's own past (analogs of the
        # state now), the rest run the hazard chain
        share = float(self.cfg.get("analog_share", 0.7))
        n_an = int(round(share * n_paths))
        hod0 = int(((now + tz) % DAY_MS) // HOUR_MS)
        seq = self._analog_activity(acct, active0, age0, hod0, n_bins, n_an, rng) if n_an > 0 else None
        n_an = 0 if seq is None else seq.shape[0]
        frac_all = np.zeros((n_paths, n_bins))
        if n_an:
            frac_all[:n_an] = seq.astype(np.float64)
        for j in range(n_bins):
            t_bin = now + j * self.bin
            hod = int(((t_bin + tz) % DAY_MS) // HOUR_MS)
            bk = self._bucket(age)
            p_on = np.minimum(h_on[bk] * hod_on[hod] * frail, 0.95)
            p_off = np.minimum(h_off[bk] * hod_off[hod] / frail, 0.95)
            u = rng.random(n_paths)
            switch = np.where(active, u < p_off, u < p_on)
            # burn during this bin: a bin that stays active burns fully, one that switches burns half
            frac = np.where(active, np.where(switch, 0.5, 1.0), np.where(switch, 0.5, 0.0))
            frac_all[n_an:, j] = frac[n_an:]
            age = np.where(switch, 1, age + 1)
            active = np.where(switch, ~active, active)
        noise = rng.gamma(shape, 1.0 / shape, (n_paths, n_bins))
        burn = np.zeros((n_paths, n_bins + 1))
        burn[:, 1:] = np.cumsum(frac_all * rate[:, None] * noise, axis=1)
        # --- to the grid ---------------------------------------------------
        t_rel = self.bin * np.arange(n_bins + 1, dtype=np.float64)
        g_rel = (grid - now).astype(np.float64)
        idx = np.clip(np.searchsorted(t_rel, g_rel, side="right") - 1, 0, n_bins - 1)
        w = (g_rel - t_rel[idx]) / self.bin
        at = burn[:, idx] * (1 - w) + burn[:, idx + 1] * w
        offset = rng.random(n_paths)[:, None]                 # sub-point position of the true meter
        val = u0 + offset + live_pts + at
        paths = np.floor(val + 1e-9)
        paths = np.maximum.accumulate(np.clip(paths, u0, 100.0), axis=1)
        self.last_diag = dict(u0=u0, live=round(live_pts, 2), act=active0, age=age0, r_hat=round(r_hat, 2),
                              r_rec=round(r_rec, 2), r_cyc=round(r_cyc, 2), lr=round(lr, 2), n_rec=n_act_rec,
                              proxy=proxy, lead_h=round((grid[-1] - now) / HOUR_MS, 2), n_an=n_an)
        return TargetForecast(paths)
