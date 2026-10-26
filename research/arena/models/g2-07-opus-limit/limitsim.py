"""Level-aware block-bootstrap simulation of a rate-limit meter to its reset.

The question this answers well is the limit call: will the meter reach 100
before it resets, and when. Three things decide it, and each is learned from
the account's own recent readings (recency-weighted, shrunk to priors):

1. **Burn.** The meter's own past burn on a regular step grid (hourly for the
   weekly meters, 5 min for the five-hour one), from the cumulative series
   that ignores re-bases and cycle resets (`kit.fm.series.meter_series`).
   Future steps are copied from the past in blocks (stationary bootstrap,
   geometric block lengths) that start at the same local time of day, so a
   path keeps the user's daily rhythm and multi-day runs of heavy or light
   use. The first block starts at past moments whose recent burn looks like
   now's (a session in progress continues; an idle night stays idle).
   Steps the user spent parked near the top or blocked at 100 are replaced
   by unconstrained steps at the same time of day: they say how the user
   behaves near the limit, not how much they use the account.
2. **Behaviour near the limit.** Many users stop short of 100 on a weekly
   meter (switching account, rationing): the chance a step with burn stays
   active, by level band, relative to the unconstrained level, is learned
   from the account's history. Each future step's burn is kept with that
   probability at the path's current level. With no evidence it is 1 (a
   user who runs into the wall).
3. **Re-bases.** The server sometimes zeroes or lowers an allowance mid-cycle
   (the reset stays). A per-step hazard from the history's own falls drops a
   path to a low level, after which it burns on.

Paths are integer meter values (readings are integers) on the step grid,
read at the request's grid by linear interpolation.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

MIN = 60_000
HOUR = 60 * MIN
DAY = 24 * HOUR

WINDOW = {"five_hour": 5 * HOUR, "seven_day": 7 * DAY, "weekly_scoped": 7 * DAY}

DEFAULTS = {
    "five_hour": dict(step_min=5, lookback_days=45, half_life_days=14.0, block_mean=18,
                      lags=(1, 3, 12), bw=0.6, bands=(90, 95, 99), park_from=101,
                      prior_hours=2.0, rebase_prior=0.0, rebase_weeks_prior=4.0,
                      min_hist_steps=36, intensity_sigma=0.4,
                      zone_lo=90, park_frac=0.12, ceil_half_life_days=28.0, ceil_prior_w100=0.5,
                      prior_park={"95": 0.1, "97": 0.1, "99": 0.3}, leak_prior=0.005, leak_prior_hours=48.0,
                      late_h=24.0, leak_late_prior=0.02, leak_late_prior_hours=24.0, delay_min_stay_h=12.0),
    "seven_day": dict(step_min=60, lookback_days=60, half_life_days=28.0, block_mean=36,
                      lags=(1, 3, 24), bw=0.6, bands=(90, 95, 99), park_from=95,
                      prior_hours=2.0, rebase_prior=0.1, rebase_weeks_prior=4.0,
                      min_hist_steps=12, intensity_sigma=1.2,
                      zone_lo=90, park_frac=0.12, ceil_half_life_days=28.0, ceil_prior_w100=0.5,
                      prior_park={"95": 0.1, "97": 0.1, "99": 0.3}, leak_prior=0.005, leak_prior_hours=48.0,
                      late_h=24.0, leak_late_prior=0.02, leak_late_prior_hours=24.0, delay_min_stay_h=12.0),
    "weekly_scoped": dict(step_min=60, lookback_days=60, half_life_days=28.0, block_mean=36,
                          lags=(1, 3, 24), bw=0.6, bands=(90, 95, 99), park_from=95,
                          prior_hours=2.0, rebase_prior=0.1, rebase_weeks_prior=4.0,
                          min_hist_steps=12, intensity_sigma=1.6,
                          zone_lo=90, park_frac=0.12, ceil_half_life_days=28.0, ceil_prior_w100=0.5,
                          prior_park={"95": 0.1, "97": 0.1, "99": 0.3}, leak_prior=0.005, leak_prior_hours=48.0,
                      late_h=24.0, leak_late_prior=0.02, leak_late_prior_hours=24.0, delay_min_stay_h=12.0),
}


@dataclass
class StepHist:
    """One meter on a regular step grid ending at now (oldest first)."""

    t_end: np.ndarray      # int64 step end times
    burn: np.ndarray       # float: burn within the step (>= 0)
    level: np.ndarray      # float: the meter as read at the step's start (0 when idle)
    tod: np.ndarray        # int: local step-of-day of the step end
    age_days: np.ndarray   # float: now - t_end in days
    covered: np.ndarray    # bool: a reading within the step or just before it


def step_history(times, cum, util, active, now: int, step: int, lookback: int, tz_ms: int,
                 stale: int) -> StepHist:
    n = int(lookback // step)
    t_end = int(now) - step * np.arange(n, -1, -1, dtype=np.int64)          # n + 1 edges
    i = np.searchsorted(times, t_end, side="right") - 1
    ok = i >= 0
    c = np.where(ok, cum[np.maximum(i, 0)], 0.0)
    lv = np.where(ok & active[np.maximum(i, 0)], util[np.maximum(i, 0)], 0.0)
    fresh = ok & ((t_end - times[np.maximum(i, 0)]) <= stale)
    burn = np.maximum(np.diff(c), 0.0)
    start_known = ok[:-1]
    keep = start_known
    te = t_end[1:][keep]
    spd = DAY // step
    tod = (((te + tz_ms) % DAY) // step).astype(np.int64) % spd
    return StepHist(te, burn[keep], lv[:-1][keep], tod, (now - te) / DAY,
                    (fresh[1:] | fresh[:-1])[keep])


def recency(age_days: np.ndarray, half_life: float) -> np.ndarray:
    return np.power(0.5, np.maximum(age_days, 0.0) / max(half_life, 1e-6))


def band_index(level: np.ndarray, bands) -> np.ndarray:
    """0 = below the first band edge, k = in [bands[k-1], bands[k]), len(bands)+1 = at 100."""
    b = np.searchsorted(np.asarray(bands, dtype=np.float64), level, side="right")
    return np.where(level >= 100, len(bands) + 1, b)


@dataclass
class Behaviour:
    keep: np.ndarray          # per band (0..len(bands)): chance an active step stays active
    rebase_per_step: float
    rebase_to: float


def learn_behaviour(hists: list[tuple[StepHist, float]], bands, half_life: float, prior_hours: float,
                    step: int, rebase_prior_per_week: float, rebase_weeks_prior: float,
                    falls: list[tuple[np.ndarray, np.ndarray]]) -> Behaviour:
    """Pool the given meters' histories (each with a weight: the account's own
    1, others less) into per-band keep probabilities and a re-base hazard."""
    nb = len(bands) + 1
    act = np.zeros(nb + 1)
    wsum = np.zeros(nb + 1)
    for h, wt in hists:
        if not len(h.burn):
            continue
        w = recency(h.age_days, half_life) * wt * h.covered
        b = band_index(h.level, bands)
        a = (h.burn > 0).astype(np.float64)
        act += np.bincount(b, weights=w * a, minlength=nb + 1)[: nb + 1]
        wsum += np.bincount(b, weights=w, minlength=nb + 1)[: nb + 1]
    base = act[0] / wsum[0] if wsum[0] > 0 else 0.0
    keep = np.ones(nb)
    hours_per_step = step / HOUR
    if base > 0:
        for k in range(1, nb):
            # Pseudo-observations at the unconstrained rate (keep = 1).
            pw = prior_hours / hours_per_step
            rate = (act[k] + pw * base) / (wsum[k] + pw)
            keep[k] = float(np.clip(rate / base, 0.0, 1.0))
    # Re-base hazard: falls per week of observed meter, recency-weighted.
    n_fall, weeks = 0.0, 0.0
    for (h, wt), (ft, fa) in zip(hists, falls):
        if not len(h.burn):
            continue
        w = recency(h.age_days, half_life) * wt
        weeks += float(w.sum()) * step / (7 * DAY)
        if len(ft):
            n_fall += float((recency((h.t_end[-1] - ft) / DAY, half_life) * wt).sum())
    per_week = (n_fall + rebase_prior_per_week * rebase_weeks_prior) / (weeks + rebase_weeks_prior)
    per_step = 1.0 - math.exp(-per_week * step / (7 * DAY))
    return Behaviour(keep, per_step, 0.0)


def find_falls(times, util, active, reset, duration: int, min_drop: float = 10.0):
    """Re-bases: a reading at least `min_drop` below the previous one of the
    same cycle (same reset within half a window)."""
    if len(times) < 2:
        return np.zeros(0, np.int64), np.zeros(0)
    a = active[1:] & active[:-1]
    same = np.abs(reset[1:] - reset[:-1]) < duration / 2
    drop = (util[:-1] - util[1:]) >= min_drop
    m = a & same & drop
    return times[1:][m], util[1:][m]


def simulate(h: StepHist, beh: Behaviour, u0: float, now: int, reset: int, step: int, tz_ms: int,
             n_paths: int, rng: np.random.Generator, cfg: dict, bands,
             ceil: np.ndarray | None = None, leak_per_step: float = 0.0,
             delay: np.ndarray | None = None) -> tuple[np.ndarray, np.ndarray]:
    """Paths on the step grid: times [H + 1] (now first) and values [n_paths, H + 1]."""
    H = max(1, int(math.ceil((reset - now) / step)))
    times = now + step * np.arange(H + 1, dtype=np.int64)
    out = np.empty((n_paths, H + 1))
    out[:, 0] = u0
    if u0 >= 100:
        out[:] = 100.0
        return times, out
    N = len(h.burn)
    spd = DAY // step
    half_life = float(cfg["half_life_days"])
    if N < 2 or h.burn.sum() <= 0:
        out[:] = u0
        return times, out
    park_from = float(cfg["park_from"])
    # Unconstrained burn: steps parked near the top or blocked are replaced by
    # a random unconstrained step at the same time of day (fresh per path).
    w_rec = recency(h.age_days, half_life)
    free = (h.level < min(park_from, 100.0)) & (h.level < 100)
    # candidate pools per tod
    pools = {}
    for d in range(spd):
        idx = np.nonzero(h.tod == d)[0]
        pools[d] = idx
    free_pools = {}
    for d in range(spd):
        idx = np.nonzero((h.tod == d) & free)[0]
        if len(idx) == 0:
            idx = pools[d]
        if len(idx) == 0:
            idx = np.arange(N)
        p = w_rec[idx]
        free_pools[d] = (idx, p / p.sum())
    # Similarity of the state before each candidate start to now's.
    lags = tuple(int(x) for x in cfg["lags"])
    csum = np.concatenate(([0.0], np.cumsum(h.burn)))
    def recent(k_end):   # burn over the `lag` steps ending at index k_end (exclusive)
        return np.stack([csum[k_end] - csum[np.maximum(k_end - L, 0)] for L in lags], axis=-1)
    now_feat = recent(np.array([N]))[0]
    tod_next = int(((times[1] + tz_ms) % DAY) // step) % spd
    first_idx = pools[tod_next]
    first_idx = first_idx[first_idx >= max(lags)]
    if len(first_idx) == 0:
        first_idx = pools[tod_next] if len(pools[tod_next]) else np.arange(N)
    f = recent(first_idx)
    bw = float(cfg["bw"])
    d2 = ((np.log1p(f) - np.log1p(now_feat[None, :])) ** 2).sum(axis=1)
    w_first = w_rec[first_idx] * np.exp(-0.5 * d2 / bw ** 2)
    if not np.isfinite(w_first).all() or w_first.sum() <= 0:
        w_first = w_rec[first_idx]
    w_first = w_first / w_first.sum()
    # Jump candidates per tod (block starts after the first): recency only.
    jump = {}
    for d in range(spd):
        idx = pools[d]
        if len(idx) == 0:
            idx = np.arange(N)
        p = w_rec[idx]
        jump[d] = (idx, p / p.sum())
    p_jump = 1.0 / max(float(cfg["block_mean"]), 1.0)
    keep = beh.keep
    nb = len(keep)
    ptr = rng.choice(first_idx, size=n_paths, p=w_first)
    u = np.full(n_paths, float(u0))
    sig = float(cfg.get("intensity_sigma", 0.0))
    fac = np.exp(sig * rng.standard_normal(n_paths) - 0.5 * sig ** 2) if sig > 0 else None
    # Nowcast of how busy this account is: its burn over the last few days
    # against what the resampled past says it should be (partial pooling).
    alpha = float(cfg.get("recent_alpha", 0.0))
    if alpha > 0:
        L_rec = max(1, int(float(cfg.get("recent_hours", 72)) * HOUR / step))
        if N > L_rec:
            recent_rate = h.burn[-L_rec:].sum() / L_rec
            wf = w_rec * free
            base_rate = float((h.burn * wf).sum() / max(wf.sum(), 1e-9))
            if base_rate > 0:
                ratio = (recent_rate + 0.1 * base_rate) / (1.1 * base_rate)
                sc = float(np.clip(ratio ** alpha, float(cfg.get("recent_min", 0.15)), float(cfg.get("recent_max", 3.0))))
                fac = sc * (fac if fac is not None else np.ones(n_paths))
    carry = np.zeros(n_paths)
    tods = (((times[1:] + tz_ms) % DAY) // step).astype(np.int64) % spd
    for j in range(H):
        d = int(tods[j])
        if j > 0:
            nxt = ptr + 1
            jm = (rng.random(n_paths) < p_jump) | (nxt >= N) | (h.tod[np.minimum(nxt, N - 1)] != d)
            if delay is not None:
                jm |= delay == j          # resuming after the idle stretch: a fresh block
            if jm.any():
                idx, p = jump[d]
                nxt[jm] = rng.choice(idx, size=int(jm.sum()), p=p)
            ptr = nxt
        b = h.burn[ptr].copy()
        if delay is not None:
            b[delay > j] = 0.0
        parked = ~free[ptr]
        if parked.any():
            idx, p = free_pools[d]
            b[parked] = h.burn[rng.choice(idx, size=int(parked.sum()), p=p)]
        if fac is not None:
            # A path-level intensity (this week busier or quieter than the
            # recent past), applied to whole points with the remainder carried.
            x = b * fac + carry
            b = np.floor(x)
            carry = x - b
        # behaviour near the limit
        band = np.minimum(band_index(u, bands), nb - 1)
        kp = keep[band]
        active = b > 0
        drop = active & (rng.random(n_paths) >= kp)
        b[drop] = 0.0
        # re-base
        if beh.rebase_per_step > 0:
            rb = rng.random(n_paths) < beh.rebase_per_step
            if rb.any():
                u[rb] = beh.rebase_to
        if ceil is not None:
            lps = float(leak_per_step[j]) if np.ndim(leak_per_step) else float(leak_per_step)
            if lps > 0:
                held = (ceil < 100) & (u >= ceil)
                lk = held & (rng.random(n_paths) < lps)
                ceil[lk] = 100.0
            u = np.minimum(u + b, np.maximum(ceil, u))
        u = np.minimum(u + b, 100.0) if ceil is None else np.minimum(u, 100.0)
        out[:, j + 1] = u
    return times, out


def to_grid(times: np.ndarray, vals: np.ndarray, grid: np.ndarray) -> np.ndarray:
    """Linear interpolation of every path at the grid times."""
    g = np.asarray(grid, dtype=np.float64)
    t = times.astype(np.float64)
    i = np.clip(np.searchsorted(t, g, side="right") - 1, 0, len(t) - 2)
    w = np.clip((g - t[i]) / (t[i + 1] - t[i]), 0.0, 1.0)
    return vals[:, i] * (1 - w) + vals[:, i + 1] * w


# ---------------------------------------------------------------------------
# Ceilings: where a user stops short of the limit
# ---------------------------------------------------------------------------

@dataclass
class CycleTop:
    t_ref: int            # when the cycle's top was reached (for recency)
    top: float            # the highest reading of the cycle
    observed: bool        # True: the user stopped there (or reached 100); False: censored
    parked_hours: float   # hours spent at the top with time still left (parked)
    leaked: bool          # parked first, then went on to 100
    park_start: int = 0   # parked from (ms)
    park_end: int = 0     # until (the leak, or the reset)
    reset: int = 0


def cycle_tops(times, util, active, reset, duration: int, now: int, zone_lo: float,
               park_min: int) -> list[CycleTop]:
    """Per completed cycle of one meter (known at now): its top, and whether
    the user stopped there by choice. A top of 100 is observed (the limit).
    A top below 100 counts as a chosen ceiling when it is at least `zone_lo`
    and the meter sat within a point of it for at least `park_min` with the
    reset still ahead; otherwise the cycle just ended (censored: the ceiling
    is at least the top)."""
    out: list[CycleTop] = []
    if len(times) == 0:
        return out
    m = active & (reset > 0)
    if not m.any():
        return out
    t, u, r = times[m], util[m], reset[m]
    # cycles by reset (half a window apart)
    order = np.argsort(r, kind="stable")
    rs = r[order]
    cyc = np.zeros(len(rs), np.int64)
    anchor, c = rs[0], 0
    for j in range(1, len(rs)):
        if rs[j] - anchor >= duration / 2:
            c += 1
            anchor = rs[j]
        cyc[j] = c
    cyc_of = np.empty(len(rs), np.int64)
    cyc_of[order] = cyc
    for k in range(int(cyc.max()) + 1):
        sel = cyc_of == k
        tk, uk = t[sel], u[sel]
        o = np.argsort(tk, kind="stable")
        tk, uk = tk[o], uk[o]
        R = int(np.median(r[sel]))
        if R > now:
            continue                                   # the cycle in progress: not a past outcome
        top = float(uk.max())
        if top >= 100:
            i100 = int(np.argmax(uk >= 100))
            # parked at 99 (or just below) for long before going over?
            pre = (uk[:i100] >= 99) if i100 > 0 else np.zeros(0, bool)
            ph = 0.0
            if pre.any():
                i99 = int(np.argmax(pre))
                ph = (tk[i100] - tk[i99]) / HOUR
            leaked = ph * HOUR >= park_min
            ps = int(tk[int(np.argmax(pre))]) if leaked else 0
            out.append(CycleTop(int(tk[i100]), 100.0, True, ph, leaked, ps, int(tk[i100]) if leaked else 0, R))
            continue
        near = uk >= top - 1
        i0 = int(np.argmax(near))
        ph = (R - tk[i0]) / HOUR
        parked = top >= zone_lo and (R - tk[i0]) >= park_min
        out.append(CycleTop(int(tk[i0]), top, bool(parked), ph if parked else 0.0, False,
                            int(tk[i0]) if parked else 0, R if parked else 0, R))
    return out


@dataclass
class Ceilings:
    levels: np.ndarray     # candidate ceilings (ints, the last is 100)
    hazard: np.ndarray     # P(C = level | C >= level), per level (100: 1)
    leak_per_hour: float
    leak_late_per_hour: float = 0.0
    late_h: float = 0.0


def learn_ceilings(tops: list[tuple[CycleTop, float]], now: int, half_life_days: float,
                   zone_lo: float, prior_w100: float, leak_prior: float, leak_prior_hours: float,
                   prior_park: dict | None = None, late_h: float = 0.0, leak_late_prior: float = 0.0,
                   leak_late_prior_hours: float = 0.0) -> Ceilings:
    levels = np.arange(int(zone_lo), 101)
    d = np.zeros(len(levels))
    n = np.zeros(len(levels))
    leaks, ph = 0.0, 0.0
    late_leaks, late_ph = 0.0, 0.0
    for ct, wt in tops:
        w = wt * recency(np.array([(now - ct.t_ref) / DAY]), half_life_days)[0]
        top = int(round(ct.top))
        if top < levels[0]:
            continue                    # never got near: says nothing about the ceiling
        at_risk = levels <= top
        n[at_risk] += w
        if ct.observed:
            d[levels == top] += w
        if ct.parked_hours > 0 and late_h > 0 and ct.park_end > ct.park_start:
            # exposure split at `late_h` before the reset
            edge = ct.reset - late_h * HOUR
            early = max(0.0, min(ct.park_end, edge) - ct.park_start) / HOUR
            late = max(0.0, ct.park_end - max(ct.park_start, edge)) / HOUR
            ph += w * early
            late_ph += w * late
            if ct.leaked:
                if ct.park_end > edge:
                    late_leaks += w
                else:
                    leaks += w
        elif ct.parked_hours > 0:
            ph += w * ct.parked_hours
            if ct.leaked:
                leaks += w
    d[-1] += prior_w100
    n += prior_w100
    # Prior pseudo-cycles that parked at a few high levels: users of a pacing
    # app often stop short of the wall, and the time a meter has already sat
    # still near the top can only update a prior that allows it.
    for lvl, w in (prior_park or {}).items():
        k = int(lvl)
        if k < levels[0] or k >= 100:
            continue
        n[levels <= k] += w
        d[levels == k] += w
    with np.errstate(invalid="ignore", divide="ignore"):
        hz = np.where(n > 0, d / n, 0.0)
    hz[-1] = 1.0
    leak = (leaks + leak_prior * leak_prior_hours) / (ph + leak_prior_hours)
    late = ((late_leaks + leak_late_prior * leak_late_prior_hours) / (late_ph + leak_late_prior_hours)
            if late_h > 0 else leak)
    return Ceilings(levels, hz, float(leak), float(late), float(late_h))


def zero_burn_survival(h: StepHist, hours: float, step: int, half_life: float, free: np.ndarray) -> float:
    """Chance that ordinary use leaves the meter unmoved for `hours`: the
    recency-weighted share of past windows that long with no burn."""
    L = max(1, int(round(hours * HOUR / step)))
    if len(h.burn) <= L:
        return 0.0
    cs = np.concatenate(([0.0], np.cumsum(h.burn)))
    win = cs[L:] - cs[:-L]                                   # windows ending at index j+L-1
    ok = np.convolve(free.astype(np.float64), np.ones(L), "valid") >= L
    w = recency(h.age_days[L - 1:], half_life) * ok
    if w.sum() <= 0:
        return 0.0
    return float((w * (win <= 0)).sum() / w.sum())


def ceiling_posterior(ce: Ceilings, u_now: float, stay_hours: float, surv) -> tuple[np.ndarray, np.ndarray]:
    """P(C = level | C >= u_now, the meter has sat at u_now for stay_hours).
    Returns (levels, probs) over levels >= u_now."""
    u = int(round(u_now))
    m = ce.levels >= u
    lv, hz = ce.levels[m], ce.hazard[m]
    if len(lv) == 0:
        return np.array([100]), np.array([1.0])
    p = np.empty(len(lv))
    s = 1.0
    for i in range(len(lv)):
        p[i] = s * hz[i]
        s *= 1 - hz[i]
    p[-1] += s
    if stay_hours > 0 and lv[0] == u and u < 100:
        # Ceilings above now would have moved the meter by now (unless the
        # user simply hasn't used it): weigh them by that chance.
        k = surv(stay_hours)
        p[1:] *= k
    tot = p.sum()
    return lv, (p / tot if tot > 0 else np.r_[np.zeros(len(lv) - 1), 1.0])


def idle_runs(h: StepHist, half_life: float, free: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Lengths (steps) of the past's maximal runs of zero burn in the
    unconstrained region, with a recency weight each (by the run's end)."""
    z = (h.burn <= 0) & free
    if not z.any():
        return np.zeros(0), np.zeros(0)
    edges = np.diff(np.concatenate(([0], z.astype(np.int8), [0])))
    starts = np.nonzero(edges == 1)[0]
    ends = np.nonzero(edges == -1)[0]
    lens = (ends - starts).astype(np.float64)
    keep = ends < len(z)                      # a run still going at now is not a finished length
    w = recency(h.age_days[np.minimum(ends, len(z) - 1)], half_life)
    return lens[keep], w[keep]


def resume_delay(lens: np.ndarray, w: np.ndarray, stay_steps: float, n: int, rng, tail_mult: float = 0.5) -> np.ndarray:
    """Steps until a meter idle for `stay_steps` moves again: the residual of
    past idle runs longer than the stay; an exponential tail when none is."""
    m = lens > stay_steps
    if m.sum() >= 3:
        p = w[m] / w[m].sum()
        r = rng.choice(lens[m] - stay_steps, size=n, p=p)
        # a little jitter inside a run's step
        return np.maximum(1, np.ceil(r * rng.uniform(0.5, 1.5, size=n))).astype(np.int64)
    mean = max(stay_steps * tail_mult, 1.0)
    return np.maximum(1, np.ceil(rng.exponential(mean, size=n))).astype(np.int64)
