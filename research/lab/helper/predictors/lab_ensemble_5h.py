"""5-hour: the median of the six lab models (two token-spend forecasters and
Timestral 5M/28M/123M/209M). On the owner's history the median of these six
scores 2.76 pp vs the shipping rule's 3.56 (all 4 time folds), as well as the
best learned second layer: on data this thin, combining beats choosing."""
from __future__ import annotations

import statistics

from lab_costcore import decay, rate
from lab_timestral import forecast

ID = "lab-ensemble-5h"
DISPLAY_NAME = "Median of the lab models"
SUMMARY = "The middle answer of six forecasters: two from your token spend, four Timestral sizes."
HOW_IT_WORKS = (
    "Asks six forecasters for the reading at reset: recent token spend fading and held (converted to meter "
    "points), and Mistral's Timestral at 5M, 28M, 123M and 209M parameters. It shows their median, each first "
    "clamped between the current reading and 100%. No weights are learned, so one model's bad call can't drag it."
)
WINDOWS = ("five_hour",)
_SIZES = {"5M": 72, "28M": 72, "123M": 72, "209M": 288}


def predict(window, account, t_cut, cycle_start, resets_at, history):
    cyc = history.cycle()
    used = cyc[-1].pct if cyc else 0.0
    vals = [decay(history, t_cut, cycle_start, resets_at, 1800, weekly=False),
            rate(history, t_cut, cycle_start, resets_at, 1800)]
    for size, steps in _SIZES.items():
        f = forecast(size, history, t_cut, resets_at, steps)
        vals.append(f[0] if f else None)
    vals = [min(100.0, max(used, v)) for v in vals if v is not None]
    if len(vals) < 3:
        return None
    return statistics.median(vals), None, None
