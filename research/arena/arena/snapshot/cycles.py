"""Meter cycles: which readings belong together, and the cycle in progress as
known at a moment. Shared by the runner (truth, episode eligibility), the
sampler and the kit (models call `current_cycle` on their own history).

The one rule, from Pacer's `RateLimitCycle.contains`: a reading belongs to the
cycle resetting at R when its own reset is within HALF A WINDOW of R. The
server re-serializes `resets_at` on every response and it jitters by
milliseconds, so one 7-day cycle carries thousands of distinct reset instants;
matching with `==` collapses a cycle to a single reading. Consecutive cycles'
resets are at least a full window apart, so half a window is unambiguous.

Everything here takes epoch milliseconds (`Millis`).
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import polars as pl

HOUR_MS = 3_600_000
DAY_MS = 24 * HOUR_MS

# Window lengths. `session` and `weekly_all` report the same meters as the
# five-hour and seven-day windows (linked by dup_group); scoped caps (the
# Fable weekly) are weekly.
WINDOW_MS: dict[str, int] = {
    "five_hour": 5 * HOUR_MS,
    "seven_day": 7 * DAY_MS,
    "session": 5 * HOUR_MS,
    "weekly_all": 7 * DAY_MS,
    "weekly_scoped": 7 * DAY_MS,
}


def window_ms(window_kind: str) -> int:
    try:
        return WINDOW_MS[window_kind]
    except KeyError:
        raise ValueError(f"unknown window kind {window_kind!r}") from None


def same_cycle(sample_reset, reset: int, duration: int):
    """`RateLimitCycle.contains`, scalar or vectorized (numpy). A null sample
    reset is NOT in-cycle here: the snapshot keeps post-reset readings as
    explicit `idle` rows, so a null reset means "no cycle", not "this one"."""
    if sample_reset is None:
        return False
    return np.abs(np.asarray(sample_reset, dtype=np.float64) - float(reset)) < duration / 2


def _ms(col: str) -> pl.Expr:
    return pl.col(col).dt.epoch("ms")


def meter_frame(readings: pl.DataFrame, account: str, window_kind: str,
                scope_model: str | None = None) -> pl.DataFrame:
    """One meter's readings with integer-ms clocks: columns t_event, t_known,
    reset (nullable), util, active; sorted by (t_event, t_known)."""
    f = readings.filter((pl.col("account") == account) & (pl.col("window_kind") == window_kind))
    if scope_model is not None:
        f = f.filter(pl.col("scope_model") == scope_model)
    return f.select(
        _ms("t_event").alias("t_event"),
        _ms("t_known").alias("t_known"),
        _ms("resets_at").alias("reset"),
        pl.col("util_pct").cast(pl.Float64).alias("util"),
        ((pl.col("state") == "active") & pl.col("resets_at").is_not_null()).fill_null(False).alias("active"),
    ).sort(["t_event", "t_known"], maintain_order=True)


@dataclass(frozen=True)
class CycleNow:
    """The cycle in progress at `now`, as known at `now`."""

    account: str
    window_kind: str
    scope_model: str | None
    reset_at: int          # the latest known reading's own reset (no median over later data)
    start: int             # reset_at - window (the nominal start)
    duration: int
    util: float            # latest known reading
    last_t: int            # its t_event


class MeterIndex:
    """As-of lookups over one meter series (account × window × scope model).

    Built once from every loaded reading. `cycle_at(now)` uses only readings
    with t_known <= now; `truth(...)` deliberately uses all of them, because
    truth is built from data the model never sees."""

    def __init__(self, frame: pl.DataFrame, account: str, window_kind: str,
                 scope_model: str | None = None, duration: int | None = None):
        self.account, self.window_kind, self.scope_model = account, window_kind, scope_model
        self.duration = duration or window_ms(window_kind)
        # Event order, for truth.
        self.te = frame["t_event"].to_numpy().astype(np.int64)
        self.tk = frame["t_known"].to_numpy().astype(np.int64)
        self.reset = frame["reset"].fill_null(-1).to_numpy().astype(np.int64)
        self.util = frame["util"].fill_null(np.nan).to_numpy().astype(np.float64)
        self.active = frame["active"].to_numpy().astype(bool)
        # Knowledge order: rows sorted by t_known, with a running "latest by
        # t_event" pointer, so "the newest reading known at now" is one
        # binary search.
        order = np.lexsort((self.te, self.tk))
        self._order = order
        self._k_tk = self.tk[order]
        te_sorted = self.te[order]
        if len(order):
            run = np.maximum.accumulate(te_sorted)
            prev = np.concatenate(([np.iinfo(np.int64).min], run[:-1]))
            is_new = te_sorted >= prev            # ties: the later-known copy wins
            pos = np.maximum.accumulate(np.where(is_new, np.arange(len(order)), 0))
            self._k_latest = order[pos]
        else:
            self._k_latest = order

    @classmethod
    def from_readings(cls, readings: pl.DataFrame, account: str, window_kind: str,
                      scope_model: str | None = None) -> "MeterIndex":
        return cls(meter_frame(readings, account, window_kind, scope_model),
                   account, window_kind, scope_model)

    def __len__(self) -> int:
        return len(self.te)

    def latest_known(self, now: int) -> int | None:
        """Row index (event order) of the newest reading known at `now`."""
        i = int(np.searchsorted(self._k_tk, now, side="right")) - 1
        return None if i < 0 else int(self._k_latest[i])

    def cycle_at(self, now: int) -> CycleNow | None:
        """The cycle in progress at `now` as known at `now`, or None when the
        window is idle (latest known reading idle, or its reset has passed)."""
        i = self.latest_known(now)
        if i is None or not self.active[i] or self.reset[i] <= now or self.te[i] > now:
            return None
        r = int(self.reset[i])
        return CycleNow(self.account, self.window_kind, self.scope_model, r, r - self.duration,
                        self.duration, float(self.util[i]), int(self.te[i]))

    def last_reset_before(self, now: int) -> int | None:
        """The reset of the most recent cycle known at `now` whose reset has
        passed (the start of the idle stretch), or None."""
        n = int(np.searchsorted(self._k_tk, now, side="right"))
        if n == 0:
            return None
        known = np.zeros(len(self.te), dtype=bool)
        known[self._order[:n]] = True
        m = known & self.active & (self.reset <= now)
        return int(self.reset[m].max()) if m.any() else None

    def truth(self, after: int, until: int, reset_at: int) -> tuple[np.ndarray, np.ndarray]:
        """Readings of the cycle resetting at `reset_at` with t_event in
        (after, min(until, reset_at)]: real times, real values, never
        interpolated, never past the reset."""
        end = min(until, reset_at)
        m = (self.active & (self.te > after) & (self.te <= end)
             & (np.abs(self.reset - reset_at) < self.duration / 2) & np.isfinite(self.util))
        return self.te[m].copy(), self.util[m].copy()

    def known_times(self, since: int, until: int) -> np.ndarray:
        """t_known of readings that became known in (since, until]."""
        m = (self.tk > since) & (self.tk <= until)
        return np.unique(self.tk[m])


def segment(readings: pl.DataFrame, duration: int) -> pl.DataFrame:
    """Label each reading of ONE meter (a `meter_frame`) with its cycle:
    adds `cycle` (0, 1, … in reset order; null for idle rows) and
    `cycle_reset` (the median of its members' resets)."""
    act = readings.with_row_index("_i").filter(pl.col("active")).sort("reset")
    if act.height == 0:
        return readings.with_columns(pl.lit(None, pl.Int64).alias("cycle"),
                                     pl.lit(None, pl.Int64).alias("cycle_reset"))
    resets = act["reset"].to_numpy()
    cyc = np.zeros(len(resets), dtype=np.int64)
    anchor, c = resets[0], 0
    for j in range(1, len(resets)):
        if resets[j] - anchor >= duration / 2:
            c += 1
            anchor = resets[j]
        cyc[j] = c
    act = act.with_columns(pl.Series("cycle", cyc))
    med = act.group_by("cycle").agg(pl.col("reset").median().round().cast(pl.Int64).alias("cycle_reset"))
    act = act.join(med, on="cycle").select("_i", "cycle", "cycle_reset")
    return (readings.with_row_index("_i").join(act, on="_i", how="left")
            .sort("_i").drop("_i"))


def current_cycle(readings: pl.DataFrame, now: int, account: str, window_kind: str,
                  scope_model: str | None = None) -> CycleNow | None:
    """The cycle in progress at `now` and its reset, as known at `now`, from a
    `meter_readings` frame (a model's own history, or any as-of slice)."""
    return MeterIndex.from_readings(readings, account, window_kind, scope_model).cycle_at(now)
