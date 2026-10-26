"""Analog block-bootstrap for hourly spend / tokens.

Every forecast path is chained from 24 h blocks of the group's own past. For
each block a path picks a historical start whose local time of day is close,
whose weekday is similar, and whose recent activity (last hour, 3 h, day, week)
looks like the path's own state at that point; then it copies what happened
next, scaled by the ratio of recent levels. Zeros, bursts and diurnal shape
come out of the data, and the spread is the spread of comparable pasts.
"""
from __future__ import annotations

import numpy as np

from kit import spend as S
from levelfeat import MeterLevel

HOUR = 3_600_000
DAY = 24 * HOUR
FEAT_H = 168


def _src_between(ledgers, cols, t0, t1, what):
    """Sum over accounts (and family columns) of the value in each (t0, t1]."""
    out = np.zeros(np.broadcast(t0, t1).shape if np.ndim(t0) or np.ndim(t1) else 1)
    for led in ledgers:
        if not len(led.t):
            continue
        per = led.between(t0, t1, what)
        out = out + (per.sum(axis=1) if cols is None else per[:, cols])
    return out


class LedgerStore:
    """Per-account cumulative ledgers (kit.spend._Ledger) built once per
    History, with turns priced through one PriceCache so a re-fit on the
    extended history only prices the rows that are new or changed."""

    def __init__(self):
        import polars as pl
        self.pl = pl
        self.pc = S.PriceCache()
        self._key = None
        self._ledgers = {}

    def get(self, history, accounts):
        key = (int(history.now), id(history))
        if key != self._key:
            self._key, self._ledgers = key, {}
            pl = self.pl
            t = history.table("turns").filter(pl.col("model") != S.SYNTHETIC_MODEL)
            self._priced = self.pc.price(t, history) if t.height else t
        out = []
        for a in accounts:
            if a not in self._ledgers:
                self._ledgers[a] = self._build(a)
            out.append(self._ledgers[a])
        return out

    def _build(self, account):
        pl = self.pl
        p = self._priced
        if p.height == 0:
            return S._EMPTY
        p = p.filter(pl.col("account") == account)
        if p.height == 0:
            return S._EMPTY
        p = p.sort("t_event", maintain_order=True)
        t = p["t_event"].dt.epoch("ms").to_numpy().astype(np.int64)
        fam = S._family_index(p["model_family"])
        cost = p["cost_usd"].fill_null(0.0).fill_nan(0.0).to_numpy().astype(np.float64)
        out_best = (pl.when((pl.col("output_reliable") == False) & pl.col("output_imputed").is_not_null())  # noqa: E712
                    .then(pl.col("output_imputed")).otherwise(pl.col("output").cast(pl.Float64)))
        tok = p.select((pl.col("input").cast(pl.Float64).fill_null(0) + out_best.fill_null(0)
                        + pl.col("cache_read").cast(pl.Float64).fill_null(0)
                        + pl.col("cache_write_5m").cast(pl.Float64).fill_null(0)
                        + pl.col("cache_write_1h").cast(pl.Float64).fill_null(0)).alias("x"))["x"]
        tok = tok.to_numpy().astype(np.float64)
        n = len(t)
        nf = len(S.FAMILIES)
        C = np.zeros((n + 1, nf))
        K = np.zeros((n + 1, nf))
        np.add.at(C[1:], (np.arange(n), fam), cost)
        np.add.at(K[1:], (np.arange(n), fam), tok)
        return S._Ledger(t, np.cumsum(C, axis=0), np.cumsum(K, axis=0), fam, cost)


class HourlyAnalog:
    def __init__(self, history, accounts, what, family, cfg, rng, ledgers=None):
        self.cfg, self.rng = cfg, rng
        self.now = int(history.now)
        self.what = what
        self.ledgers = ledgers if ledgers is not None else [S._ledger(history, a) for a in accounts]
        self.cols = None if family is None else S.FAMILIES.index(family)
        self.level = None          # levelfeat.MeterLevel, set by the model
        self.k_level = None        # points of that meter per unit of this series
        starts = [int(led.t[0]) for led in self.ledgers if len(led.t)]
        self.t0 = min(starts) if starts else self.now
        tz = history.tz_offset_min
        self.tz = (0 if tz is None else int(tz)) * 60_000

    def vals(self, t0, t1):
        return _src_between(self.ledgers, self.cols, np.asarray(t0, dtype=np.int64),
                            np.asarray(t1, dtype=np.int64), self.what)

    def hourly(self, ends, n):
        """[len(ends), n] hourly values: column j is the hour ending ends - (n-1-j) h."""
        ends = np.asarray(ends, dtype=np.int64)
        e = ends[:, None] - HOUR * np.arange(n - 1, -1, -1, dtype=np.int64)[None, :]
        v = self.vals((e - HOUR).ravel(), e.ravel())
        return v.reshape(e.shape)

    def weekday(self, t):
        return (((np.asarray(t, dtype=np.int64) + self.tz) // DAY) + 3) % 7

    def tod_h(self, t):
        return (((np.asarray(t, dtype=np.int64) + self.tz) % DAY) / HOUR)


def _features(h):
    """h: [n, FEAT_H] hourly values (last column newest) -> [n, 4] log features
    (last hour, last 3 h, last 24 h mean, last week mean)."""
    return np.stack([h[:, -1], h[:, -3:].mean(axis=1), h[:, -24:].mean(axis=1), h.mean(axis=1)], axis=1)


def _temper(a_state, a_static, ess_min):
    """Per path, the largest lam in [0, 1] such that the weights
    exp(lam * a_state + a_static) keep an effective sample size >= ess_min."""
    P = a_state.shape[0]
    lo = np.zeros(P)
    hi = np.ones(P)

    def ess(lam):
        lw = lam[:, None] * a_state + a_static
        lw = lw - lw.max(axis=1, keepdims=True)
        w = np.exp(lw)
        return w.sum(axis=1) ** 2 / (w ** 2).sum(axis=1)

    ok = ess(hi) >= ess_min
    for _ in range(8):
        mid = 0.5 * (lo + hi)
        good = ess(mid) >= ess_min
        lo = np.where(good, mid, lo)
        hi = np.where(good, hi, mid)
    return np.where(ok, 1.0, lo)


def forecast_paths(src: HourlyAnalog, grid, n_paths, cfg):
    cfg = dict(cfg)
    now = src.now
    grid = np.asarray(grid, dtype=np.int64)
    K = len(grid)
    block_h = int(cfg.get("block_h", 24))
    margin = int(cfg.get("margin_min", 30)) * 60_000
    step = int(cfg.get("cand_step_min", 30)) * 60_000
    max_dev = float(cfg.get("max_dev_h", 3.0)) * HOUR
    sig_t = float(cfg.get("sigma_tod_h", 1.5)) * HOUR
    half_life = float(cfg.get("half_life_days", 35.0)) * DAY
    sig_state = np.array(cfg.get("sigma_state", [1.5, 1.3, 1.0, 0.8]), dtype=np.float64)
    w_same_dow = float(cfg.get("w_dow", [1.0, 0.55, 0.2])[0]), float(cfg.get("w_dow", [1.0, 0.55, 0.2])[1]), float(cfg.get("w_dow", [1.0, 0.55, 0.2])[2])
    gamma = float(cfg.get("level_gamma", 0.5))
    jitter = float(cfg.get("jitter", 0.25))
    block_sigma = float(cfg.get("block_sigma", 0.0))
    rng = src.rng
    ess_min = float(cfg.get('ess_min', 25))
    sig_lvl = float(cfg.get('sigma_level', 15.0))
    sig_ttr = float(cfg.get('sigma_ttr', 1.0))
    lvl = getattr(src, 'level', None)
    use_lvl = lvl is not None and getattr(src, 'k_level', None) is not None and sig_lvl > 0
    if use_lvl:
        kl = float(src.k_level)
        l0, ttr0 = lvl.at(np.array([now]))
        if not np.isfinite(l0[0]):
            use_lvl = False
        else:
            lp = np.full(n_paths, float(l0[0]))                # per-path level
            R_known = (now + float(ttr0[0])) if np.isfinite(ttr0[0]) else None

    # reference scale for log features: typical positive hourly value
    hist_h = src.hourly(np.array([now]), min(int((now - src.t0) // HOUR), 24 * 60))[0] if now > src.t0 else np.zeros(1)
    pos = hist_h[hist_h > 0]
    ref = float(np.median(pos)) if len(pos) else 1.0
    ref = max(ref, 1e-9)

    def lf(x):
        return np.log1p(x / ref)

    # per-path rolling hourly state (last FEAT_H hours), seeded with the real past
    past = src.hourly(np.array([now]), FEAT_H)[0]
    state = np.tile(past[None, :], (n_paths, 1))
    # hours before the history existed carry no information: treat as the mean level of known hours
    known_h = int(max(0, (now - src.t0) // HOUR))
    if known_h < FEAT_H:
        fill = past[FEAT_H - known_h:].mean() if known_h > 0 else 0.0
        state[:, : FEAT_H - known_h] = fill

    n_blocks = int(np.ceil(K / block_h))
    out = np.zeros((n_paths, K))
    t_hist_end = now - margin
    for b in range(n_blocks):
        k0, k1 = b * block_h, min((b + 1) * block_h, K)
        L = k1 - k0
        t_b = now + b * block_h * HOUR              # block start (hour ending grid[k0-1] ~ t_b)
        # candidate starts: wall-clock time-of-day within max_dev of t_b, whole block inside known history
        latest = t_hist_end - block_h * HOUR
        earliest = src.t0
        if latest <= earliest:
            cands = np.zeros(0, dtype=np.int64)
        else:
            base = np.arange(earliest, latest + 1, step, dtype=np.int64)
            dtod = ((src.tod_h(base) - src.tod_h(np.array([t_b]))[0] + 12) % 24 - 12) * HOUR
            cands = base[np.abs(dtod) <= max_dev]
        if len(cands) < 8:
            # cold start: nothing aligned; fall back to the recent hourly mean with noise
            lvl_mean = past[-min(known_h, 72):].mean() if known_h > 0 else 0.0
            pos_frac = float((past[-min(known_h, 72):] > 0).mean()) if known_h > 0 else 0.0
            vals = np.where(rng.random((n_paths, L)) < pos_frac,
                            lvl_mean / max(pos_frac, 1e-6) * rng.lognormal(-0.5, 1.0, (n_paths, L)), 0.0)
            out[:, k0:k1] = vals
            state = np.concatenate([state[:, L:], vals], axis=1) if L < FEAT_H else vals[:, -FEAT_H:]
            continue
        dtod = ((src.tod_h(cands) - src.tod_h(np.array([t_b]))[0] + 12) % 24 - 12) * HOUR
        # analog data: features from the 168 h before the candidate, the block's own L hours after
        ends_prior = cands
        hp = src.hourly(ends_prior, FEAT_H)
        # hours before the data began count as unknown -> replace by the candidate's mean known level
        unknown = (ends_prior[:, None] - HOUR * np.arange(FEAT_H - 1, -1, -1)[None, :]) <= src.t0
        if unknown.any():
            cnt = np.maximum((~unknown).sum(axis=1), 1)
            fillv = (np.where(unknown, 0.0, hp).sum(axis=1) / cnt)[:, None]
            hp = np.where(unknown, fillv, hp)
        fc = lf(_features(hp))                        # [C, 4]
        if use_lvl:
            lc, ttr_c = lvl.at(cands)
            lc = np.where(np.isfinite(lc), lc, 0.0)
        e_next = cands[:, None] + HOUR * np.arange(1, L + 1, dtype=np.int64)[None, :]
        fut = src.vals((e_next - HOUR).ravel(), e_next.ravel()).reshape(e_next.shape)   # [C, L]
        # time-of-day & recency & weekday weights (state-independent)
        wd_now = src.weekday(np.array([t_b]))[0]
        wd_c = src.weekday(cands - 0)
        d = np.abs(wd_c - wd_now)
        d = np.minimum(d, 7 - d)
        both_wk = (wd_c < 5) == (wd_now < 5)
        w_dow = np.where(d == 0, w_same_dow[0], np.where(both_wk, w_same_dow[1], w_same_dow[2]))
        w_static = (np.exp(-0.5 * (dtod / sig_t) ** 2) * w_dow
                    * 0.5 ** (np.maximum(now - cands, 0) / half_life))
        # per-path state features
        fp = lf(_features(state))                       # [P, 4]
        dist = ((fp[:, None, :] - fc[None, :, :]) / sig_state[None, None, :]) ** 2
        a_state = -0.5 * dist.sum(axis=2)               # [P, C]
        if use_lvl:
            a_state = a_state - 0.5 * ((lp[:, None] - lc[None, :]) / sig_lvl) ** 2
            if R_known is not None and sig_ttr > 0:
                R_eff = R_known if R_known > t_b else R_known + 7 * DAY * np.ceil((t_b - R_known) / (7 * DAY) + 1e-9)
                ttr_p = (R_eff - t_b) / HOUR
                ok_c = np.isfinite(ttr_c)
                d_t = np.where(ok_c, (np.log1p(ttr_p) - np.log1p(np.where(ok_c, ttr_c, 0.0) / HOUR)) / sig_ttr, 0.0)
                a_state = a_state - 0.5 * (d_t[None, :] ** 2)
        a_static = np.log(w_static + 1e-300)[None, :]
        lam = _temper(a_state, a_static, ess_min)
        logw = lam[:, None] * a_state + a_static
        logw -= logw.max(axis=1, keepdims=True)
        w = np.exp(logw)
        w /= w.sum(axis=1, keepdims=True)
        # draw one analog per path
        cum = np.cumsum(w, axis=1)
        u = rng.random((n_paths, 1))
        idx = np.minimum((cum < u).sum(axis=1), len(cands) - 1)
        vals = fut[idx]                                  # [P, L]
        # level adjustment: ratio of weekly mean levels
        lvl_now = state.mean(axis=1) + 1e-9 * ref
        lvl_c = hp[idx].mean(axis=1) + 1e-9 * ref
        rho = np.clip((lvl_now / lvl_c) ** gamma, 0.25, 4.0)
        vals = vals * rho[:, None]
        if block_sigma > 0:
            vals = vals * np.exp(rng.normal(-0.5 * block_sigma ** 2, block_sigma, (n_paths, 1)))
        if jitter > 0:
            vals = np.where(vals > 0, vals * np.exp(rng.normal(0.0, jitter, vals.shape) - 0.5 * jitter ** 2), 0.0)
        out[:, k0:k1] = vals
        state = np.concatenate([state[:, L:], vals], axis=1) if L < FEAT_H else vals[:, -FEAT_H:]
        if use_lvl:
            t_e = t_b + L * HOUR
            if R_known is not None and t_b < R_known <= t_e:
                h_R = int(np.ceil((R_known - t_b) / HOUR))
                lp = np.clip(kl * vals[:, h_R:].sum(axis=1), 0.0, 100.0) if h_R < L else np.zeros(n_paths)
            else:
                lp = np.clip(lp + kl * vals.sum(axis=1), 0.0, 100.0)
    return out


def attach_level(src, history, accounts, cfg, cache=None):
    """Give `src` the weekly-meter level feature when the history has one."""
    if float(cfg.get("sigma_level", 15.0)) <= 0:
        return src
    key = (id(history), tuple(accounts))
    if cache is not None and key in cache:
        lvl = cache[key]
    else:
        lvl = MeterLevel(history, accounts, cfg.get("level_kind", "seven_day"))
        if cache is not None:
            cache.clear()
            cache[key] = lvl
    if lvl.ok:
        k = lvl.rate(src.vals, src.now)
        if k is not None:
            src.level, src.k_level = lvl, k
    return src
