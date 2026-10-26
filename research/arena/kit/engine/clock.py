"""The user's local calendar, which the engine's day-of-week and hour-of-day
logic reads (`Calendar.current` in the app): the diurnal rate table, the
activity grid and the weekday/weekend conformal strata.

A fixed UTC offset per account, taken from the account's own turns
(`turns.tz_offset_min`, the offset the app stored with each sample). Every
snapshot so far sits inside one DST period; an account whose offset changes
gets the most recent one.
"""
from __future__ import annotations

import numpy as np
import polars as pl

DAY_S = 86_400.0
HOUR_S = 3_600.0


class LocalClock:
    """Weekday (0 = Sunday, as `Calendar.component(.weekday) - 1`) and hour
    of epoch seconds, at a fixed offset."""

    def __init__(self, offset_s: float = 0.0):
        self.offset_s = float(offset_s)

    def local_day(self, t):
        """Days since 1970-01-01 in local time (int or int array)."""
        return np.floor((np.asarray(t, dtype=np.float64) + self.offset_s) / DAY_S).astype(np.int64)

    def weekday_hour(self, t) -> tuple[np.ndarray, np.ndarray]:
        loc = np.asarray(t, dtype=np.float64) + self.offset_s
        day = np.floor(loc / DAY_S)
        wd = ((day.astype(np.int64) + 4) % 7)          # 1970-01-01 was a Thursday (4)
        hour = np.floor((loc - day * DAY_S) / HOUR_S).astype(np.int64)
        return wd, np.clip(hour, 0, 23)

    def is_weekend(self, t: float) -> bool:
        """`DayRegime.of`: Saturday or Sunday."""
        wd, _ = self.weekday_hour(np.array([t]))
        return int(wd[0]) in (0, 6)

    def __repr__(self) -> str:
        return f"LocalClock({self.offset_s / 60:+.0f} min)"


def offset_minutes(turns: pl.DataFrame, account: str | None = None) -> int | None:
    """The account's latest known UTC offset in minutes (any account's in the
    history when it has none yet); None when no turn carries one."""
    if turns.height == 0 or "tz_offset_min" not in turns.columns:
        return None
    t = turns.filter(pl.col("tz_offset_min").is_not_null())
    if account is not None:
        own = t.filter(pl.col("account") == account)
        if own.height:
            t = own
    if t.height == 0:
        return None
    return int(t.select(pl.col("tz_offset_min").sort_by("t_event").last()).item())


def clock_for(turns: pl.DataFrame, account: str | None = None,
              fallback: LocalClock | None = None) -> LocalClock:
    """The account's clock from the history; `fallback` (else UTC) while no
    turn says. A new account's first moments can hold no turn at all, so a
    caller re-reads this as the history grows rather than fixing it once."""
    m = offset_minutes(turns, account)
    if m is None:
        return fallback or LocalClock(0.0)
    return LocalClock(m * 60.0)
