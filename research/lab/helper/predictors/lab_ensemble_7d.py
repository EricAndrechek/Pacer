"""7-day: the median of twelve forecasters: six built-in models (the
harness's Python ports, without the daily rhythm), four token-spend
forecasters, and Timestral 5M/28M on four weeks of context. On the owner's
history this median scores 7.20 pp vs the shipping rule's 8.18 (all 4 time
folds), the night's best weekly result."""
from __future__ import annotations

import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "harness"))
import pacer_replay as pr  # noqa: E402

from lab_costcore import decay, rate  # noqa: E402
from lab_timestral import forecast  # noqa: E402

ID = "lab-ensemble-7d"
DISPLAY_NAME = "Median of twelve (weekly)"
SUMMARY = "The middle answer of twelve weekly forecasters: six built-in, four from token spend, two Timestral sizes."
HOW_IT_WORKS = (
    "Asks twelve forecasters for the reading at reset: six of Pacer's built-in models, your recent token spend "
    "held and fading over the last 6 hours and the last day (converted to meter points), and Mistral's Timestral "
    "at 5M and 28M parameters reading four weeks of history. It shows their median, each first clamped between "
    "the current reading and 100%. No weights are learned."
)
WINDOWS = ("seven_day",)
_PARAMS = pr.Params()
_ENGINE = [pr.linear_recent, pr.recency_weighted, pr.damped_acceleration, pr.saturating, pr.kalman_trend, pr.recent_rate]
_CTX = 28 * 96        # four weeks of 15-minute steps
_STEP = 900.0


def predict(window, account, t_cut, cycle_start, resets_at, history):
    cyc = history.cycle()
    used = cyc[-1].pct if cyc else 0.0
    vals = []
    if len(cyc) >= 2:
        partial = pr.Partial([(r.t, r.pct) for r in cyc], t_cut, cycle_start, resets_at)
        for fit in _ENGINE:
            proj = fit(partial, _PARAMS)
            if proj is not None:
                vals.append(pr.displayed_at_reset(proj, partial))
    vals += [rate(history, t_cut, cycle_start, resets_at, 86400), rate(history, t_cut, cycle_start, resets_at, 6 * 3600),
             decay(history, t_cut, cycle_start, resets_at, 6 * 3600, weekly=True),
             decay(history, t_cut, cycle_start, resets_at, 86400, weekly=True)]
    for size in ("5M", "28M"):
        f = forecast(size, history, t_cut, resets_at, _CTX, step=_STEP)
        vals.append(f[0] if f else None)
    vals = [min(100.0, max(used, v)) for v in vals if v is not None]
    if len(vals) < 5:
        return None
    return statistics.median(vals), None, None
