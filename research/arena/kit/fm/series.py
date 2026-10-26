"""Series a pretrained forecaster can read, built from a `History` only (rows
known by `history.now`), so nothing here can see the future.

**Meters: cumulative burn.** A meter resets every cycle, which a generic
forecaster reads as a crash. The series it gets instead is the meter's burn
summed across cycles and never reset (issue #271's formulation, the lab's
`common.cumulative`): each reading adds how far it rose from the previous
reading of its cycle, and the first reading of a cycle adds its whole value
(the meter started that cycle at 0). Cycles follow the one rule
(`RateLimitCycle.contains`): a reading belongs to the cycle of the last active
reading when their resets are within half a window. Idle rows (the snapshot
keeps them, util 0) add nothing: burn really was zero then. A meter can FALL
inside a cycle under the same reset (the allowance was re-based: the server
lowered or zeroed it and kept the reset): a fall adds nothing, and burn counts
again from the lower value. There is no running maximum anywhere: the meter
now is the latest reading as read. So the current cycle's readings are the
end of the series and the previous cycles are its context.

**Resampling.** Readings are irregular (polls every 15 s to 5 min, gaps while
the Mac sleeps). `resample_last` puts them on a regular grid ending exactly at
`now`: each grid time takes the last reading at or before it, or NaN when that
reading is older than `stale_ms` (2 h): a gap is unknown, not flat. Models that
cannot take NaN get `fill_gaps`.

**Hourly series.** Spend (USD at the rates known at `now`, `arena.pricing`)
or tokens, per hour aligned to `now`: bin k covers (now-(k+1)h, now-kh], the
same alignment as the hourly targets' grid (now + k h). Calendar covariates
are in the user's local time (the turns' `tz_offset_min`).
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import polars as pl

from arena.pricing import output_tokens, price_turns
from arena.snapshot.cycles import meter_frame, window_ms
from kit.spend import PriceCache  # noqa: F401 - kit/fm's models price through it

MIN_MS = 60_000
HOUR_MS = 3_600_000
DAY_MS = 24 * HOUR_MS
STALE_MS = 2 * HOUR_MS
SYNTHETIC = "<synthetic>"


# ---------------------------------------------------------------------------
# Meters
# ---------------------------------------------------------------------------

@dataclass
class MeterSeries:
    """One meter's readings known at now, in event order."""

    times: np.ndarray        # t_event, int64 ms
    cum: np.ndarray          # cumulative burn after each reading
    cycle_util: np.ndarray   # the reading's util as read (0 when idle)
    reset: np.ndarray        # the reading's reset (int64 ms), -1 when idle
    active: np.ndarray       # bool
    duration: int

    def __len__(self) -> int:
        return len(self.times)

    def cycle_mask(self, reset_at: int) -> np.ndarray:
        return self.active & (np.abs(self.reset - int(reset_at)) < self.duration / 2)

    def used_now(self, reset_at: int) -> float | None:
        """The meter now: the latest reading of the cycle resetting at
        `reset_at`, as read (it can be below an earlier one: a re-base)."""
        m = self.cycle_mask(reset_at)
        return float(self.cycle_util[m][-1]) if m.any() else None

    def last(self) -> tuple[int, float] | None:
        if not len(self.times):
            return None
        return int(self.times[-1]), float(self.cum[-1])


def meter_series(readings: pl.DataFrame, account: str, window_kind: str,
                 scope_model: str | None = None, now: int | None = None) -> MeterSeries:
    f = meter_frame(readings, account, window_kind, scope_model)
    if now is not None:
        f = f.filter(pl.col("t_event") <= now)
    f = f.filter(pl.col("util").is_not_null() & pl.col("util").is_not_nan())
    dur = window_ms(window_kind)
    t = f["t_event"].to_numpy().astype(np.int64)
    r = f["reset"].fill_null(-1).to_numpy().astype(np.int64)
    a = f["active"].to_numpy().astype(bool)
    u = np.where(a, f["util"].to_numpy().astype(np.float64), 0.0)
    n = len(t)
    if n == 0:
        z = np.zeros(0)
        return MeterSeries(t, z, z, r, a, dur)
    # The reset of the latest ACTIVE reading before each row (idle rows in
    # between do not start a new cycle; only a reset half a window away does).
    r_act = np.where(a, r.astype(np.float64), np.nan)
    idx = np.where(a, np.arange(n), -1)
    idx = np.maximum.accumulate(idx)
    prev_idx = np.concatenate(([-1], idx[:-1]))
    prev_r = np.where(prev_idx >= 0, r_act[np.maximum(prev_idx, 0)], np.nan)
    new = a & (np.isnan(prev_r) | (np.abs(r - prev_r) >= dur / 2))
    # A fall inside a cycle is a re-base (seen on a scoped weekly cap: most
    # of it used one day, zero the next, same reset): it adds no burn, and
    # the rise after it counts from the lower value. Never a running max,
    # which would hold the old value to the reset.
    u_prev = np.where(prev_idx >= 0, u[np.maximum(prev_idx, 0)], 0.0)
    inc = np.where(new, u, u - u_prev)
    inc = np.where(a, np.maximum(inc, 0.0), 0.0)
    cum = np.cumsum(inc)
    return MeterSeries(t, cum, np.where(a, u, 0.0), r, a, dur)


def resample_last(times: np.ndarray, values: np.ndarray, grid: np.ndarray,
                  stale_ms: int = STALE_MS) -> np.ndarray:
    """Each grid time takes the last value at or before it; NaN when there is
    none, or it is older than `stale_ms`."""
    grid = np.asarray(grid, dtype=np.int64)
    out = np.full(len(grid), np.nan)
    if not len(times):
        return out
    i = np.searchsorted(times, grid, side="right") - 1
    ok = i >= 0
    ok[ok] &= (grid[ok] - times[i[ok]]) <= stale_ms
    out[ok] = values[i[ok]]
    return out


def regular_grid(now: int, step_ms: int, n: int) -> np.ndarray:
    """n times ending exactly at now, `step_ms` apart (oldest first)."""
    return int(now) - int(step_ms) * np.arange(n - 1, -1, -1, dtype=np.int64)


def fill_gaps(x: np.ndarray) -> np.ndarray:
    """For models that cannot take NaN: inner gaps linear, leading gaps take
    the first value, trailing gaps the last (along the last axis). An all-NaN
    row becomes 0."""
    out = np.array(x, dtype=np.float64, copy=True)
    flat = out.reshape(-1, out.shape[-1])
    idx = np.arange(flat.shape[-1])
    for row in flat:
        ok = np.isfinite(row)
        if ok.all():
            continue
        if not ok.any():
            row[:] = 0.0
            continue
        row[:] = np.interp(idx, idx[ok], row[ok])
    return out


# ---------------------------------------------------------------------------
# Hourly spend and tokens
# ---------------------------------------------------------------------------

def hour_bins(t_ms: np.ndarray, now: int, hours: int) -> np.ndarray:
    """Bin index (0 = oldest) of each time among the `hours` hours ending at
    now, or -1 outside. Bin k from the end covers (now-(k+1)h, now-kh]."""
    back = (int(now) - np.asarray(t_ms, dtype=np.int64)) // HOUR_MS
    ok = (np.asarray(t_ms) <= now) & (back < hours) & (back >= 0)
    return np.where(ok, hours - 1 - back, -1)


def bin_sum(t_ms: np.ndarray, v: np.ndarray, now: int, hours: int) -> np.ndarray:
    b = hour_bins(t_ms, now, hours)
    keep = b >= 0
    return np.bincount(b[keep], weights=np.nan_to_num(v[keep]), minlength=hours)[:hours].astype(np.float64)


class TurnFrame:
    """A model's recent turns, priced at the rates known at `now`: what every
    hourly series and covariate of one forecast reads. An unpriced turn
    counts 0 here (the hour's truth is NaN instead)."""

    def __init__(self, history, hours: int, accounts=None, cache: PriceCache | None = None):
        self.now = int(history.now)
        self.hours = int(hours)
        since = self.now - self.hours * HOUR_MS
        t = history.table("turns")
        t = t.filter((pl.col("model") != SYNTHETIC)
                     & (pl.col("t_event").dt.epoch("ms") > since)
                     & (pl.col("t_event").dt.epoch("ms") <= self.now))
        if accounts is not None:
            t = t.filter(pl.col("account").is_in(list(accounts)))
        if t.height:
            t = (cache or PriceCache()).price(t, history)
            t = t.with_columns(
                (pl.col("input").cast(pl.Float64) + output_tokens(t, "best").fill_null(0)
                 + pl.col("cache_read") + pl.col("cache_write_5m") + pl.col("cache_write_1h")).alias("_tokens"))
        self.t_ms = t["t_event"].dt.epoch("ms").to_numpy().astype(np.int64) if t.height else np.zeros(0, np.int64)
        self.account = np.array(t["account"].to_list(), dtype=object) if t.height else np.zeros(0, dtype=object)
        self.family = (np.array(t["model_family"].fill_null("other").to_list(), dtype=object)
                       if t.height else np.zeros(0, dtype=object))
        self.cost = (t["cost_usd"].fill_null(0.0).to_numpy().astype(np.float64) if t.height else np.zeros(0))
        self.tokens = (t["_tokens"].fill_null(0.0).to_numpy().astype(np.float64) if t.height else np.zeros(0))
        self.session = (t["session_h"].fill_null(0).to_numpy().astype(np.uint64) if t.height
                        else np.zeros(0, np.uint64))
        tz = t["tz_offset_min"].drop_nulls() if t.height else None
        self.tz_offset_min = int(tz[-1]) if tz is not None and len(tz) else 0

    def mask(self, accounts, family: str | None = None) -> np.ndarray:
        m = np.isin(self.account, list(accounts))
        if family is not None:
            m &= self.family == family
        return m

    def hourly(self, accounts, what: str = "spend", family: str | None = None, hours: int | None = None) -> np.ndarray:
        """[hours] oldest first, ending at now."""
        h = hours or self.hours
        m = self.mask(accounts, family)
        v = self.cost if what == "spend" else self.tokens
        return bin_sum(self.t_ms[m], v[m], self.now, h)

    def families(self, accounts) -> list[str]:
        m = self.mask(accounts)
        return sorted(set(self.family[m].tolist()))

    def sessions_per_hour(self, accounts, hours: int | None = None) -> np.ndarray:
        """Distinct sessions with a turn in each hour."""
        h = hours or self.hours
        m = self.mask(accounts)
        b = hour_bins(self.t_ms[m], self.now, h)
        s = self.session[m]
        keep = b >= 0
        if not keep.any():
            return np.zeros(h)
        pairs = np.unique(np.stack([b[keep].astype(np.uint64), s[keep]], axis=1), axis=0)
        return np.bincount(pairs[:, 0].astype(np.int64), minlength=h)[:h].astype(np.float64)

    def session_set(self, accounts) -> np.ndarray:
        return np.unique(self.session[self.mask(accounts)])


def prompts_per_hour(history, sessions: np.ndarray, now: int, hours: int) -> np.ndarray:
    """Prompts (human turns and the like, timestamps only) per hour, in the
    given sessions."""
    p = history.table("prompts")
    if not p.height or not len(sessions):
        return np.zeros(hours)
    since = int(now) - hours * HOUR_MS
    p = p.filter((pl.col("t_event").dt.epoch("ms") > since) & (pl.col("t_event").dt.epoch("ms") <= now)
                 & pl.col("session_h").is_in(pl.Series(sessions.astype(np.uint64)).implode()))
    if not p.height:
        return np.zeros(hours)
    t = p["t_event"].dt.epoch("ms").to_numpy().astype(np.int64)
    return bin_sum(t, np.ones(len(t)), now, hours)


def meter_level_hourly(history, accounts, window_kind: str, now: int, hours: int) -> np.ndarray:
    """The meter at each hour's end (max over the accounts), NaN where no
    reading in the 2 h before; idle counts 0."""
    r = history.table("meter_readings")
    r = r.filter(pl.col("t_event").dt.epoch("ms") > int(now) - (hours + 3) * HOUR_MS)
    ends = int(now) - HOUR_MS * np.arange(hours - 1, -1, -1, dtype=np.int64)
    out = np.full(hours, np.nan)
    for a in accounts:
        f = meter_frame(r, a, window_kind)
        if not f.height:
            continue
        t = f["t_event"].to_numpy().astype(np.int64)
        u = np.where(f["active"].to_numpy(), f["util"].fill_null(0.0).to_numpy(), 0.0)
        v = resample_last(t, u, ends)
        out = np.where(np.isnan(out), v, np.where(np.isnan(v), out, np.maximum(out, v)))
    return out


def calendar(ends_ms: np.ndarray, tz_offset_min: int) -> np.ndarray:
    """[4, n]: hour-of-day and day-of-week as sin/cos, local time, at the
    middle of each hour ending at `ends_ms`."""
    mid = (np.asarray(ends_ms, dtype=np.int64) - HOUR_MS // 2 + tz_offset_min * MIN_MS)
    hod = (mid % DAY_MS) / DAY_MS
    dow = ((mid // DAY_MS + 3) % 7 + hod) / 7.0          # 1970-01-01 was a Thursday: Monday = 0
    return np.stack([np.sin(2 * np.pi * hod), np.cos(2 * np.pi * hod),
                     np.sin(2 * np.pi * dow), np.cos(2 * np.pi * dow)])
