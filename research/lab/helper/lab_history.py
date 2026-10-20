"""What a predictor is allowed to see: readings at or before the cut.

The helper builds one `History` per (cycle, cut) and hands it to every
predictor. It holds a copy of the readings with `t <= t_cut` and nothing
later, so a predictor cannot peek at the future by accident: there is no
later reading to reach. Other windows of the same account come through
`window()`, bounded by the same cut.

Times are unix seconds, usage is percentage points (0–100).
"""
from __future__ import annotations

import bisect
import math
from typing import Callable, NamedTuple


def _minute(t: float) -> int:
    """A reset to the minute, rounded half away from zero as Swift's
    `.rounded()` does (Python's `round` rounds half to even)."""
    return math.floor(t / 60 + 0.5)


class Reading(NamedTuple):
    t: float           # when the reading was taken
    pct: float         # the meter, percentage points
    resets_at: float   # the reset the server reported with it


class Cycle(NamedTuple):
    """A cycle that had reset by the cut (a legitimate training target)."""
    cycle_start: float
    resets_at: float
    readings: tuple[Reading, ...]
    final: float       # the cycle's peak reading: what a forecast is scored against


class History:
    __slots__ = ("window", "account", "t_cut", "cycle_start", "resets_at", "duration",
                 "readings", "_other")

    def __init__(self, *, window: str, account: str | None, t_cut: float, cycle_start: float,
                 resets_at: float, duration: float, readings: tuple[Reading, ...],
                 other: Callable[[str, float], tuple[Reading, ...]] | None = None):
        self.window = window
        self.account = account
        self.t_cut = t_cut
        self.cycle_start = cycle_start
        self.resets_at = resets_at
        self.duration = duration
        # Every reading of this window and account at or before the cut,
        # time-ordered, all cycles. The helper slices it; a predictor gets
        # nothing past `t_cut`.
        self.readings = readings
        self._other = other

    # -- this cycle -----------------------------------------------------------

    def cycle(self) -> tuple[Reading, ...]:
        """This cycle's readings up to the cut, grouped the way the app groups
        them (`BurnTrajectory.segment`): the reading's reset, rounded to the
        minute, is this cycle's (the server's reset jitters by milliseconds).
        Strictly after `cycle_start`, because a cycle that began with an
        off-schedule reset starts at the last reading before the drop, and
        that reading belongs to the old one."""
        lo = bisect.bisect_right(self.readings, self.cycle_start, key=lambda r: r.t)
        key = _minute(self.resets_at)
        return tuple(r for r in self.readings[lo:] if _minute(r.resets_at) == key)

    def used_now(self) -> float:
        """The meter at the cut: this cycle's last reading, 0 when it has none
        yet (a window opens at 0%)."""
        c = self.cycle()
        return c[-1].pct if c else 0.0

    def since(self, t0: float) -> tuple[Reading, ...]:
        """Readings with `t0 <= t <= t_cut`, any cycle."""
        lo = bisect.bisect_left(self.readings, t0, key=lambda r: r.t)
        return self.readings[lo:]

    # -- the past ---------------------------------------------------------------

    def completed_cycles(self) -> list[Cycle]:
        """Every cycle of this window that had reset by the cut, oldest first,
        grouped by reset to the minute (as the app keys cycles)."""
        groups: dict[int, list[Reading]] = {}
        for r in self.readings:
            if r.resets_at <= self.t_cut:
                groups.setdefault(_minute(r.resets_at), []).append(r)
        out = []
        for _, rows in sorted(groups.items()):
            reset = max(r.resets_at for r in rows)
            out.append(Cycle(reset - self.duration, reset, tuple(rows), max(r.pct for r in rows)))
        return out

    def window_readings(self, window: str) -> tuple[Reading, ...]:
        """Another window (or scoped identity) of the same account, at or
        before the cut. Empty when the helper can't read it."""
        if self._other is None:
            return ()
        return self._other(window, self.t_cut)
