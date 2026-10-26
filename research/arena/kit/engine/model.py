"""The arena model behind every `models/port-engine-*`: the app's
rate-limit engine for `meter.five_hour`, `meter.seven_day` and
`meter.scoped`, as the shipping rule (`method = "rule"`) or one fixed method.

Config (`model.toml [config]`):
- `method`: "rule" or a method id (`kit.engine.core.METHOD_IDS`);
- `params_version`: optional `EngineParams` tag (`kit.engine.params.VERSIONS`);
  default today's.

One `WindowEngine` per (account, window) lives for the episode, so each
cycle is scored into the record once (at the first forecast for the cycles
already complete, the app's launch backfill; later ones as they complete).
Everything is read from the `History`: nothing outside it, no files.
"""
from __future__ import annotations

import numpy as np
import polars as pl

from arena.types import Forecast, Target, TargetForecast
from kit.engine.clock import LocalClock, clock_for, offset_minutes
from kit.engine.engine import RULE, Outlook, WindowEngine
from kit.engine.params import SHIPPING, Params, for_version
from kit.engine.paths import flat_paths, outlook_paths
from kit.engine.series import activity_grid, meter_arrays

HOUR_S = 3600.0
WINDOW_OF = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day", Target.METER_SCOPED: "weekly_scoped"}
# WindowSpec: the fixed blocks by name, scoped weekly caps by their group hint.
DURATION_S = {"five_hour": 5 * HOUR_S, "seven_day": 7 * 24 * HOUR_S, "weekly_scoped": 7 * 24 * HOUR_S}


class EngineState:
    """The engines of one model instance, fed from a History at each moment."""

    def __init__(self, method: str = RULE, params: Params = SHIPPING):
        self.method, self.params = method, params
        self.engines: dict[tuple, WindowEngine] = {}
        self._grid_key = None
        self._grids: dict[str | None, np.ndarray] = {}
        self._clocks: dict[tuple, object] = {}

    def outlook(self, history, account: str, window_kind: str, scope_model: str | None,
                now_s: float, params: Params | None = None) -> Outlook | None:
        key = (account, window_kind, scope_model)
        eng = self.engines.get(key)
        if eng is None:
            eng = WindowEngine(DURATION_S[window_kind], self.clock(history, account, now_s),
                               method=self.method, params=self.params)
            self.engines[key] = eng
        else:
            eng.clock = self.clock(history, account, now_s, eng.clock)
        t, y, r = meter_arrays(history.table("meter_readings"), account, window_kind, scope_model)
        if len(t) == 0:
            return None
        return eng.observe(t, y, r, now_s, self.grid(history, account, now_s, eng), params)

    def clock(self, history, account: str, now_s: float, fallback=None):
        """The account's local clock as the history now says (the latest offset
        its turns carry), read once per history and moment. While no turn in
        the history carries one, the device's offset (`History.tz_offset_min`,
        when the harness provides it: the app always knows the Mac's clock),
        else `fallback`, else UTC."""
        k = ("clock", id(history), now_s, account)
        if k not in self._clocks:
            if len(self._clocks) > 64:
                self._clocks.clear()
            turns = history.table("turns")
            device = getattr(history, "tz_offset_min", None)
            if device is not None and offset_minutes(turns, account) is None:
                self._clocks[k] = LocalClock(float(device) * 60.0)
            else:
                self._clocks[k] = clock_for(turns, account, fallback)
        return self._clocks[k]

    def grid(self, history, account: str, now_s: float, eng: WindowEngine) -> np.ndarray:
        """The account's activity grid as of now, once per history and moment."""
        k = (id(history), now_s)
        if self._grid_key != k:
            self._grid_key, self._grids = k, {}
        if account not in self._grids:
            self._grids[account] = activity_grid(history.table("turns"), account, now_s, eng.clock)
        return self._grids[account]


def latest_in_cycle(history, account: str, window_kind: str, scope_model: str | None,
                    reset_ms: int | None, now_s: float) -> float:
    """The latest known reading of the requested cycle (any reading when the
    reset is unknown), 0 when there is none."""
    t, y, r = meter_arrays(history.table("meter_readings"), account, window_kind, scope_model)
    m = t <= now_s
    if reset_ms is not None:
        m &= np.abs(r - reset_ms / 1000.0) < DURATION_S[window_kind] / 2
    return float(y[m][-1]) if m.any() else 0.0


class EngineModel:
    def __init__(self, ctx):
        cfg = dict(getattr(ctx, "config", {}) or {})
        self.ctx = ctx
        method = str(cfg.get("method", RULE))
        params = for_version(cfg.get("params_version")) or SHIPPING
        self.state = EngineState(method, params)
        self.history = None
        self._why: set[str] = set()

    def fit(self, history) -> None:
        self.history = history

    def update(self, events) -> None:
        self.history = self.history.extend(events)

    def forecast(self, request) -> Forecast:
        now_s = request.now / 1000.0
        out = {}
        for tr in request.targets:
            kind = WINDOW_OF.get(tr.target)
            if kind is None:
                continue
            cap = tr.cap if tr.target is Target.METER_SCOPED else None
            out[tr.key] = TargetForecast(self._paths(tr, tr.accounts[0], kind, cap, now_s))
        return Forecast(out)

    def _paths(self, tr, account: str, kind: str, cap: str | None, now_s: float) -> np.ndarray:
        grid_s = np.asarray(tr.grid, dtype=np.float64) / 1000.0
        o = self.state.outlook(self.history, account, kind, cap, now_s)
        same_cycle = (o is not None and (tr.reset_at is None
                      or abs(o.reset - tr.reset_at / 1000.0) < DURATION_S[kind] / 2))
        if same_cycle and o.proj is not None:
            return outlook_paths(o, grid_s, tr.n_paths, self.state.params)
        # Nothing to draw (the method declines this cycle, or no live cycle):
        # the meter held where it is, as the app shows the reading alone.
        why = "declined" if same_cycle else "no live cycle"
        if why not in self._why:
            self._why.add(why)
            self._log(f"{tr.key}: {why}; holding the latest reading")
        base = o.used_now if same_cycle else latest_in_cycle(self.history, account, kind, cap, tr.reset_at, now_s)
        return flat_paths(base, len(grid_s), tr.n_paths)

    def _log(self, msg: str) -> None:
        log = getattr(self.ctx, "log", None)
        if callable(log):
            log(msg)
