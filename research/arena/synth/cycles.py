"""The `cycles` label table, computed from readings the way the exporter does:
active canonical readings (oauth; five_hour, seven_day, weekly_scoped),
grouped per account and window, and split into cycles with the
`RateLimitCycle.contains` rule — a reading belongs to the current cycle when
its `resets_at` is within half a window of the cycle's — never `==`, because
`resets_at` jitters by milliseconds.

The harness core owns `arena/snapshot/cycles.py`; this copy exists so a
synthetic snapshot is complete on its own. Both must agree on the rule.
"""
from __future__ import annotations

import numpy as np
import polars as pl

from .config import WINDOW_MS

CANONICAL = ("five_hour", "seven_day", "weekly_scoped")


def cycles_from_readings(readings: pl.DataFrame, t_end: int) -> pl.DataFrame:
    """readings: the meter_readings frame with Int64 ms times."""
    r = readings.filter(
        (pl.col("source") == "oauth") & (pl.col("state") == "active")
        & pl.col("window_kind").is_in(list(CANONICAL)) & pl.col("resets_at").is_not_null()
    ).sort(["account", "window_kind", "scope_model", "t_event"], nulls_last=False)
    rows = []
    for (acc, wk, sm), g in r.group_by(["account", "window_kind", "scope_model"], maintain_order=True):
        half = WINDOW_MS[wk] // 2
        t = g["t_event"].to_numpy()
        res = g["resets_at"].to_numpy()
        u = g["util_pct"].to_numpy()
        # New cycle whenever the reset moves by more than half a window.
        cut = np.flatnonzero(np.abs(np.diff(res)) > half) + 1
        bounds = np.concatenate([[0], cut, [len(t)]])
        for s, e in zip(bounds[:-1], bounds[1:]):
            reset = int(np.median(res[s:e]))
            rows.append({
                "cycle_id": f"{acc}:{wk}:{sm or ''}:{reset}",
                "account": acc, "window_kind": wk, "scope_model": sm,
                "reset_at": reset, "start": reset - WINDOW_MS[wk],
                "first_t": int(t[s]), "last_t": int(t[e - 1]), "n": int(e - s),
                "max_util": float(u[s:e].max()), "final_util": float(u[e - 1]),
                "censored": bool(reset > t_end),
            })
    schema = {"cycle_id": pl.String, "account": pl.String, "window_kind": pl.String, "scope_model": pl.String,
              "reset_at": pl.Int64, "start": pl.Int64, "first_t": pl.Int64, "last_t": pl.Int64, "n": pl.Int32,
              "max_util": pl.Float64, "final_util": pl.Float64, "censored": pl.Boolean}
    df = pl.DataFrame(rows, schema=schema)
    # A cycle's label exists once it has reset and its last reading is in.
    return df.with_columns(
        pl.col("start").alias("t_event"),
        pl.max_horizontal("reset_at", "last_t").alias("t_known"),
        pl.lit("unknown").alias("t_known_src"),
    ).sort(["t_event", "account", "window_kind"])
