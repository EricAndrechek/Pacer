"""The plumbing check: the built-in `recent-rate` model, ported to Python.

The meter's rise over the last hour (a day on a window a day or longer) held
from the latest reading to the reset, the same rule as
`BurnTrajectory.RecentRate` in the app. Because it is the same rule, its
record in the app should track `recent-rate`'s closely: if it doesn't, the
plumbing (cuts, cycle bounds, history slicing) is wrong, not the model.
"""
from __future__ import annotations

from lab_history import Reading

ID = "lab-recent-rate-py"
DISPLAY_NAME = "Latest pace, held (lab)"
SUMMARY = "The lab helper's Python copy of 'Latest pace, held': the last hour's rise, held to the reset."
HOW_IT_WORKS = (
    "Served by the prediction-lab helper. Takes how far the meter rose over the last hour (a day on "
    "weekly windows) and assumes that pace holds from the latest reading until the reset. It is the "
    "built-in rule run in Python, so its record should match the built-in model's."
)
WINDOWS = ("five_hour", "seven_day")


def predict(window, account, t_cut, cycle_start, resets_at, history):
    readings = list(history.cycle())
    # A window opens at 0%: that is a reading (BurnTrajectory.PartialCycle).
    if not readings or readings[0].t > cycle_start + 1:
        readings.insert(0, Reading(cycle_start, 0.0, resets_at))
    if len(readings) < 2:
        return None
    last = readings[-1]
    lookback = 86400.0 if resets_at - cycle_start >= 86400 else 3600.0
    since = t_cut - lookback
    start = None
    if since > cycle_start:
        before = [r for r in readings if r.t <= since]
        start = before[-1] if before else None
    t0, u0 = (start.t, start.pct) if start else (cycle_start, 0.0)
    span = last.t - t0
    if span < 300:
        return None
    rate = max(0.0, (last.pct - u0) / span)
    return last.pct + rate * (resets_at - last.t), None, None
