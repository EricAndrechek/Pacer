"""Kernel-weighted analog ensembles: the one statistical idea behind every
target of g1-10-fable-analog.

The forecast distribution of "what happens over the next τ" is read off the
account's own past: every past moment that looked like now (same phase of the
window, same local time of day / day of week, a similar recent burn, the same
account, not too long ago) contributes the trajectory that followed it, with
a kernel weight. Sample paths are those trajectories, re-based on the current
level. Nothing is parametric except the kernels; bandwidths widen until the
effective sample size is adequate, and a small pace-mixture fallback covers
cold starts (no complete past cycle yet).
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from arena.pricing import SYNTHETIC_MODEL
from kit import spend as S

MIN = 60_000
HOUR = 3_600_000
DAY = 24 * HOUR


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def step_at(t: np.ndarray, u: np.ndarray, q: np.ndarray, before: float = 0.0) -> np.ndarray:
    """Value of the step function (last reading at or before q); `before` when
    q precedes the first reading."""
    i = np.searchsorted(t, q, side="right") - 1
    return np.where(i >= 0, u[np.maximum(i, 0)], before)


def local_hour(t_ms, tz_ms: int) -> np.ndarray:
    return ((np.asarray(t_ms, dtype=np.float64) + tz_ms) % DAY) / HOUR


def local_dow(t_ms, tz_ms: int) -> np.ndarray:
    """0 = Monday … 6 = Sunday (1970-01-01 was a Thursday)."""
    return ((np.asarray(t_ms, dtype=np.int64) + tz_ms) // DAY + 3) % 7


def circ_diff(a: np.ndarray, b: float, period: float = 24.0) -> np.ndarray:
    d = np.abs(a - b) % period
    return np.minimum(d, period - d)


def gauss(x: np.ndarray, bw: float) -> np.ndarray:
    return np.exp(-0.5 * (x / bw) ** 2)


def ess(w: np.ndarray) -> float:
    s = w.sum()
    return float(s * s / (w * w).sum()) if s > 0 else 0.0


def widen_until(make_w, target_ess: float, max_rounds: int = 6, factor: float = 1.5):
    """Call `make_w(scale)` with growing bandwidth scales until the weights'
    effective sample size reaches `target_ess`; returns (w, scale, ess)."""
    scale = 1.0
    w = make_w(scale)
    e = ess(w)
    rounds = 0
    while e < target_ess and rounds < max_rounds:
        scale *= factor
        w = make_w(scale)
        e = ess(w)
        rounds += 1
    return w, scale, e


def sample_idx(rng: np.random.Generator, w: np.ndarray, n: int) -> np.ndarray:
    p = w / w.sum()
    return rng.choice(len(w), size=n, replace=True, p=p)


def tz_ms(history, account: str | None = None) -> int:
    tz = getattr(history, "tz_offset_min", None)
    if tz is not None:
        return int(tz) * MIN
    return S.tz_offset_ms(history, account)


# ---------------------------------------------------------------------------
# Meters: analogs cut from complete past cycles
# ---------------------------------------------------------------------------

@dataclass
class MeterTable:
    kind: str
    W: int                      # window ms
    lags: tuple[int, ...]       # rate feature lags (ms)
    M: int                      # trajectory points over the time left
    e: np.ndarray               # elapsed at the cut (ms)
    u0: np.ndarray              # level at the cut
    rates: np.ndarray           # [n, len(lags)] rise over each lag before the cut (points)
    hour: np.ndarray            # local hour at the cut
    dow: np.ndarray             # local weekday at the cut
    acct: np.ndarray            # account label (object)
    t_ref: np.ndarray           # the cycle's reset (for recency)
    D: np.ndarray               # [n, M] increment at fractions k/M of the time left
    n_cycles: int

    def __len__(self):
        return len(self.e)


def meter_lags(kind: str) -> tuple[int, ...]:
    return (15 * MIN, 60 * MIN) if kind == "five_hour" else (HOUR, 6 * HOUR, 24 * HOUR)


def build_meter_table(history, accounts, kind: str, cap: str | None, tz: int,
                      step: int, M: int, max_cycles: int = 400) -> MeterTable:
    W = S._cycles.window_ms(kind)
    lags = meter_lags(kind)
    fr = np.arange(1, M + 1) / M
    cols = {k: [] for k in ("e", "u0", "rates", "hour", "dow", "acct", "t_ref", "D")}
    n_cycles = 0
    for acct in accounts:
        cycles = S.past_cycles(history, acct, kind, cap)
        for c in cycles[-max_cycles:]:
            if len(c.t) == 0:
                continue
            W_c = c.reset - c.start
            # Usable when polling reached near the reset; the step function
            # holds the last reading over any final gap.
            complete = c.t[-1] >= c.reset - max(HOUR, 0.2 * W_c)
            if not complete:
                continue
            first_e = int(c.t[0] - c.start)
            e = np.arange(step, W_c - 5 * MIN, step, dtype=np.int64)
            e = e[e >= first_e]
            if len(e) == 0:
                continue
            q = c.start + e
            u0 = step_at(c.t, c.util, q)
            rates = np.stack([u0 - step_at(c.t, c.util, q - lag) for lag in lags], axis=1)
            rem = (c.reset - q).astype(np.float64)
            Q = q[:, None] + (fr[None, :] * rem[:, None]).astype(np.int64)
            D = step_at(c.t, c.util, Q.ravel()).reshape(Q.shape) - u0[:, None]
            cols["e"].append(e); cols["u0"].append(u0); cols["rates"].append(rates)
            cols["hour"].append(local_hour(q, tz)); cols["dow"].append(local_dow(q, tz))
            cols["acct"].append(np.full(len(e), acct, dtype=object))
            cols["t_ref"].append(np.full(len(e), c.reset, dtype=np.int64)); cols["D"].append(D)
            n_cycles += 1
    if n_cycles == 0:
        z = np.zeros(0)
        return MeterTable(kind, W, lags, M, z.astype(np.int64), z, np.zeros((0, len(lags))), z, z,
                          np.zeros(0, dtype=object), z.astype(np.int64), np.zeros((0, M)), 0)
    return MeterTable(kind, W, lags, M,
                      np.concatenate(cols["e"]), np.concatenate(cols["u0"]), np.vstack(cols["rates"]),
                      np.concatenate(cols["hour"]), np.concatenate(cols["dow"]), np.concatenate(cols["acct"]),
                      np.concatenate(cols["t_ref"]), np.vstack(cols["D"]), n_cycles)


@dataclass
class MeterQuery:
    e: float                    # elapsed ms at now
    remaining: float            # ms to reset
    u: float                    # latest reading
    rates: np.ndarray           # rise over each lag before now
    hour: float
    dow: int
    acct: str
    now: int


def meter_weights(T: MeterTable, q: MeterQuery, cfg: dict):
    kind = T.kind
    bw_phase = float(cfg.get("bw_phase_frac", 0.08)) * T.W
    bw_hour = float(cfg.get("bw_hour", 1.5))
    bw_rate = float(cfg.get("bw_rate", 0.7))
    tau = float(cfg.get("recency_days", 45)) * DAY
    other_acct = float(cfg.get("other_account", 0.3))
    weekend_mis = float(cfg.get("weekend_mismatch", 0.5))
    bw_level = float(cfg.get("bw_level", 0.0))
    lr = np.log1p(np.maximum(T.rates, 0.0))
    lq = np.log1p(np.maximum(q.rates, 0.0))
    wk_T = T.dow >= 5
    wk_q = q.dow >= 5
    base = (np.where(T.acct == q.acct, 1.0, other_acct)
            * np.exp(-(q.now - T.t_ref) / tau)
            * np.where(wk_T == wk_q, 1.0, weekend_mis))

    def make(scale):
        w = base * gauss(T.e - q.e, bw_phase * scale) * gauss(circ_diff(T.hour, q.hour), bw_hour * scale)
        for j in range(lr.shape[1]):
            w = w * gauss(lr[:, j] - lq[j], bw_rate * scale)
        if bw_level > 0:
            w = w * gauss(np.log1p(T.u0) - np.log1p(q.u), bw_level * scale)
        return w
    return widen_until(make, float(cfg.get("target_ess", 30)))


def meter_paths_from_table(T: MeterTable, q: MeterQuery, grid: np.ndarray, n_paths: int,
                           rng: np.random.Generator, cfg: dict, log=None):
    """Paths [n_paths, len(grid)] of the level, or None when the table is empty."""
    if len(T) == 0:
        return None, 0.0
    w, scale, e = meter_weights(T, q, cfg)
    if log is not None:
        log(f"meter {T.kind}: n={len(T)} ess={e:.1f} scale={scale:.2f} u={q.u:.0f} "
            f"rates={np.round(q.rates, 1).tolist()} e_h={q.e / HOUR:.2f}")
    if not np.isfinite(w).all() or w.sum() <= 0:
        return None, 0.0
    idx = sample_idx(rng, w, n_paths)
    fr = (grid.astype(np.float64) - q.now) / max(q.remaining, 1.0)
    fr = np.clip(fr, 0.0, 1.0)
    fk = np.concatenate(([0.0], np.arange(1, T.M + 1) / T.M))
    D = np.concatenate([np.zeros((len(idx), 1)), T.D[idx]], axis=1)
    # Pace scaling (local-linear flavour): an analog that was burning slower
    # than now is scaled up, and vice versa, by a damped ratio of paces.
    alpha = float(cfg.get("scale_alpha", 0.0))
    if alpha > 0:
        j = len(T.lags) - 1                   # the longest lag
        L = T.lags[j]
        c = float(cfg.get("scale_floor", 2.0))
        pace_q = 0.5 * max(q.rates[j], 0.0) + 0.5 * q.u / max(q.e, L) * L
        pace_a = 0.5 * np.maximum(T.rates[idx, j], 0.0) + 0.5 * T.u0[idx] / np.maximum(T.e[idx], L) * L
        s = ((pace_q + c) / (pace_a + c)) ** alpha
        s = np.clip(s, float(cfg.get("scale_min", 0.3)), float(cfg.get("scale_max", 3.0)))
        D = D * s[:, None]
    # Interpolate each analog's increment trajectory onto the grid fractions.
    pos = np.searchsorted(fk, fr, side="right") - 1
    pos = np.clip(pos, 0, T.M - 1)
    f0, f1 = fk[pos], fk[pos + 1]
    a = (fr - f0) / np.maximum(f1 - f0, 1e-12)
    inc = D[:, pos] * (1 - a) + D[:, pos + 1] * a
    # Readings are whole points: keep increments whole so the paths look like readings.
    inc = np.where(inc >= 0, np.floor(inc + 1e-9), np.ceil(inc - 1e-9))
    paths = np.clip(q.u + inc, 0.0, 100.0)
    return paths, e


def meter_paths_pace(q: MeterQuery, grid: np.ndarray, n_paths: int, rng: np.random.Generator,
                     kind: str) -> np.ndarray:
    """Cold-start fallback: a burst at a random rate for a random while.
    rate ~ blend of the recent and whole-cycle pace × lognormal(0, 0.7);
    duration ~ Exp(mean: 1.5 h for five-hour, 12 h for weekly); a share of
    the paths are idle (nothing more this cycle)."""
    lags = meter_lags(kind)
    r_recent = max(float(q.rates[j]) / (lags[j] / HOUR) for j in range(len(lags)))  # points per hour
    r_cycle = q.u / max(q.e / HOUR, 0.25)
    r = 0.6 * r_recent + 0.4 * r_cycle
    if r <= 0:
        r = 2.0 if kind == "five_hour" else 0.5
    p_idle = 0.5 if r_recent <= 0 else 0.15
    mean_T = 1.5 * HOUR if kind == "five_hour" else 12 * HOUR
    tau = (grid.astype(np.float64) - q.now)
    rate = r * np.exp(rng.normal(0.0, 0.7, size=n_paths))
    dur = rng.exponential(mean_T, size=n_paths)
    idle = rng.random(n_paths) < p_idle
    inc = rate[:, None] * np.minimum(tau[None, :], dur[:, None]) / HOUR
    inc[idle] = 0.0
    inc = np.floor(inc)
    return np.clip(q.u + inc, 0.0, 100.0)


# ---------------------------------------------------------------------------
# Meters: day-block bootstrap of hourly increments (uses every reading,
# including incomplete cycles and the cycle in progress)
# ---------------------------------------------------------------------------

def hourly_increments(series: dict, now: int, W: int, tz: int, days: int):
    """[n_days, 24] increments of the meter over each whole local hour of the
    last `days` local days (the day containing now last, partial), NaN where
    the hour crosses a reset or has no reading on either side of it."""
    t, u, reset, act = series["t"], series["p"], series["reset"], series["active"]
    keep = act & (t <= now)
    t, u, reset = t[keep], u[keep], reset[keep]
    if len(t) < 2:
        return None, None
    day0 = ((now + tz) // DAY) * DAY - tz           # start of today's local day (UTC ms)
    starts = day0 - np.arange(days - 1, -1, -1) * DAY
    edges = (starts[:, None] + np.arange(25)[None, :] * HOUR)          # [days, 25]
    flat = edges.ravel()
    i = np.searchsorted(t, flat, side="right") - 1
    ok = i >= 0
    lvl = np.where(ok, u[np.maximum(i, 0)], np.nan)
    rs = np.where(ok, reset[np.maximum(i, 0)], -1)
    lvl = lvl.reshape(edges.shape); rs = rs.reshape(edges.shape)
    inc = lvl[:, 1:] - lvl[:, :-1]
    same = np.abs(rs[:, 1:] - rs[:, :-1]) < W / 2
    inc = np.where(same, inc, np.nan)
    inc = np.where(np.isfinite(inc) & (inc < 0), 0.0, inc)          # a re-base is not usage
    # hours ending after now are unknown
    inc = np.where(edges[:, 1:] <= now, inc, np.nan)
    # hours before the first reading are unknown
    inc = np.where(edges[:, :-1] >= t[0] - HOUR, inc, np.nan)
    return starts, inc


def meter_block_paths(series: dict, q: "MeterQuery", grid: np.ndarray, W: int, tz: int, n_paths: int,
                      rng: np.random.Generator, cfg: dict, log=None):
    """Paths from day blocks: each future local day takes the hourly
    increments of one past day (weighted by recency and weekday type, with a
    mild preference for days whose total was like the recent ones), summed
    from the latest reading. The current partial hour is drawn from the hours
    with the same local hour."""
    days = int(cfg.get("block_days", 60))
    starts, inc = hourly_increments(series, q.now, W, tz, days)
    if inc is None:
        return None
    known = np.isfinite(inc)
    n_known = known.sum(axis=1)
    use = n_known >= 6
    if use.sum() < 2:
        return None
    starts, inc, known = starts[use], inc[use], known[use]
    tot = np.where(known, inc, 0.0).sum(axis=1) * 24.0 / np.maximum(known.sum(axis=1), 1)
    dow = local_dow(starts + 12 * HOUR, tz)
    wk = dow >= 5
    tau = float(cfg.get("block_recency_days", 21)) * DAY
    rec = np.exp(-(q.now - starts) / tau)
    # The pace to prefer: this cycle's own per-day pace blended with the
    # last day's rise (both in points per day), like the pace scaling.
    lt = np.log1p(tot)
    r_day = float(max(q.rates[-1], 0.0)) if len(q.rates) else 0.0
    pace_q = 0.5 * r_day + 0.5 * q.u / max(q.e, DAY) * DAY
    recent = float(np.log1p(pace_q))
    bw_tot = float(cfg.get("block_bw_total", 1.0))
    mis = float(cfg.get("weekend_mismatch", 0.5))
    n_h = int(np.ceil(q.remaining / HOUR)) + 2
    out = np.zeros((n_paths, len(grid)))
    hour_now = local_hour(np.array([q.now]), tz)[0]
    h0 = int(hour_now)
    # local-hour pool for the partial first hour
    pool = inc[:, h0][known[:, h0]]
    frac_first = 1.0 - (hour_now - h0)
    tgrid = (grid.astype(np.float64) - q.now) / HOUR          # hours ahead
    day_now = q.now + tz
    day_cursor_hours = h0                                       # local hour index of the current hour
    # Pre-draw, per path, one past day per future day.
    n_days_ahead = int(n_h // 24) + 2
    for p in range(n_paths):
        cum = np.zeros(n_h + 1)              # cumulative increment at hour boundaries ahead
        level = 0.0
        # partial current hour
        if len(pool):
            level += float(rng.choice(pool)) * frac_first
        cum[1] = level
        k = 1
        hr = h0 + 1
        d = 0
        qwk = (local_dow(np.array([q.now + d * DAY]), tz)[0] >= 5)
        chosen = None
        while k < n_h:
            if chosen is None or hr >= 24:
                if hr >= 24:
                    hr -= 24; d += 1
                    qwk = (local_dow(np.array([q.now + d * DAY]), tz)[0] >= 5)
                w = rec * np.where(wk == qwk, 1.0, mis) * gauss(lt - recent, bw_tot)
                if w.sum() <= 0:
                    w = rec
                chosen = int(sample_idx(rng, w, 1)[0])
            v = inc[chosen, hr]
            level += float(v) if np.isfinite(v) else 0.0
            cum[k + 1] = level
            k += 1; hr += 1
        # read the cumulative increment at the grid's hours ahead (linear within the hour)
        kk = np.clip(np.floor(tgrid).astype(int), 0, n_h - 1)
        a = tgrid - kk
        inc_g = cum[kk] * (1 - a) + cum[kk + 1] * a
        out[p] = np.floor(inc_g + 1e-9)
    paths = np.clip(q.u + out, 0.0, 100.0)
    if log is not None:
        log(f"block paths {series.get('kind', '')}: {len(starts)} days, recent={np.expm1(recent):.1f} pts/day")
    return paths


# ---------------------------------------------------------------------------
# Meters: day-activity model with shrinkage priors (cold-start robust)
# ---------------------------------------------------------------------------

# Default diurnal shape of meter increments (share per local hour), from the
# visible tier's turn activity profile; used until the account has its own.
_SHAPE = PROFILE_DEFAULT_SHAPE = np.array([0.17, 0.16, 0.14, 0.12, 0.14, 0.25, 0.45, 0.45, 0.48, 0.50, 0.53, 0.54,
                                           0.57, 0.54, 0.53, 0.52, 0.51, 0.47, 0.42, 0.37, 0.33, 0.27, 0.24, 0.20])
_SHAPE = _SHAPE / _SHAPE.sum()


def turn_day_activity(history, account: str, family: str | None, now: int, tz: int, days: int):
    """Per local day (oldest first, today last): the number of the account's
    turns (of one model family when given), and the hours since the last
    such turn at now (inf when none)."""
    import polars as pl
    t = history.table("turns")
    if not t.height:
        return np.zeros(days), np.inf
    f = t.filter((pl.col("account") == account) & (pl.col("model") != SYNTHETIC_MODEL))
    if family is not None:
        f = f.filter(pl.col("model_family") == family)
    te = f["t_event"].dt.epoch("ms").to_numpy().astype(np.int64)
    te = te[te <= now]
    if not len(te):
        return np.zeros(days), np.inf
    day0 = ((now + tz) // DAY) * DAY - tz
    d = (te + tz) // DAY - (day0 + tz) // DAY + (days - 1)       # 0..days-1, today = days-1
    counts = np.bincount(d[(d >= 0) & (d < days)], minlength=days).astype(np.float64)
    return counts, float(now - te.max()) / HOUR


def meter_daymodel_paths(series: dict, q: "MeterQuery", grid: np.ndarray, W: int, tz: int, n_paths: int,
                         rng: np.random.Generator, cfg: dict, log=None, turn_days=None, since_turn_h=np.inf):
    """Each future local day is active or idle (a two-state chain by weekday
    type, estimated from the account's own days and shrunk toward priors);
    an active day's total is drawn from the account's own active days pooled
    with a wide lognormal prior (weight fading as own days accumulate), and
    spread over the hours by one of the account's own day shapes or the
    default diurnal shape. The rest of today continues today's state."""
    days = int(cfg.get("block_days", 60))
    starts, inc = hourly_increments(series, q.now, W, tz, days)
    if inc is None:
        starts = np.array([((q.now + tz) // DAY) * DAY - tz]); inc = np.full((1, 24), np.nan)
    known = np.isfinite(inc)
    nk = known.sum(axis=1)
    tot = np.where(known, inc, 0.0).sum(axis=1) * 24.0 / np.maximum(nk, 1)
    wk = local_dow(starts + 12 * HOUR, tz) >= 5
    thr = float(cfg.get("active_pts", 2.0))
    hist_ok = (nk >= 6)
    hist_ok[-1] = False                                   # today is handled separately
    # --- activity chain: P(active | weekday type, previous day's state)
    prior_p = {False: float(cfg.get("prior_p_weekday", 0.7)), True: float(cfg.get("prior_p_weekend", 0.35))}
    n0 = float(cfg.get("prior_days", 4.0))
    act = tot >= thr
    if turn_days is not None and len(turn_days) == len(tot):
        # A day with turns of the counted family is active even when the
        # meter was not polled; a day without any is idle for the chain.
        has_turns = turn_days > 0
        act = np.where(hist_ok, act | has_turns, act)
        chain_ok = hist_ok | (np.arange(len(tot)) < len(tot) - 1)   # every past day informs the chain
        act_chain = np.where(hist_ok, act, has_turns)
    else:
        chain_ok, act_chain = hist_ok, act
    p_base = {}
    for k in (False, True):
        m = chain_ok & (wk == k)
        p_base[k] = (act_chain[m].sum() + n0 * prior_p[k]) / (m.sum() + n0)
    # persistence multipliers (prior 1.25 after an active day, 0.6 after an idle one)
    mult = {True: float(cfg.get("mult_after_active", 1.25)), False: float(cfg.get("mult_after_idle", 0.6))}
    if chain_ok.sum() >= 6:
        idx = np.flatnonzero(chain_ok)
        prev_act, cur_act, cur_p = [], [], []
        for i in idx[1:]:
            if chain_ok[i - 1]:
                prev_act.append(act_chain[i - 1]); cur_act.append(act_chain[i]); cur_p.append(p_base[wk[i]])
        prev_act, cur_act, cur_p = map(np.array, (prev_act, cur_act, cur_p))
        for s in (True, False):
            m = prev_act == s
            if m.sum():
                mult[s] = (cur_act[m].sum() + n0 * mult[s] * cur_p[m].mean()) / (cur_p[m].sum() + n0 * cur_p[m].mean())
    # --- active-day totals: own pool + prior
    own_tot = tot[hist_ok & act]
    own_rows = inc[hist_ok & act]
    own_rows = np.where(np.isfinite(own_rows), own_rows, 0.0)
    rec = np.exp(-(q.now - starts[hist_ok & act]) / (float(cfg.get("block_recency_days", 21)) * DAY))
    n_own = len(own_tot)
    n_prior = float(cfg.get("prior_total_n", 3.0))
    w_prior = n_prior / (n_own + n_prior)
    m0 = float(cfg.get("prior_total_median", 12.0)); s0 = float(cfg.get("prior_total_sigma", 0.9))
    # this cycle's own pace nudges the prior median (geometric blend)
    r_day = float(max(q.rates[-1], 0.0)) if len(q.rates) else 0.0
    pace_q = 0.5 * r_day + 0.5 * q.u / max(q.e, DAY) * DAY
    if pace_q > 0:
        m0 = float(np.exp(0.5 * np.log(m0) + 0.5 * np.log(max(pace_q, 1.0))))
    # own-day draw weights: recency × a mild preference for days whose total
    # matched this cycle's pace (the block bootstrap's strength on long histories)
    bw_tot = float(cfg.get("block_bw_total", 1.0))
    if n_own and pace_q > 0:
        rec = rec * gauss(np.log1p(own_tot) - np.log1p(pace_q), bw_tot)
        if rec.sum() <= 0:
            rec = np.ones(n_own)
    # --- today's state
    today = inc[-1]
    today_known = np.isfinite(today)
    today_sum = float(np.nansum(today)) if today_known.any() else 0.0
    today_active = today_sum >= 1.0 or (len(q.rates) and q.rates[0] > 0)
    if turn_days is not None:
        # the counted family's turns decide: active today if any in the last
        # few hours; a day with no such turn so far is not active yet
        recent_h = float(cfg.get("active_recent_h", 3.0))
        today_active = bool(since_turn_h <= recent_h) or (today_sum >= 1.0 and since_turn_h <= 12.0)
    hour_now = float(local_hour(np.array([q.now]), tz)[0]); h0 = int(hour_now)
    n_h = int(np.ceil(q.remaining / HOUR)) + 2
    tgrid = (grid.astype(np.float64) - q.now) / HOUR
    out = np.zeros((n_paths, len(grid)))
    wk_now = bool(local_dow(np.array([q.now]), tz)[0] >= 5)

    def draw_day():
        """24 hourly increments of one active day."""
        if n_own and rng.random() >= w_prior:
            i = int(sample_idx(rng, rec, 1)[0])
            return own_rows[i]
        total = m0 * np.exp(rng.normal(0.0, s0))
        if n_own and rng.random() < 0.5:
            row = own_rows[int(sample_idx(rng, rec, 1)[0])]
            shape = row / row.sum() if row.sum() > 0 else _SHAPE
        else:
            shape = _SHAPE
        return total * shape

    for p in range(n_paths):
        cum = np.zeros(n_h + 1)
        level = 0.0
        k = 0; hr = h0; d = 0
        state = today_active
        wkd = wk_now
        day = None
        if state:
            day = draw_day()
            # rest of today: scale so the remaining hours carry a typical remaining share
        else:
            # may still start later today: hazard over the remaining hours
            p_today = p_base[wkd] * mult[False] * float(_SHAPE[h0 + 1:].sum() / _SHAPE.sum()) if h0 < 23 else 0.0
            if rng.random() < p_today:
                day = draw_day(); state = True
        first = True
        while k < n_h:
            if hr >= 24:
                hr -= 24; d += 1
                wkd = bool(local_dow(np.array([q.now + d * DAY]), tz)[0] >= 5)
                prev = state
                state = rng.random() < min(0.98, p_base[wkd] * mult[prev])
                day = draw_day() if state else None
                first = False
            if day is not None:
                v = float(day[hr])
                if first and hr == h0:
                    v *= 1.0 - (hour_now - h0)
                level += v
            cum[k + 1] = level
            k += 1; hr += 1
        kk = np.clip(np.floor(tgrid).astype(int), 0, n_h - 1)
        a = tgrid - kk
        out[p] = np.floor(cum[kk] * (1 - a) + cum[kk + 1] * a + 1e-9)
    paths = np.clip(q.u + out, 0.0, 100.0)
    if log is not None:
        log(f"daymodel: own_active={n_own} w_prior={w_prior:.2f} m0={m0:.1f} p_base={{wd:{p_base[False]:.2f},we:{p_base[True]:.2f}}} "
            f"mult={{a:{mult[True]:.2f},i:{mult[False]:.2f}}} today_active={today_active}")
    return paths


# ---------------------------------------------------------------------------
# Hourly series: analog starts
# ---------------------------------------------------------------------------

def hourly_analog_paths(ends: np.ndarray, v: np.ndarray, H: int, now: int, tz: int, n_paths: int,
                        rng: np.random.Generator, cfg: dict, log=None) -> np.ndarray:
    """`v[k]` is the value of the hour ending `ends[k]` (ascending, the last
    ends at now). Paths over the next H hours from analog starts.

    A start j contributes v[j+1 : j+1+H]; when the history runs out the path
    continues from another start drawn on time of day alone (chained)."""
    L = len(v)
    if L < 3:
        base = float(v.mean()) if L else 0.0
        return np.full((n_paths, H), base)
    lv = np.log1p(np.maximum(v, 0.0))
    cs = np.concatenate(([0.0], np.cumsum(np.maximum(v, 0.0))))

    def recent(j, k):              # sum of v over the k hours ending at j (inclusive)
        lo = np.maximum(j - k + 1, 0)
        return cs[j + 1] - cs[lo]
    js = np.arange(0, L - 1)        # at least one future hour
    f1 = np.log1p(recent(js, 1)); f3 = np.log1p(recent(js, 3)); f24 = np.log1p(recent(js, 24))
    q1 = float(np.log1p(recent(L - 1, 1))); q3 = float(np.log1p(recent(L - 1, 3)))
    q24 = float(np.log1p(recent(L - 1, 24)))
    hour = local_hour(ends[js], tz); dow = local_dow(ends[js], tz)
    qh = float(local_hour(np.array([now]), tz)[0]); qd = int(local_dow(np.array([now]), tz)[0])
    tau = float(cfg.get("recency_days", 30)) * DAY
    rec = np.exp(-(now - ends[js]) / tau)
    wk = (dow >= 5) == (qd >= 5)
    avail = (L - 1) - js                 # future hours available from j
    bw_h = float(cfg.get("bw_hour", 1.5)); bw_r = float(cfg.get("bw_rate", 1.0))
    bw_24 = float(cfg.get("bw_day", 1.0)); mis = float(cfg.get("weekend_mismatch", 0.5))
    full = avail >= H
    pref_full = np.where(full, 1.0, float(cfg.get("partial_weight", 0.5)))

    def make(scale):
        return (rec * np.where(wk, 1.0, mis) * pref_full
                * gauss(circ_diff(hour, qh), bw_h * scale)
                * gauss(f1 - q1, bw_r * scale) * gauss(f3 - q3, bw_r * scale)
                * gauss(f24 - q24, bw_24 * scale))
    w, scale, e = widen_until(make, float(cfg.get("target_ess", 25)))
    if log is not None:
        log(f"hourly analogs: n={len(js)} ess={e:.1f} scale={scale:.2f}")
    if w.sum() <= 0:
        return np.full((n_paths, H), float(v[-24:].mean()))
    starts = sample_idx(rng, w, n_paths)
    # Optional level scaling: an analog whose last day was quieter than ours
    # is scaled up (damped ratio of 24-h sums), and vice versa.
    alpha = float(cfg.get("scale_alpha", 0.0))
    r24 = recent(js, 24); q24r = float(recent(L - 1, 24))
    c = float(cfg.get("scale_floor", 0.0)) or max(1e-9, 0.1 * float(np.mean(r24) + 1e-9))
    out = np.empty((n_paths, H))
    for p, j in enumerate(starts):
        filled = 0
        jj = int(j)
        guard = 0
        s = float(np.clip(((q24r + c) / (r24[j] + c)) ** alpha, 0.25, 4.0)) if alpha > 0 else 1.0
        while filled < H and guard < 20:
            take = min(H - filled, int(avail[jj]))
            if take > 0:
                out[p, filled:filled + take] = v[jj + 1: jj + 1 + take] * s
                filled += take
            # chain: another start at the same time of day as the gap begins
            hh = (qh + filled) % 24.0
            wc = rec * gauss(circ_diff(hour, hh), 2.0)
            wc[avail <= 0] = 0.0
            if wc.sum() <= 0:
                break
            jj = int(sample_idx(rng, wc, 1)[0])
            guard += 1
        if filled < H:
            out[p, filled:] = float(v.mean())
    return out


def share_analog_paths(ends: np.ndarray, share: np.ndarray, H: int, now: int, tz: int, n_paths: int,
                       rng: np.random.Generator, cfg: dict, n_group: int) -> np.ndarray:
    """share[k] in [0,1] or NaN (the group spent nothing that hour)."""
    L = len(share)
    valid = np.isfinite(share)
    equal = 1.0 / max(n_group, 1)
    if valid.sum() < 2:
        return np.full((n_paths, H), equal)
    # recent share: over the last 24 valid hours (weighted equally)
    last_valid = np.flatnonzero(valid)
    rs = float(np.nanmean(share[max(0, L - 24):])) if valid[max(0, L - 24):].any() else float(share[last_valid[-1]])
    # analog starts: hours j with at least one future hour
    js = np.arange(0, L - 1)
    # trailing 24-h mean share before each start (NaN-aware running mean)
    s0 = np.where(valid, share, 0.0); c0 = valid.astype(np.float64)
    cs, cc = np.concatenate(([0.0], np.cumsum(s0))), np.concatenate(([0.0], np.cumsum(c0)))
    lo = np.maximum(js - 23, 0)
    cnt = cc[js + 1] - cc[lo]
    f_rs = np.where(cnt > 0, (cs[js + 1] - cs[lo]) / np.maximum(cnt, 1), np.nan)
    hour = local_hour(ends[js], tz)
    qh = float(local_hour(np.array([now]), tz)[0])
    tau = float(cfg.get("recency_days", 30)) * DAY
    rec = np.exp(-(now - ends[js]) / tau)
    avail = (L - 1) - js
    bw_s = float(cfg.get("bw_share", 0.2))

    def make(scale):
        d = np.where(np.isfinite(f_rs), f_rs - rs, 0.0)
        return rec * gauss(circ_diff(hour, qh), 2.0 * scale) * gauss(d, bw_s * scale) * np.where(np.isfinite(f_rs), 1.0, 0.3)
    w, scale, e = widen_until(make, float(cfg.get("target_ess", 25)))
    if w.sum() <= 0:
        return np.full((n_paths, H), rs)
    # forward-filled share series for trajectories
    ff = share.copy()
    last = rs
    for k in range(L):
        if np.isfinite(ff[k]):
            last = ff[k]
        else:
            ff[k] = last
    starts = sample_idx(rng, w, n_paths)
    out = np.empty((n_paths, H))
    for p, j in enumerate(starts):
        take = min(H, int(avail[j]))
        out[p, :take] = ff[j + 1: j + 1 + take]
        if take < H:
            out[p, take:] = ff[j + take] if take > 0 else rs
    return np.clip(out, 0.0, 1.0)


# ---------------------------------------------------------------------------
# Next start of an idle five-hour window: a discrete-time hazard model
# ---------------------------------------------------------------------------

# Default idle factors (A1's visible history, see REPORT.md): the chance of a
# turn in the next hour relative to the hour-of-day profile, by idle so far.
IDLE_EDGES_H = np.array([0.5, 2.0, 6.0, 12.0, 24.0, 48.0])
IDLE_FACTOR_DEFAULT = np.array([2.0, 0.85, 0.35, 0.33, 0.15, 0.07, 0.10])
PROFILE_DEFAULT = np.array([0.17, 0.16, 0.14, 0.12, 0.14, 0.25, 0.45, 0.45, 0.48, 0.50, 0.53, 0.54,
                            0.57, 0.54, 0.53, 0.52, 0.51, 0.47, 0.42, 0.37, 0.33, 0.27, 0.24, 0.20])


def hazard_fit(T: np.ndarray, now: int, tz: int, max_days: int = 90, prior_n: float = 24.0,
               prior_idle: float = 120.0):
    """Estimate from the account's own turns: the hour-of-day × weekday-type
    profile P(turn within the next hour | local hour) and the idle factors,
    each shrunk toward the defaults with `prior_n` pseudo-observations."""
    prof = np.stack([PROFILE_DEFAULT, PROFILE_DEFAULT])          # [weekday, weekend]
    fac = IDLE_FACTOR_DEFAULT.copy()
    if len(T) < 2:
        return prof, fac
    lo = max(int(T[0]), now - max_days * DAY)
    t0 = np.arange(lo, now - HOUR, 15 * MIN, dtype=np.int64)
    if len(t0) < 8:
        return prof, fac
    ip = np.searchsorted(T, t0, side="right") - 1
    idle = np.where(ip >= 0, (t0 - T[np.maximum(ip, 0)]) / HOUR, np.nan)
    inx = np.searchsorted(T, t0, side="right")
    gap = np.where(inx < len(T), (T[np.minimum(inx, len(T) - 1)] - t0) / HOUR, np.inf)
    nxt = (gap <= 1.0).astype(np.float64)
    lh = local_hour(t0, tz).astype(int); wk = (local_dow(t0, tz) >= 5).astype(int)
    for k in range(2):
        for hr in range(24):
            m = (lh == hr) & (wk == k)
            n = m.sum()
            prof[k, hr] = (nxt[m].sum() + prior_n * PROFILE_DEFAULT[hr]) / (n + prior_n)
    base = prof[wk, lh]
    b = np.searchsorted(IDLE_EDGES_H, np.nan_to_num(idle, nan=0.0), side="right")
    for k in range(len(fac)):
        m = (b == k) & np.isfinite(idle)
        n = m.sum()
        if n:
            # ratio of observed starts to those the profile alone expects
            fac[k] = (nxt[m].sum() + prior_idle * IDLE_FACTOR_DEFAULT[k]) / (base[m].sum() + prior_idle)
    return prof, fac


def next_start_hazard_paths(T: np.ndarray, now: int, idle_since: int, horizon: int, tz: int,
                            n_paths: int, rng: np.random.Generator, cfg: dict, log=None) -> np.ndarray:
    prof, fac = hazard_fit(T, now, tz, int(cfg.get("max_days", 90)), float(cfg.get("prior_n", 24.0)),
                           float(cfg.get("prior_idle", 120.0)))
    last = T[T <= now]
    d0 = max(float(now - last[-1]) if len(last) else 0.0, float(now - idle_since)) / HOUR
    n_h = int(np.ceil((horizon - now) / HOUR))
    alive = np.ones(n_paths, dtype=bool)
    start = np.full(n_paths, np.nan)
    for k in range(n_h):
        t_k = now + k * HOUR
        hr = int(local_hour(np.array([t_k]), tz)[0]); wk = int(local_dow(np.array([t_k]), tz)[0] >= 5)
        d = d0 + k
        f = fac[int(np.searchsorted(IDLE_EDGES_H, d, side="right"))]
        p = min(1.0, prof[wk, hr] * f)
        hit = alive & (rng.random(n_paths) < p)
        start[hit] = t_k + rng.random(hit.sum()) * HOUR
        alive &= ~hit
    start = np.where(start <= horizon, start, np.nan)
    if log is not None:
        log(f"next_start hazard: idle_h={d0:.1f} p_start={np.isfinite(start).mean():.2f} "
            f"fac={np.round(fac, 2).tolist()}")
    return start


# ---------------------------------------------------------------------------
# Next start: empirical conditional gaps (kept as an alternative)
# ---------------------------------------------------------------------------

def turn_times(history, account: str) -> np.ndarray:
    t = history.table("turns")
    if not t.height:
        return np.zeros(0, np.int64)
    import polars as pl
    f = t.filter((pl.col("account") == account) & (pl.col("model") != SYNTHETIC_MODEL))
    return np.sort(f["t_event"].dt.epoch("ms").to_numpy().astype(np.int64))


def next_start_paths(T: np.ndarray, now: int, idle_since: int, horizon: int, tz: int, n_paths: int,
                     rng: np.random.Generator, cfg: dict, hist_start: int | None, log=None) -> np.ndarray:
    """Sampled start times (epoch ms) or NaN for 'not before the horizon'."""
    H = horizon - now
    if len(T) < 5:
        # a weak prior: half the paths start, uniformly over the horizon
        out = np.where(rng.random(n_paths) < 0.5, now + rng.random(n_paths) * H, np.nan)
        return out
    last = T[T <= now]
    d_star = float(now - last[-1]) if len(last) else float(now - idle_since)
    d_star = max(d_star, float(now - idle_since))
    step = 15 * MIN
    t0_lo = max(int(T[0]) + HOUR, hist_start if hist_start else int(T[0]))
    t0 = np.arange(t0_lo, now - H, step, dtype=np.int64)
    if len(t0) == 0:
        out = np.where(rng.random(n_paths) < 0.5, now + rng.random(n_paths) * H, np.nan)
        return out
    i_prev = np.searchsorted(T, t0, side="right") - 1
    idle = t0 - T[np.maximum(i_prev, 0)]
    idle = np.where(i_prev >= 0, idle, -1).astype(np.float64)
    i_next = np.searchsorted(T, t0, side="right")
    gap = np.where(i_next < len(T), T[np.minimum(i_next, len(T) - 1)] - t0, np.inf).astype(np.float64)
    ok = idle > 0
    t0, idle, gap = t0[ok], idle[ok], gap[ok]
    if len(t0) == 0:
        return np.where(rng.random(n_paths) < 0.5, now + rng.random(n_paths) * H, np.nan)
    hour = local_hour(t0, tz); dow = local_dow(t0, tz)
    qh = float(local_hour(np.array([now]), tz)[0]); qd = int(local_dow(np.array([now]), tz)[0])
    tau = float(cfg.get("recency_days", 30)) * DAY
    rec = np.exp(-(now - t0) / tau)
    wk = (dow >= 5) == (qd >= 5)
    mis = float(cfg.get("weekend_mismatch", 0.5))
    bw_h = float(cfg.get("bw_hour", 1.5)); bw_idle = float(cfg.get("bw_idle", 0.5))
    lid = np.log(idle / HOUR + 0.1); lq = np.log(d_star / HOUR + 0.1)

    target = float(cfg.get("target_ess", 30))
    trunc_frac = float(cfg.get("trunc_frac", 0.75))

    def make_with(trunc_scale):
        # Left truncation: the analog must have been idle at least about as
        # long as now. The hour / weekday / idle kernels widen first; the
        # truncation itself is relaxed only when that is not enough.
        trunc = np.where(idle >= trunc_frac * d_star / trunc_scale, 1.0, 0.0)

        def make(scale):
            return rec * np.where(wk, 1.0, mis) * trunc * gauss(circ_diff(hour, qh), bw_h * scale) \
                * gauss(lid - lq, bw_idle * scale)
        return widen_until(make, target, max_rounds=3)
    w, scale, e = make_with(1.0)
    ts = 1.0
    while e < target / 3 and ts < 8:
        ts *= 2.0
        w, scale, e = make_with(ts)
    if log is not None:
        log(f"next_start analogs: n={len(t0)} ess={e:.1f} scale={scale:.2f} idle_h={d_star / HOUR:.1f}")
    if w.sum() <= 0:
        return np.where(rng.random(n_paths) < 0.5, now + rng.random(n_paths) * H, np.nan)
    idx = sample_idx(rng, w, n_paths)
    g = gap[idx]
    # jitter within the 15-minute sampling step so paths are not quantised
    g = g + rng.random(n_paths) * step
    return np.where(g <= H, now + g, np.nan)
