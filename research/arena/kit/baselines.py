"""Naive baselines, so every board has a floor: the rules themselves, as
functions of a `History` and a `TargetRequest`, shared by `models/naive-*`.

Each returns a `TargetForecast`. They are point forecasts (one path) unless
the rule itself gives an ensemble (the hour-of-week profile's past weeks):
a floor should be the rule and nothing more, and a point forecast's CRPS is
its absolute error, so they score honestly on calibration (badly).

- `meter_flat`          persistence: the latest reading of the cycle, to reset
- `meter_linear`        the cycle's average pace so far, extended to reset
- `next_start_never`    persistence of an idle window: no start before the horizon
- `hourly_flat`         the last hour's spend or tokens, flat
- `hourly_seasonal`     the same hour one period (a day, a week) earlier
- `hourly_profile`      the mean of the same local hour of the week over history
- `split_recent`        each account's share of the group's recent spend, flat

Everything uses only the history (rows known by now), through `kit.spend`.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import polars as pl

from arena.snapshot.cycles import window_ms
from arena.types import History, Target, TargetForecast, TargetRequest
from kit import spend

HOUR_MS = spend.HOUR_MS
DAY_MS = spend.DAY_MS
WEEK_MS = 7 * DAY_MS

WINDOW_OF = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day", Target.METER_SCOPED: "weekly_scoped"}


# ---------------------------------------------------------------------------
# Meters
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class MeterNow:
    """One meter's cycle as known at now."""

    window_kind: str
    scope_model: str | None
    start: int               # nominal start: reset - window
    reset: int
    t: np.ndarray            # this cycle's readings (t_event ms, ascending)
    util: np.ndarray

    @property
    def latest(self) -> float:
        return float(self.util[-1]) if len(self.util) else 0.0

    @property
    def latest_t(self) -> int:
        return int(self.t[-1]) if len(self.t) else self.start


def meter_now(history: History, tr: TargetRequest) -> MeterNow:
    """The request's meter as known at now. The cycle comes from
    `kit.spend.current_cycle`; when that finds none (the history was cut
    after the cycle's readings, say) the request's own reset stands, with
    no readings (0 %)."""
    kind = WINDOW_OF[tr.target]
    cap = tr.cap if tr.target is Target.METER_SCOPED else None
    c = spend.current_cycle(history, tr.accounts[0], kind, cap)
    if c is not None:
        start, reset, rows = c
        t = rows["t_event"].dt.epoch("ms").to_numpy().astype(np.int64)
        # As read, never a running maximum: a meter can fall within its
        # cycle under the same resets_at (an allowance reset mid-cycle can
        # take it from full to near zero), and what it reads now is what
        # persists.
        u = rows["util_pct"].to_numpy().astype(np.float64)
        return MeterNow(kind, cap, start, reset, t, u)
    reset = int(tr.reset_at) if tr.reset_at is not None else int(tr.grid[-1])
    return MeterNow(kind, cap, reset - window_ms(kind), reset, np.zeros(0, np.int64), np.zeros(0))


def meter_flat(history: History, tr: TargetRequest) -> TargetForecast:
    """Persistence: the latest reading, flat to reset."""
    m = meter_now(history, tr)
    return TargetForecast.point(np.full(len(tr.grid), m.latest))


def meter_linear(history: History, tr: TargetRequest) -> TargetForecast:
    """The pace so far, extended: a straight line from 0 at the cycle's
    nominal start through the latest reading, to reset, never below the
    reading or above 100. With no time elapsed it is flat."""
    m = meter_now(history, tr)
    elapsed = m.latest_t - m.start
    rate = m.latest / elapsed if elapsed > 0 else 0.0
    g = tr.grid.astype(np.float64)
    return TargetForecast.point(np.clip(m.latest + rate * (g - m.latest_t), m.latest, 100.0))


def next_start_never(history: History, tr: TargetRequest) -> TargetForecast:
    """An idle window stays idle: no start before the horizon (NaN)."""
    return TargetForecast(np.full((1, len(tr.grid)), np.nan))


# ---------------------------------------------------------------------------
# Hourly spend and tokens
# ---------------------------------------------------------------------------

def _what(tr: TargetRequest) -> str:
    return "spend" if tr.target is Target.SPEND_HOURLY else "tokens"


def _family(tr: TargetRequest) -> str | None:
    return tr.family if tr.target is Target.TOKENS_HOURLY else None


def hourly_flat(history: History, tr: TargetRequest, hours: int = 1) -> TargetForecast:
    """The mean of the last `hours` hours (1: persistence), flat."""
    _, v = spend.hourly_series(history, tr.accounts, hours, _what(tr), _family(tr))
    return TargetForecast.point(np.full(len(tr.grid), float(v.mean()) if len(v) else 0.0))


def hourly_seasonal(history: History, tr: TargetRequest, period_h: int) -> TargetForecast:
    """Seasonal naive: each grid hour takes the value of the hour one period
    earlier, repeating the last period for leads beyond it. Hours before the
    history began are 0, which is what the history says about them."""
    _, v = spend.hourly_series(history, tr.accounts, period_h, _what(tr), _family(tr))
    lead_h = np.rint((tr.grid - history.now) / HOUR_MS).astype(np.int64)     # 1, 2, …
    idx = (lead_h - 1) % period_h
    return TargetForecast.point(v[idx])


def hourly_profile(history: History, tr: TargetRequest, weeks: int | None = None) -> TargetForecast:
    """The hour-of-week profile from history only: each grid hour takes the
    same hour of the week (exactly 168 h earlier, so DST never shifts it) in
    every whole past week the history covers (`weeks` caps how many, newest
    first). The paths are those weeks, each a whole trajectory, so the middle
    path is the profile's median and the spread is the weeks' own. Under two
    weeks it is a point: the one week, or under a week the mean of each hour
    of the day over the whole days there are (the mean of every hour there
    is, under a day)."""
    start = _history_start(history)
    span = max(0, history.now - start)
    k = int(span // WEEK_MS) if weeks is None else int(min(span // WEEK_MS, weeks))
    lead_h = np.rint((np.asarray(tr.grid, dtype=np.int64) - history.now) / HOUR_MS).astype(np.int64)
    if k == 0:
        days = int(span // DAY_MS)
        if days == 0:
            return hourly_flat(history, tr, hours=max(1, int(span // HOUR_MS)))
        _, v = spend.hourly_series(history, tr.accounts, 24 * days, _what(tr), _family(tr))
        prof = v.reshape(days, 24).mean(axis=0)
        return TargetForecast.point(prof[(lead_h - 1) % 24])
    _, v = spend.hourly_series(history, tr.accounts, 168 * k, _what(tr), _family(tr))
    # Row r is the week ending (k-1-r) weeks before now; its column j is the
    # hour ending now - (167-j) h of that week. Grid hour now + L h shares its
    # hour of the week with column (L-1) mod 168 of every row.
    paths = v.reshape(k, 168)[:, (lead_h - 1) % 168]
    if k < 2:
        return TargetForecast.point(paths[0])
    return TargetForecast(paths)


def _history_start(history: History) -> int:
    start = getattr(history, "start", None)
    if start is not None:
        return int(start)
    t = history.table("turns")
    if not t.height:
        return history.now
    return int(t.select(pl.col("t_event").dt.epoch("ms").min()).item())


def split_recent(history: History, tr: TargetRequest, group: tuple[str, ...],
                 hours: tuple[int, ...] = (24, 168)) -> TargetForecast:
    """This account's share of the group's spend over the last day (the last
    week when the group spent nothing that day; equal shares when it spent
    nothing all week), flat."""
    acct = tr.accounts[0]
    for h in hours:
        tot = sum(float(spend.hourly_series(history, (a,), h)[1].sum()) for a in group)
        if tot > 0:
            mine = float(spend.hourly_series(history, (acct,), h)[1].sum())
            return TargetForecast.point(np.full(len(tr.grid), mine / tot))
    return TargetForecast.point(np.full(len(tr.grid), 1.0 / max(len(group), 1)))
