"""5-hour: the last 30 minutes of token spend, converted and calibrated,
continued at the same rate (the lab's tokc-rate-30m-cal: 3.08 pp vs 3.56)."""
from __future__ import annotations

from lab_costcore import rate

ID = "lab-cost-rate-30m"
DISPLAY_NAME = "Recent spend, held"
SUMMARY = "Your last 30 minutes of token spend, converted to meter points and held until the reset."
HOW_IT_WORKS = (
    "Prices every Claude Code turn at API rates and converts dollars to meter points with a factor refit "
    "daily on the last 14 days. Adds the spend since the last reading, then continues the last 30 minutes' "
    "converted burn at the same pace, scaled by how much of it this window's meter actually showed."
)
WINDOWS = ("five_hour",)


def predict(window, account, t_cut, cycle_start, resets_at, history):
    v = rate(history, t_cut, cycle_start, resets_at, 1800)
    return None if v is None else (v, None, None)
