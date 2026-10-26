"""The plumbing every learned meter model shares: as-of data, a model per
window kind trained lazily on a walk-forward set from the history, a
fallback when there is too little to learn from, and paths on the request
grid.

A subclass implements `train(ts) -> state` and
`predict(state, row, lead_X, fracs, used, n_paths, rng) -> TargetForecast-like`
(see `LearnedMeterModel`). Trained state is kept in memory for the episode
and, as the brief asks, in `ctx.scratch` (per worker, so per episode):
nothing survives into another episode.

`update` folds the new rows into the as-of data without retraining (the
model fitted at the cutoff keeps forecasting from fresh features); it
retrains once `retrain_h` hours of new data have arrived, which only
matters in long-run episodes.
"""
from __future__ import annotations

import pickle
import time
from pathlib import Path

import numpy as np

from arena.types import Forecast, Target, TargetForecast
from kit.ml.data import HOUR_MS, AsOfData
from kit.ml.features import F, FeatureBuilder
from kit.ml.paths import grid_fracs, rise_paths
from kit.ml.walkforward import LEADS, build_trainset

WINDOW_OF = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day", Target.METER_SCOPED: "weekly_scoped"}
# Where the model reads its rise distribution at forecast time.
ANCHORS = np.array([0.01, 0.03, 0.06, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0])
FALLBACK_LEVELS = np.array([0.05, 0.15, 0.3, 0.5, 0.7, 0.85, 0.95])


def fallback_quantiles(row: np.ndarray, fracs: np.ndarray, levels: np.ndarray = FALLBACK_LEVELS) -> np.ndarray:
    """No model: the average of the cycle's burn so far and the recent burn
    (readings, or converted spend when that is higher) carried to each lead,
    with a wide spread. [levels, fracs]."""
    from scipy.stats import norm
    rem_h = row[F["remaining_h"]]
    recent = max(row[F["rate_1"]], row[F["conv_rate_1"]])
    rate = 0.5 * (row[F["rate_cycle"]] + recent)
    lead_h = fracs * rem_h
    med = rate * lead_h
    z = norm.ppf(levels)[:, None]
    return med[None, :] * np.exp(0.8 * z) + np.maximum(z, 0) * (0.5 * np.sqrt(lead_h) + 0.3 * med)[None, :]


class LearnedMeterModel:
    """Duck-typed arena model. Config keys (all optional): `max_rows`,
    `min_rows`, `min_cycles`, `retrain_h`, `train_at_fit`, `step_min` (lattice step override per kind as
    {kind: minutes}), `max_days` ({kind: days}), `use_cache`."""

    name = "learned"

    def __init__(self, ctx):
        self.ctx = ctx
        self.cfg = dict(ctx.config)
        self.rng = ctx.rng
        self.scratch = Path(ctx.scratch)
        self.data: AsOfData | None = None
        self.history_start: int | None = None
        self.state: dict = {}
        self.builders: dict = {}

    # contract ------------------------------------------------------------
    def fit(self, history):
        self.data = AsOfData.from_history(history)
        self.history_start = getattr(history, "start", None)
        self.state, self.builders = {}, {}
        if self.cfg.get("train_at_fit", False):
            # Off by default: a kind is trained (from this same history) at the
            # first forecast that asks for it, so a child asked only for the
            # five-hour meter never pays for the weekly ones.
            for (_, kind, cap) in sorted({(0, k, c) for (_, k, c) in self.data.meters}, key=str):
                self._state(kind, cap)

    def update(self, events):
        self.data = self.data.extend(events, events.until)
        self.builders = {}                       # caches are as-of buckets; rebuild over the new data
        stale = [k for k, (t, _) in self.state.items()
                 if self.data.now - t > float(self.cfg.get("retrain_h", 24)) * HOUR_MS]
        for k in stale:
            del self.state[k]

    def forecast(self, request):
        out = {}
        for tr in request.targets:
            kind = WINDOW_OF.get(tr.target)
            if kind is None:
                continue
            out[tr.key] = self._meter(request.now, tr, kind)
        return Forecast(out)

    # internals -----------------------------------------------------------
    def builder(self, kind: str) -> FeatureBuilder:
        if kind not in self.builders:
            self.builders[kind] = FeatureBuilder(self.data, kind)
        return self.builders[kind]

    def _meter(self, now, tr, kind) -> TargetForecast:
        acct = tr.accounts[0]
        cap = tr.cap if kind == "weekly_scoped" else None
        series = self.data.meter(acct, kind, cap)
        reset = tr.reset_at
        st = series.state_at(now, reset) if series is not None else None
        if st is None:
            # Nothing known of this cycle: a flat path at the latest level.
            lvl = series.level_at(now)[0] if series is not None else 0.0
            return TargetForecast.point(np.full(len(tr.grid), lvl), tr.n_paths)
        reset = reset or st.reset
        b = self.builder(kind)
        row = b.row(series, now, reset, st)
        g = grid_fracs(tr.grid, now, reset)
        state = self._state(kind, cap)
        if state is None:
            return rise_paths(FALLBACK_LEVELS, fallback_quantiles(row, ANCHORS), ANCHORS, g, st.used,
                              tr.n_paths, self.rng)
        lead_X = b.lead_rows(row, series, now, reset, ANCHORS)
        return self.predict(state, row, lead_X, ANCHORS, g, st.used, tr.n_paths, self.rng)

    def _state(self, kind: str, cap: str | None):
        key = (kind, cap)
        if key in self.state:
            return self.state[key][1]
        now = self.data.now
        cache = self.scratch / f"{self.name}-{kind}-{cap}-{now}.pkl"
        state = None
        if self.cfg.get("use_cache", True) and cache.is_file():
            try:
                state = pickle.loads(cache.read_bytes())
            except Exception:  # noqa: BLE001 - a bad cache entry is just a miss
                state = None
        if state is None:
            t0 = time.time()
            ts = build_trainset(self.data, self.builder(kind), kind, cap, now, start=self.history_start,
                                step=self._cfg_kind("step_min", kind, 60_000),
                                max_days=self._cfg_kind("max_days", kind, 1),
                                max_rows=int(self.cfg.get("max_rows", 4000)), leads=LEADS)
            n_cyc = int(ts.cycle.max()) + 1 if len(ts) else 0
            enough = len(ts) >= int(self.cfg.get("min_rows", 60)) and n_cyc >= int(self.cfg.get("min_cycles", 4))
            state = self.train(ts, kind) if enough else None
            self.ctx.log(f"{self.name} {kind}{':' + cap if cap else ''}: {len(ts)} rows, {n_cyc} cycles, "
                         f"{'trained' if state is not None else 'fallback'} in {time.time() - t0:.1f}s")
            if state is not None and self.cfg.get("use_cache", True):
                try:
                    cache.write_bytes(pickle.dumps(state))
                except OSError:
                    pass
        self.state[key] = (now, state)
        return state

    def _cfg_kind(self, name: str, kind: str, unit: int):
        v = self.cfg.get(name)
        if isinstance(v, dict) and kind in v:
            return int(float(v[kind]) * unit)
        return None

    # subclass API --------------------------------------------------------
    def train(self, ts, kind):
        raise NotImplementedError

    def predict(self, state, row, lead_X, fracs, grid_fracs, used, n_paths, rng) -> TargetForecast:
        raise NotImplementedError
