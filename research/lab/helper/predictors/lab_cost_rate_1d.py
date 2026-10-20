"""7-day: the last day of token spend, converted and calibrated, continued
to the reset (the lab's tokc-rate-1d-cal: mean miss 7.59 pp vs 8.18)."""
from __future__ import annotations

from lab_costcore import rate

ID = "lab-cost-rate-1d"
DISPLAY_NAME = "Last day's spend, held"
SUMMARY = "Your last day of token spend, converted to meter points and held until the reset."
HOW_IT_WORKS = (
    "Prices every Claude Code turn at API rates and converts dollars to meter points with a factor refit "
    "daily on the last 14 days. Adds the spend since the last reading, then continues the last day's "
    "converted burn at the same pace, scaled by how much of it this window's meter actually showed."
)
WINDOWS = ("seven_day",)


def predict(window, account, t_cut, cycle_start, resets_at, history):
    v = rate(history, t_cut, cycle_start, resets_at, 86400)
    return None if v is None else (v, None, None)
