"""The model contract: what a model is handed and what it hands back.

A model is a folder `models/<name>/` with `model.py` (a class named `Model`)
and `model.toml`. The class is duck-typed against `ModelProtocol`; nothing
forces a base class. Every time is epoch milliseconds UTC (`Millis`).

    class Model:
        def __init__(self, ctx: Context): ...
        def fit(self, history: History) -> None: ...
        def update(self, events: Events) -> None: ...      # optional
        def forecast(self, request: Request) -> Forecast: ...

A forecast is a set of sample paths per requested target. Everything people
see or the scorer needs (the middle path, ranges, the chance of hitting the
limit, the time to the limit, the value at reset) is derived from the same
paths, so those answers can never disagree with each other.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum
from pathlib import Path
from typing import Literal, Protocol, runtime_checkable

import numpy as np
import polars as pl
import pyarrow as pa

Millis = int
DEFAULT_PATHS = 200


class Target(StrEnum):
    """What can be asked for. Meter targets are per account; spend, tokens
    and the split may cover any group of accounts (meters don't add up across
    accounts, spend does).

    The meter's value *now*, between polls (the live meter), is not a separate
    target: it is the first step of a meter path, scored as its own metric
    against the next reading."""

    METER_5H = "meter.five_hour"        # % used, to the current cycle's reset
    METER_7D = "meter.seven_day"        # % used, to reset
    METER_SCOPED = "meter.scoped"       # a per-model cap (TargetRequest.cap), to reset
    CYCLE_NEXT_START = "cycle.next_start"  # when an idle 5-hour window starts again
    SPEND_HOURLY = "spend.hourly"       # API-equivalent USD per hour
    TOKENS_HOURLY = "tokens.hourly"     # tokens per hour (TargetRequest.family, or all)
    # (spend.hourly takes TargetRequest.family too, when a model asks a child)
    SPLIT = "split.accounts"            # this account's share of the group's spend per hour


Units = Literal["pct", "usd_per_hour", "tokens_per_hour", "share", "epoch_ms"]


@dataclass(frozen=True)
class Scope:
    """Whose data a case is about. `view` decides what the model sees:
    "scope_only" — only these accounts' rows, like a user who has just these;
    "all" — every account's rows, with targets on the scope."""

    accounts: tuple[str, ...]
    view: Literal["scope_only", "all"] = "scope_only"


@dataclass(frozen=True)
class TargetRequest:
    """One thing to forecast. `key` names it within the request and the
    forecast (e.g. "meter.five_hour:A2").

    `grid` is int64 epoch ms, strictly increasing, every value > request.now.
    Not evenly spaced: the runner's meter grids start with a dense head (five-
    hour +30 s, +1, +2, +3, +5 min, then every 5 min; seven-day and scoped
    +1, +5, +15, +30 min, then every 30 min) and end exactly at the reset.
    The forecast's paths give the target's value at each grid time:
    - meters: % used at that moment, as the server would report it. Usually
      non-decreasing within a cycle, but not always: an allowance can be
      re-based mid-cycle (the meter falls, the reset stays), and truth keeps
      every reading as read, never a running maximum;
    - spend / tokens: the rate over the hour ending at that grid time;
    - split: the share over the hour ending at that grid time;
    - cycle.next_start: grid has one entry (the horizon) and each path holds a
      sampled start time in epoch ms, NaN for "no start before the horizon".
    """

    key: str
    target: Target
    accounts: tuple[str, ...]
    grid: np.ndarray
    units: Units
    n_paths: int = DEFAULT_PATHS
    cap: str | None = None            # meter.scoped: e.g. "Fable"
    family: str | None = None         # tokens.hourly, spend.hourly: a model family, None = all
                                      # (the runner asks spend for all families; a parent may
                                      # ask a child for one family's spend)
    reset_at: Millis | None = None    # meters: the cycle's reset as known at now


@dataclass(frozen=True)
class Request:
    now: Millis
    scope: Scope
    targets: tuple[TargetRequest, ...]


@dataclass
class TargetForecast:
    """`paths`: float64 [n_paths, len(grid)]. `extras`: optional direct
    estimates the model wants scored too, by name:
    "p_hit_limit" (float), "time_to_limit" (float64 samples, epoch ms, NaN =
    not before reset)."""

    paths: np.ndarray
    extras: dict[str, float | np.ndarray] = field(default_factory=dict)

    @classmethod
    def point(cls, values: np.ndarray, n_paths: int = 1) -> "TargetForecast":
        """A model with no idea of uncertainty: one path, repeated. It scores
        fine on point metrics and honestly badly on calibration."""
        v = np.asarray(values, dtype=np.float64)[None, :]
        return cls(np.repeat(v, n_paths, axis=0))

    @classmethod
    def from_quantiles(
        cls,
        levels: np.ndarray,
        values: np.ndarray,
        n_paths: int = DEFAULT_PATHS,
        dependence: Literal["comonotone"] = "comonotone",
        rng: np.random.Generator | None = None,
    ) -> "TargetForecast":
        """Turn per-grid-time quantiles ([n_levels, len(grid)]) into paths.
        "comonotone" draws one uniform per path and reads every grid time at
        that same level: a path that is high early stays high. That suits a
        cumulative meter; a model that believes otherwise should make its
        own paths."""
        rng = rng or np.random.default_rng(0)
        lv = np.asarray(levels, dtype=np.float64)
        q = np.asarray(values, dtype=np.float64)
        u = np.sort(rng.uniform(lv.min(), lv.max(), size=n_paths))
        paths = np.stack([np.interp(u, lv, q[:, j]) for j in range(q.shape[1])], axis=1)
        return cls(paths)


@dataclass
class Forecast:
    by_key: dict[str, TargetForecast]


class TableView(Protocol):
    """Shared read API of `History` and `Events`."""

    tables: tuple[str, ...]

    def table(self, name: str) -> pl.DataFrame: ...
    def arrow(self, name: str) -> pa.Table: ...
    def sql(self, query: str) -> pl.DataFrame:
        """DuckDB over the same tables, each registered under its own name."""
        ...


class History(TableView, Protocol):
    """Everything known at `now`: rows with t_known <= now, restricted to the
    scope's accounts when scope.view == "scope_only". Read-only. Label tables
    (cycles, records of what the app did) are never in it."""

    now: Millis
    scope: Scope
    accounts: tuple[str, ...]
    mode: Literal["current_code", "as_recorded"]
    # The device's UTC offset in minutes as known at now (the latest known
    # turn's `tz_offset_min`, any account, even in a scope-only view: the
    # user's clock is not account data); None while no turn is known.
    tz_offset_min: int | None

    def extend(self, events: "Events") -> "History":
        """The history as of events.until: what a model that keeps no state
        of its own calls in `update`."""
        ...


class Events(TableView, Protocol):
    """Rows that became known in (since, until]."""

    since: Millis
    until: Millis
    tz_offset_min: int | None      # as History.tz_offset_min, known at until


class ChildModel(Protocol):
    def forecast(self, request: Request) -> Forecast: ...


class Context(Protocol):
    """Handed to a model's constructor.

    `model(name)` returns a child declared in model.toml. The runner, not the
    parent, runs it, in its own worker, with exactly the parent's view at the
    same moments; its forecasts are cached across runs. `backtest` returns a
    child's forecasts over the parent's own past, each made without seeing
    what followed — the safe way to train a combiner."""

    seed: int
    rng: np.random.Generator
    scratch: Path
    config: dict
    children: tuple[str, ...]      # the child names model.toml declares (the only ones `model` takes)

    def model(self, name: str) -> ChildModel: ...
    def backtest(
        self, name: str, *, every: Millis, targets: tuple[Target, ...],
        since: Millis | None = None,
    ) -> list[tuple[Request, Forecast]]: ...
    def log(self, message: str) -> None: ...


@runtime_checkable
class ModelProtocol(Protocol):
    def fit(self, history: History) -> None: ...
    def forecast(self, request: Request) -> Forecast: ...


@dataclass
class TargetTruth:
    """What actually happened after `now` for one target key. The runner
    builds it from data the model never saw; scoring reads it.

    `times` are the real observation times (meter readings, or hour ends for
    hourly targets) in (now, horizon_end]; `values` the observed values there.
    Meters: never interpolated, and stopping at the cycle's reset."""

    times: np.ndarray                  # int64 epoch ms
    values: np.ndarray                 # float64
    horizon_end: Millis
    reset_at: Millis | None = None
    hit_limit: bool | None = None      # meters: a reading reached 100 before reset
    time_to_limit: float = float("nan")  # meters: first reading >= 100, NaN if none
    next_start: float = float("nan")   # cycle.next_start: actual start, NaN if none


@dataclass
class Truth:
    by_key: dict[str, TargetTruth]


@dataclass(frozen=True)
class ScoreRow:
    """One score of one forecast. Whole-path metrics have lead_s = None;
    lead-binned metrics carry the bin's upper edge in seconds."""

    target_key: str
    target: str
    metric: str
    lead_s: float | None
    value: float
