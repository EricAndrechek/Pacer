"""5-hour: the last 30 minutes of token spend, converted to meter points,
fading toward the reset (the lab's tokc-decay-30m: median miss 2.87 pp vs
the shipping rule's 3.56 on the owner's history, better in 4/4 folds)."""
from __future__ import annotations

from lab_costcore import decay

ID = "lab-cost-decay-30m"
DISPLAY_NAME = "Recent spend, fading"
SUMMARY = "Your last 30 minutes of token spend, converted to meter points, tapering off toward the reset."
HOW_IT_WORKS = (
    "Prices every Claude Code turn at API rates and converts dollars to meter points with a factor refit "
    "daily on the last 14 days. Adds the spend since the last reading (the meter lags), then continues the "
    "last 30 minutes' converted burn, scaled by how much of it this window's meter actually showed, fading "
    "with a time constant learned from your earlier windows."
)
WINDOWS = ("five_hour",)


def predict(window, account, t_cut, cycle_start, resets_at, history):
    v = decay(history, t_cut, cycle_start, resets_at, 1800, weekly=False)
    return None if v is None else (v, None, None)
