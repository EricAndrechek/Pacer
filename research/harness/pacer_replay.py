"""Replay Pacer's rate-limit prediction pipeline over the real store, walk-forward.

Faithful Python ports of the Swift engine's pieces (BurnTrajectory models,
DiurnalBurnModel, stratified additive conformal, method selection with shadow
floors), driven by the same raw RateLimitSample rows the app reads. Every
prediction is made using only data that existed at prediction time, then
scored against the realized cycle:

- absolute error of the end-at-reset point (percentage points)
- 80% interval coverage (should be ~0.80 if the bands are honest)
- pinball loss at q10/q90 (the band's quantile quality)
- Brier score for "hits the limit before reset"

Usage:
    uv run pacer_replay.py                 # replay both windows, current params
    uv run pacer_replay.py --window seven_day
    uv run pacer_replay.py --store /path/to/pacer.sqlite

The store is copied to a temp dir first and opened read-only — the live app
is never touched.
"""

from __future__ import annotations

import argparse
import json
import math
import shutil
import sqlite3
import tempfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

CORE_DATA_EPOCH = 978307200.0  # 2001-01-01 → unix offset
GROUP_DIR = Path.home() / "Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer"

WINDOW_SECONDS = {"five_hour": 5 * 3600.0, "seven_day": 7 * 24 * 3600.0}

# Segmentation thresholds (BurnTrajectory.resetDropPoints / resetLowMax).
RESET_DROP_POINTS = 15.0
RESET_LOW_MAX = 5.0

# Scoring cuts (EngineSelfEval.rlCutFractions).
RL_CUT_FRACTIONS = [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]


# ---------------------------------------------------------------------------
# Parameters (mirror EngineParams — canonical string must match Swift)
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Params:
    conformal_min_residuals: int = 8
    rl_stratum_min_scores: int = 10
    pool_tolerance: float = 1.25
    pool_min_periods: int = 10
    pool_recency_window: int = 30
    linear_recent_lookback_fraction: float = 0.3
    recency_half_life_fraction: float = 0.15
    shadow_promotion_min_periods: int = 15

    def canonical(self) -> str:
        def g(v: float) -> str:
            return f"{v:g}"

        return ";".join([
            f"conformalMinResiduals={self.conformal_min_residuals}",
            f"rlStratumMinScores={self.rl_stratum_min_scores}",
            f"poolTolerance={g(self.pool_tolerance)}",
            f"poolMinPeriods={self.pool_min_periods}",
            f"poolRecencyWindow={self.pool_recency_window}",
            f"linearRecentLookbackFraction={g(self.linear_recent_lookback_fraction)}",
            f"recencyHalfLifeFraction={g(self.recency_half_life_fraction)}",
            f"shadowPromotionMinPeriods={self.shadow_promotion_min_periods}",
        ])

    def version_tag(self) -> str:
        h = 0xCBF29CE484222325
        for b in self.canonical().encode():
            h ^= b
            h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
        return "v1-" + format(h & 0xFFFFFFFF, "08x")


# ---------------------------------------------------------------------------
# Store access (read-only copy)
# ---------------------------------------------------------------------------

def locate_store(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit).expanduser()
    hits = sorted(GROUP_DIR.rglob("pacer.sqlite"))
    if not hits:
        raise SystemExit(f"no pacer.sqlite under {GROUP_DIR} — pass --store")
    return hits[0]


def open_copy(store: Path) -> sqlite3.Connection:
    tmp = Path(tempfile.mkdtemp(prefix="pacer-harness-"))
    for suffix in ("", "-wal", "-shm"):
        src = Path(str(store) + suffix)
        if src.exists():
            shutil.copy2(src, tmp / src.name)
    conn = sqlite3.connect(f"file:{tmp / store.name}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def _cols(conn: sqlite3.Connection, table: str) -> set[str]:
    return {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}


def load_rate_samples(conn: sqlite3.Connection, window: str) -> list[tuple[float, float, float]]:
    """(at_unix, used_pct, resets_unix) sorted by time, resets non-null only."""
    cols = _cols(conn, "ZRATELIMITSAMPLE")
    need = {"ZSAMPLEDAT", "ZUSEDPERCENTAGE", "ZWINDOW", "ZRESETSAT"}
    if not need <= cols:
        raise SystemExit(f"ZRATELIMITSAMPLE columns {sorted(cols)} missing {sorted(need - cols)}")
    rows = conn.execute(
        "SELECT ZSAMPLEDAT, ZUSEDPERCENTAGE, ZRESETSAT FROM ZRATELIMITSAMPLE "
        "WHERE ZWINDOW = ? AND ZRESETSAT IS NOT NULL ORDER BY ZSAMPLEDAT",
        (window,),
    ).fetchall()
    return [(r[0] + CORE_DATA_EPOCH, float(r[1]), r[2] + CORE_DATA_EPOCH) for r in rows]


def load_activity_grid(conn: sqlite3.Connection) -> list[list[float]]:
    """P(active)[weekday 0=Sun..6=Sat][hour] from hourly aggregates — the
    diurnal prior. Idle days count in the denominator (gaps are real zeros).
    A missing/renamed table degrades to a uniform (absent) prior."""
    try:
        rows = conn.execute(
            "SELECT ZDATE, ZHOUR, SUM(ZTOTALCOSTUSD) FROM ZHOURLYAGGREGATE GROUP BY ZDATE, ZHOUR"
        ).fetchall()
    except sqlite3.OperationalError:
        return [[0.0] * 24 for _ in range(7)]
    active: dict[str, set[int]] = {}
    for date_key, hour, cost in rows:
        if cost and cost > 0:
            active.setdefault(date_key, set()).add(int(hour))
    if not active:
        return [[0.0] * 24 for _ in range(7)]
    days = sorted(active)
    first = datetime.strptime(days[0], "%Y-%m-%d").date()
    last = datetime.strptime(days[-1], "%Y-%m-%d").date()
    num = [[0.0] * 24 for _ in range(7)]
    den = [0.0] * 7
    day = first
    from datetime import timedelta
    while day <= last:
        wd = (day.weekday() + 1) % 7  # python Mon=0 → gregorian Sun=0
        den[wd] += 1
        for h in active.get(day.strftime("%Y-%m-%d"), ()):
            num[wd][h] += 1
        day += timedelta(days=1)
    return [[(num[wd][h] / den[wd]) if den[wd] > 0 else 0.0 for h in range(24)] for wd in range(7)]


# ---------------------------------------------------------------------------
# Cycle segmentation (port of BurnTrajectory.segment)
# ---------------------------------------------------------------------------

@dataclass
class Cycle:
    samples: list[tuple[float, float]]  # (at_unix, used_pct)
    cycle_start: float
    resets_at: float

    @property
    def final(self) -> float:
        return max(p for _, p in self.samples)

    @property
    def duration(self) -> float:
        return self.resets_at - self.cycle_start


def _post_reset_start(rows: list[tuple[float, float, float]]) -> int:
    split = 0
    for i in range(1, len(rows)):
        if rows[i - 1][1] - rows[i][1] >= RESET_DROP_POINTS and rows[i][1] <= RESET_LOW_MAX:
            split = i
    return split


def segment(samples: list[tuple[float, float, float]], duration: float) -> list[Cycle]:
    """All cycles (completed = all but the one with the max reset key)."""
    groups: dict[float, list[tuple[float, float, float]]] = {}
    for s in samples:
        key = round(s[2] / 60.0) * 60.0
        groups.setdefault(key, []).append(s)
    cycles: list[Cycle] = []
    for key, rows in groups.items():
        rows = sorted(rows)
        split = _post_reset_start(rows)
        kept = rows[split:]
        if not kept:
            continue
        reset = max(r[2] for r in kept)
        start = rows[split - 1][0] if split > 0 else reset - duration
        cycles.append(Cycle([(r[0], r[1]) for r in kept], start, reset))
    return sorted(cycles, key=lambda c: c.cycle_start)


# ---------------------------------------------------------------------------
# Model ports (BurnTrajectoryModels + DiurnalBurnModel)
# ---------------------------------------------------------------------------

@dataclass
class Partial:
    samples: list[tuple[float, float]]
    now: float
    cycle_start: float
    resets_at: float

    def hours(self, at: float) -> float:
        return (at - self.cycle_start) / 3600.0

    @property
    def duration_hours(self) -> float:
        return (self.resets_at - self.cycle_start) / 3600.0

    @property
    def used_now(self) -> float:
        return self.samples[-1][1] if self.samples else 0.0


def _ls_line(pts: list[tuple[float, float]]):
    n = float(len(pts))
    sx = sum(p[0] for p in pts)
    sy = sum(p[1] for p in pts)
    sxx = sum(p[0] * p[0] for p in pts)
    sxy = sum(p[0] * p[1] for p in pts)
    det = n * sxx - sx * sx
    if abs(det) <= 1e-9:
        return None
    return (n * sxy - sx * sy) / det, (sy * sxx - sx * sxy) / det


def linear_recent(c: Partial, params: Params):
    cutoff = c.hours(c.now) - c.duration_hours * params.linear_recent_lookback_fraction
    pts = [(c.hours(a), p) for a, p in c.samples if c.hours(a) >= cutoff]
    used = pts if len(pts) >= 2 else [(c.hours(a), p) for a, p in c.samples]
    if len(used) < 2:
        return None
    line = _ls_line(used)
    if line is None:
        return None
    slope, intercept = line
    return lambda t: slope * ((t - c.cycle_start) / 3600.0) + intercept


def _trend_fit(c: Partial, params: Params, *, min_samples: int, damping_tau_s: float,
               max_accel_frac: float):
    """TrendEstimator.fit port (weighted LS in half-life units)."""
    half_life_h = c.duration_hours * params.recency_half_life_fraction
    if half_life_h <= 0:
        return None
    min_span = max(300.0, c.duration_hours * 3600.0 * 0.05)
    recent = sorted((a, v) for a, v in c.samples if a <= c.now)
    if len(recent) < min_samples or recent[-1][0] - recent[0][0] < min_span:
        return None
    rows = []
    for a, v in recent:
        u = ((a - c.now) / 3600.0) / half_life_h
        rows.append((u, v, 2.0 ** u))
    s0 = s1 = s2 = s3 = s4 = t0 = t1 = t2 = 0.0
    for u, v, w in rows:
        u2 = u * u
        s0 += w; s1 += w * u; s2 += w * u2; s3 += w * u2 * u; s4 += w * u2 * u2
        t0 += w * v; t1 += w * v * u; t2 += w * v * u2
    det = s0 * s2 - s1 * s1
    if abs(det) <= 1e-12:
        return None
    a_lin = (t0 * s2 - t1 * s1) / det
    b_lin = (s0 * t1 - s1 * t0) / det
    level, slope_ph = a_lin, b_lin / half_life_h
    accel = 0.0
    if len({u for u, _, _ in rows}) >= 3:
        # Cramer's rule for the quadratic normal equations; c is the third
        # unknown, so its numerator replaces the third column with t.
        d = (s0 * (s2 * s4 - s3 * s3) - s1 * (s1 * s4 - s3 * s2) + s2 * (s1 * s3 - s2 * s2))
        if abs(d) > 1e-12:
            cq = (s0 * (s2 * t2 - t1 * s3) - s1 * (s1 * t2 - t1 * s2) + t0 * (s1 * s3 - s2 * s2))
            accel = 2 * (cq / d) / (half_life_h * half_life_h)
    tau_h = damping_tau_s / 3600.0
    max_boost = max_accel_frac * abs(slope_ph)
    if tau_h > 0 and math.isfinite(max_boost):
        cap = max_boost / tau_h
        accel_e = max(-cap, min(cap, accel))
    else:
        accel_e = 0.0 if tau_h <= 0 else accel
    now = c.now

    def project(t: float) -> float:
        h = (t - now) / 3600.0
        linear = level + slope_ph * h
        if tau_h <= 0 or accel_e == 0:
            return linear
        return linear + accel_e * tau_h * (h - tau_h * (1 - math.exp(-h / tau_h)))

    return project


def recency_weighted(c: Partial, params: Params):
    return _trend_fit(c, params, min_samples=3, damping_tau_s=3600.0, max_accel_frac=0.0)


def damped_acceleration(c: Partial, params: Params):
    remaining = max(3600.0, c.resets_at - c.now)
    return _trend_fit(c, params, min_samples=4, damping_tau_s=remaining, max_accel_frac=1.0)


def saturating(c: Partial, params: Params):
    s = [c.hours(a) for a, _ in c.samples]
    y = [p for _, p in c.samples]
    if len(s) < 3 or max(y) <= 0:
        return None
    y_max = max(y)
    best = None
    ceiling = 1.05
    while ceiling <= 2.5:
        big_l = max(y_max * ceiling, y_max + 1)
        sk = ss = 0.0
        for si, yi in zip(s, y):
            if 0 < yi < big_l * 0.999:
                z = -math.log(1 - yi / big_l)
                sk += si * z
                ss += si * si
        if ss > 1e-9:
            k = sk / ss
            if k > 0:
                sse = sum((big_l * (1 - math.exp(-k * si)) - yi) ** 2 for si, yi in zip(s, y))
                if best is None or sse < best[0]:
                    best = (sse, big_l, k)
        ceiling += 0.05
    if best is None:
        return None
    _, big_l, k = best
    start = c.cycle_start
    return lambda t: big_l * (1 - math.exp(-k * ((t - start) / 3600.0)))


def kalman_trend(c: Partial, params: Params):
    samples = c.samples
    if len(samples) < 3:
        return None
    q, r = 0.5 ** 2, 0.5 ** 2
    level, slope = samples[0][1], 0.0
    p00, p01, p11 = 25.0, 0.0, 25.0
    last_t = c.hours(samples[0][0])
    for a, v in samples[1:]:
        t = c.hours(a)
        dt = max(1e-3, t - last_t)
        last_t = t
        level += slope * dt
        np00 = p00 + 2 * dt * p01 + dt * dt * p11 + q * dt ** 3 / 3
        np01 = p01 + dt * p11 + q * dt * dt / 2
        np11 = p11 + q * dt
        innov = v - level
        denom = np00 + r
        if denom <= 1e-12:
            return None
        k0, k1 = np00 / denom, np01 / denom
        level += k0 * innov
        slope += k1 * innov
        p00, p01, p11 = (1 - k0) * np00, (1 - k0) * np01, np11 - k1 * np01
    if not (math.isfinite(level) and math.isfinite(slope)):
        return None
    anchor_h, start = last_t, c.cycle_start
    return lambda t: level + slope * ((t - start) / 3600.0 - anchor_h)


def diurnal_rate_table(cycles: list[Cycle], prior: list[list[float]] | None,
                       pseudocount: float = 6.0) -> list[list[float]]:
    sums = [[0.0] * 24 for _ in range(7)]
    cnt = [[0.0] * 24 for _ in range(7)]
    for cyc in cycles:
        s = sorted(cyc.samples)
        for i in range(1, len(s)):
            dt = s[i][0] - s[i - 1][0]
            if dt <= 0:
                continue
            rate = max(0.0, s[i][1] - s[i - 1][1]) / dt
            mid = datetime.fromtimestamp(s[i - 1][0] + dt / 2)
            wd = (mid.weekday() + 1) % 7
            sums[wd][mid.hour] += rate
            cnt[wd][mid.hour] += 1
    obs = [[0.0] * 24 for _ in range(7)]
    populated = []
    for wd in range(7):
        for h in range(24):
            if cnt[wd][h] > 0:
                obs[wd][h] = sums[wd][h] / cnt[wd][h]
                populated.append(obs[wd][h])
    mean = sum(populated) / len(populated) if populated else 0.0
    if mean > 0:
        obs = [[v / mean for v in row] for row in obs]
    if prior and len(prior) == 7 and all(len(r) == 24 for r in prior):
        flat = [v for row in prior for v in row]
        pm = sum(flat) / len(flat)
        pri = [[v / pm for v in row] for row in prior] if pm > 0 else [[1.0] * 24 for _ in range(7)]
    else:
        pri = [[1.0] * 24 for _ in range(7)]
    table = [[0.0] * 24 for _ in range(7)]
    for wd in range(7):
        for h in range(24):
            n = cnt[wd][h]
            w = n / (n + pseudocount)
            table[wd][h] = w * (obs[wd][h] if n > 0 else 0.0) + (1 - w) * pri[wd][h]
    return table


def diurnal_integrate(table: list[list[float]], a: float, b: float, step: float = 600.0) -> float:
    if b <= a or step <= 0:
        return 0.0
    total, t = 0.0, a
    while t < b:
        dt = min(step, b - t)
        mid = datetime.fromtimestamp(t + dt / 2)
        wd = (mid.weekday() + 1) % 7
        total += table[wd][mid.hour] * dt
        t += step
    return total


def diurnal_fit(table: list[list[float]]):
    def fit(c: Partial, params: Params):
        used = c.used_now
        if used <= 0:
            return None
        observed = diurnal_integrate(table, c.cycle_start, c.now)
        if observed <= 0:
            return None
        level = used / observed
        origin, base = c.now, used
        return lambda t: base + (level * diurnal_integrate(table, origin, t) if t > origin else 0.0)
    return fit


MODEL_COMPLEXITY = {
    "linear-recent": 1, "recency-weighted": 2, "saturating": 3,
    "damped-acceleration": 4, "kalman-trend": 5, "diurnal-rate": 3,
}
SHADOW_IDS = {"five_hour": {"kalman-trend", "diurnal-rate"}, "seven_day": {"kalman-trend"}}


def model_roster(diurnal_table):
    return {
        "linear-recent": linear_recent,
        "recency-weighted": recency_weighted,
        "damped-acceleration": damped_acceleration,
        "saturating": saturating,
        "kalman-trend": kalman_trend,
        "diurnal-rate": diurnal_fit(diurnal_table),
    }


# ---------------------------------------------------------------------------
# Conformal (stratified additive) + selection
# ---------------------------------------------------------------------------

def stratum_key(cut_fraction: float, cycle_start: float) -> str:
    phase = "early" if cut_fraction < 0.5 else "late"
    wd = datetime.fromtimestamp(cycle_start).weekday()  # Mon=0
    regime = "weekend" if wd >= 5 else "weekday"
    return f"{phase}|{regime}"


def gated_quantile(residuals: list[float], p: float, min_residuals: int) -> float | None:
    n = len(residuals)
    if n < min_residuals:
        return None
    rank = math.ceil((n + 1) * p)
    return sorted(residuals)[min(max(rank, 1), n) - 1]


def collect_residuals(model_fit, params: Params, history: list[Cycle]) -> dict[str, list[float]]:
    """Walk-forward residuals (truth_final − projection at reset), stratified,
    with the pooled fallback — port of stratifiedRLCalibrators."""
    by: dict[str, list[float]] = {"pooled": []}
    for cyc in history:
        true_final = cyc.final
        if true_final <= 0:
            continue
        for cf in RL_CUT_FRACTIONS:
            cut_now = cyc.cycle_start + cyc.duration * cf
            seen = [s for s in cyc.samples if s[0] <= cut_now]
            if len(seen) < 3:
                continue
            partial = Partial(seen, cut_now, cyc.cycle_start, cyc.resets_at)
            proj = model_fit(partial, params)
            if proj is None:
                continue
            residual = true_final - proj(cyc.resets_at)
            by["pooled"].append(residual)
            by.setdefault(stratum_key(cf, cyc.cycle_start), []).append(residual)
    return {k: v for k, v in by.items() if k == "pooled" or len(v) >= params.rl_stratum_min_scores}


def best_method(record: dict[str, dict[str, list[float]]], window: str, params: Params) -> str | None:
    """Port of EngineSelfEval.bestMethod: lowest median |err|, ties within
    1.5pp to the simpler model, shadow floors applied."""
    scored = []
    for mid, per_period in record.items():
        floor = params.shadow_promotion_min_periods if mid in SHADOW_IDS[window] else 2
        if len(per_period) < floor:
            continue
        errs = [e for es in per_period.values() for e in es]
        errs.sort()
        n = len(errs)
        med = errs[n // 2] if n % 2 else (errs[n // 2 - 1] + errs[n // 2]) / 2
        scored.append((mid, med, MODEL_COMPLEXITY.get(mid, 3)))
    if not scored:
        return None
    best = min(scored, key=lambda x: x[1])
    near = [x for x in scored if x[1] <= best[1] + 1.5]
    return min(near, key=lambda x: (x[2], x[1]))[0]


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------

def pinball(truth: float, pred: float, q: float) -> float:
    d = truth - pred
    return q * d if d >= 0 else (q - 1) * d


@dataclass
class CaseScore:
    cycle_index: int
    cut: float
    method: str
    abs_error: float
    covered80: bool | None       # None when no band was stated
    pinball_q10: float | None
    pinball_q90: float | None
    brier: float
    truth_hit: bool
    band_stated: bool


def replay_window(window: str, samples, activity_grid, params: Params) -> list[CaseScore]:
    duration = WINDOW_SECONDS[window]
    cycles = segment(samples, duration)
    completed = cycles[:-1] if cycles else []   # last group = current/live
    scores: list[CaseScore] = []
    # record[m][period_key] = [abs errors] — accumulated walk-forward.
    record: dict[str, dict[str, list[float]]] = {}

    for i, cyc in enumerate(completed):
        history = completed[:i]
        table = diurnal_rate_table(history, activity_grid)
        roster = model_roster(table)
        truth = cyc.final
        if truth <= 0:
            continue
        truth_hit = truth >= 99.5

        # Selection and the calibrator depend only on the record/history, not
        # the cut — resolve once per cycle (the walk over cuts is the hot loop).
        chosen = best_method(record, window, params) or (
            "diurnal-rate" if window == "seven_day" else "recency-weighted")
        residuals = collect_residuals(roster[chosen], params, history)

        for cf in RL_CUT_FRACTIONS:
            cut_now = cyc.cycle_start + cyc.duration * cf
            seen = [s for s in cyc.samples if s[0] <= cut_now]
            if len(seen) < 3:
                continue
            partial = Partial(seen, cut_now, cyc.cycle_start, cyc.resets_at)
            proj = roster[chosen](partial, params)
            if proj is None:
                continue
            anchor = max(0.0, partial.used_now - proj(cut_now))
            raw = proj(cyc.resets_at) + anchor
            point = min(100.0, max(partial.used_now, raw))

            strat = residuals.get(stratum_key(cf, cyc.cycle_start), residuals.get("pooled", []))
            lo = gated_quantile(strat, 0.1, params.conformal_min_residuals)
            hi = gated_quantile(strat, 0.9, params.conformal_min_residuals)
            band_stated = lo is not None and hi is not None
            covered = (min(raw + lo, raw + hi) <= truth <= max(raw + lo, raw + hi)) if band_stated else None
            pb10 = pinball(truth, raw + lo, 0.1) if band_stated else None
            pb90 = pinball(truth, raw + hi, 0.9) if band_stated else None
            # Hit probability: empirical share of residual-shifted outcomes ≥100
            # (conformal predictive), falling back to the deterministic call.
            if len(strat) >= params.conformal_min_residuals:
                p_hit = sum(1 for r in strat if raw + r >= 100.0) / len(strat)
            else:
                p_hit = 1.0 if point >= 100.0 else 0.0
            scores.append(CaseScore(i, cf, chosen, abs(point - truth), covered,
                                    pb10, pb90, (p_hit - (1.0 if truth_hit else 0.0)) ** 2,
                                    truth_hit, band_stated))

        # After the cycle completes, extend every model's record (walk-forward).
        period_key = str(round(cyc.resets_at / 60) * 60)
        for mid, fit in roster.items():
            for cf in RL_CUT_FRACTIONS:
                cut_now = cyc.cycle_start + cyc.duration * cf
                seen = [s for s in cyc.samples if s[0] <= cut_now]
                if len(seen) < 3:
                    continue
                proj = fit(Partial(seen, cut_now, cyc.cycle_start, cyc.resets_at), params)
                if proj is None:
                    continue
                record.setdefault(mid, {}).setdefault(period_key, []).append(
                    abs(proj(cyc.resets_at) - truth))
    return scores


def summarize(scores: list[CaseScore]) -> dict:
    if not scores:
        return {"cases": 0}
    errs = sorted(s.abs_error for s in scores)
    n = len(errs)
    banded = [s for s in scores if s.covered80 is not None]
    out = {
        "cases": n,
        "medianAbsErrorPP": round(errs[n // 2] if n % 2 else (errs[n // 2 - 1] + errs[n // 2]) / 2, 2),
        "meanAbsErrorPP": round(sum(errs) / n, 2),
        "coverage80": round(sum(1 for s in banded if s.covered80) / len(banded), 3) if banded else None,
        "bandStatedShare": round(len(banded) / n, 3),
        "meanPinball": round(sum((s.pinball_q10 + s.pinball_q90) / 2 for s in banded) / len(banded), 3) if banded else None,
        "brier": round(sum(s.brier for s in scores) / n, 4),
        "capHitBaseRate": round(sum(1 for s in scores if s.truth_hit) / n, 3),
        "methodShare": {},
    }
    for s in scores:
        out["methodShare"][s.method] = out["methodShare"].get(s.method, 0) + 1
    out["methodShare"] = {k: round(v / n, 3) for k, v in
                          sorted(out["methodShare"].items(), key=lambda kv: -kv[1])}
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--store", help="path to pacer.sqlite (default: app group)")
    ap.add_argument("--window", choices=["five_hour", "seven_day"], help="one window only")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    conn = open_copy(locate_store(args.store))
    grid = load_activity_grid(conn)
    params = Params()
    report = {"paramsVersion": params.version_tag(), "params": params.canonical(), "windows": {}}
    for window in ([args.window] if args.window else ["five_hour", "seven_day"]):
        samples = load_rate_samples(conn, window)
        scores = replay_window(window, samples, grid, params)
        report["windows"][window] = summarize(scores)
    if args.json:
        print(json.dumps(report, indent=2))
        return
    print(f"params {report['paramsVersion']}  ({report['params']})\n")
    for window, s in report["windows"].items():
        print(f"[{window}]  cases={s.get('cases', 0)}")
        for k, v in s.items():
            if k != "cases":
                print(f"  {k:>20}: {v}")
        print()


if __name__ == "__main__":
    main()
