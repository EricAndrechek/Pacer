"""What the engine reads, built only from the `History` a model was handed:
the meter series it fits and the activity grid it uses as the diurnal prior.

The old harness (`pacer_replay.grid_loader`) built the activity grid from
the whole store, every hour that would ever be recorded included, which
leaked the future into every diurnal forecast. Here the grid comes from the
turns in the history alone, over complete local days before `now`, exactly
as `EngineFeatures.buildActivityGrid` reads the hourly rollup the app had.
"""
from __future__ import annotations

import numpy as np
import polars as pl

from kit.engine.clock import DAY_S, HOUR_S, LocalClock

SYNTHETIC_MODEL = "<synthetic>"


def meter_arrays(readings: pl.DataFrame, account: str, window_kind: str,
                 scope_model: str | None = None) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """(t, util, own reset) in epoch seconds for one meter: every reading with
    a reset (the engine drops the rest), sorted by time."""
    f = readings.filter((pl.col("account") == account) & (pl.col("window_kind") == window_kind)
                        & pl.col("resets_at").is_not_null() & pl.col("util_pct").is_not_null())
    if scope_model is not None:
        f = f.filter(pl.col("scope_model") == scope_model)
    if f.height == 0:
        z = np.zeros(0)
        return z, z, z
    f = f.select(pl.col("t_event").dt.epoch("ms").alias("t"), pl.col("util_pct").cast(pl.Float64).alias("y"),
                 pl.col("resets_at").dt.epoch("ms").alias("r")).sort("t", maintain_order=True)
    return (f["t"].to_numpy().astype(np.float64) / 1000.0, f["y"].to_numpy().astype(np.float64),
            f["r"].to_numpy().astype(np.float64) / 1000.0)


def activity_grid(turns: pl.DataFrame, account: str | None, now_s: float, clock: LocalClock) -> np.ndarray:
    """`EngineFeatures.buildActivityGrid`: P(any priced activity) per
    [weekday 0=Sun][hour], over every local day from the account's first
    active day to yesterday (idle days count in the denominator). An hour is
    active when it holds a real (non-synthetic) turn with tokens. Zeros when
    there is no complete day yet."""
    grid = np.zeros((7, 24))
    if turns.height == 0:
        return grid
    f = turns if account is None else turns.filter(pl.col("account") == account)
    f = f.filter(pl.col("model").fill_null("") != SYNTHETIC_MODEL)
    tok = (pl.col("input").fill_null(0) + pl.col("output").fill_null(0) + pl.col("cache_read").fill_null(0)
           + pl.col("cache_write_5m").fill_null(0) + pl.col("cache_write_1h").fill_null(0))
    f = f.filter(tok > 0)
    if f.height == 0:
        return grid
    off = pl.col("tz_offset_min").cast(pl.Float64).fill_null(clock.offset_s / 60.0) * 60.0
    loc = f.select(((pl.col("t_event").dt.epoch("ms").cast(pl.Float64) / 1000.0) + off).alias("loc"))["loc"]
    loc = loc.to_numpy()
    day = np.floor(loc / DAY_S).astype(np.int64)
    hour = np.clip(np.floor((loc - day * DAY_S) / HOUR_S).astype(np.int64), 0, 23)
    today = int(clock.local_day(now_s))
    m = day < today
    if not m.any():
        return grid
    day, hour = day[m], hour[m]
    first = int(day.min())
    cells = np.unique(day * 24 + hour)
    cd, ch = cells // 24, cells % 24
    wd_of = lambda d: (d + 4) % 7                       # 1970-01-01 was a Thursday
    days = np.arange(first, today)
    day_count = np.bincount(wd_of(days), minlength=7).astype(np.float64)
    active = np.zeros((7, 24))
    np.add.at(active, (wd_of(cd), ch), 1.0)
    ok = day_count > 0
    grid[ok] = active[ok] / day_count[ok, None]
    return grid
