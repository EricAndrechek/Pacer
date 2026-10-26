"""The second clock: `t_known`, when today's Pacer would have held a row in
its final form (spec §2.2).

- From SwiftData history (09-24 on) it is exact: the insert, or the last
  streamed output upgrade.
- Before that it is modeled: `t_event` plus a lag drawn once per row from the
  empirical post-history distribution, then moved to the next moment Pacer
  was polling if it wasn't. Before the first poll there is no evidence the
  app ran at all, so the distribution's p99 is used.

Draws are a pure function of (row id, stream, seed): no RNG state, so the
same row gets the same lag whatever else is in the export and in whatever
order rows arrive. That is what "drawn once per row, with a fixed seed"
means here, and why the determinism gate can hold.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

SECOND = 1_000
MINUTE = 60 * SECOND
HOUR = 60 * MINUTE
DAY = 24 * HOUR

LAG_SEED = 20261024
# An insert more than this long after the moment Pacer could first have read
# the row is a backfill (a re-read under a code fix, a new transcript root),
# not ingest lag: today's code would have read the row at the time.
BACKFILL_SLACK_MS = 6 * HOUR
# Gaps over this between oauth polls close an app_alive interval.
ALIVE_GAP_MS = 15 * MINUTE
QUANTILE_POINTS = 200

_GOLDEN = np.uint64(0x9E3779B97F4A7C15)
_M1 = np.uint64(0xBF58476D1CE4E5B9)
_M2 = np.uint64(0x94D049BB133111EB)


def _splitmix64(x: np.ndarray) -> np.ndarray:
    with np.errstate(over="ignore"):
        z = x + _GOLDEN
        z = (z ^ (z >> np.uint64(30))) * _M1
        z = (z ^ (z >> np.uint64(27))) * _M2
        return z ^ (z >> np.uint64(31))


def unit_draw(ids: np.ndarray, stream: int, seed: int = LAG_SEED) -> np.ndarray:
    """A uniform in [0, 1) per id, fixed by (id, stream, seed)."""
    ids = np.asarray(ids, dtype=np.uint64)
    with np.errstate(over="ignore"):
        mix = np.uint64((seed * 0x100000001B3 + stream * 0x9E3779B1) & 0xFFFFFFFFFFFFFFFF)
        z = _splitmix64(_splitmix64(ids ^ mix))
    return (z >> np.uint64(11)).astype(np.float64) * (1.0 / (1 << 53))


@dataclass(frozen=True)
class LagModel:
    """An empirical lag distribution as QUANTILE_POINTS+1 evenly spaced
    quantiles (ms). Draws interpolate between them."""

    name: str
    quantiles_ms: tuple[int, ...]
    n_fit: int

    @classmethod
    def fit(cls, name: str, lags_ms: np.ndarray) -> "LagModel":
        lags = np.asarray(lags_ms, dtype=np.float64)
        lags = lags[np.isfinite(lags) & (lags >= 0)]
        if lags.size == 0:
            return cls(name, (0,) * (QUANTILE_POINTS + 1), 0)
        q = np.quantile(lags, np.linspace(0.0, 1.0, QUANTILE_POINTS + 1), method="linear")
        return cls(name, tuple(int(round(v)) for v in q), int(lags.size))

    def draw(self, u: np.ndarray) -> np.ndarray:
        q = np.asarray(self.quantiles_ms, dtype=np.float64)
        x = np.clip(np.asarray(u, dtype=np.float64), 0.0, 1.0) * (len(q) - 1)
        i = np.minimum(np.floor(x).astype(np.int64), len(q) - 2)
        frac = x - i
        return np.round(q[i] + frac * (q[i + 1] - q[i])).astype(np.int64)

    def quantile(self, p: float) -> int:
        return int(self.draw(np.array([p]))[0])

    def params(self) -> dict:
        return {"name": self.name, "n_fit": self.n_fit, "seed": LAG_SEED,
                "p50_ms": self.quantile(0.5), "p90_ms": self.quantile(0.9),
                "p99_ms": self.quantile(0.99), "p999_ms": self.quantile(0.999),
                "quantiles_ms": list(self.quantiles_ms)}


@dataclass(frozen=True)
class Alive:
    """Intervals [start, end] during which Pacer was polling."""

    starts: np.ndarray
    ends: np.ndarray

    @classmethod
    def from_polls(cls, poll_ms: np.ndarray, gap_ms: int = ALIVE_GAP_MS) -> "Alive":
        t = np.unique(np.asarray(poll_ms, dtype=np.int64))
        if t.size == 0:
            return cls(np.array([], dtype=np.int64), np.array([], dtype=np.int64))
        cut = np.flatnonzero(np.diff(t) > gap_ms)
        starts = np.concatenate([[t[0]], t[cut + 1]])
        ends = np.concatenate([t[cut], [t[-1]]])
        return cls(starts.astype(np.int64), ends.astype(np.int64))

    @property
    def first(self) -> int | None:
        return int(self.starts[0]) if self.starts.size else None

    def is_alive(self, t: np.ndarray) -> np.ndarray:
        t = np.asarray(t, dtype=np.int64)
        if self.starts.size == 0:
            return np.zeros(t.shape, dtype=bool)
        i = np.searchsorted(self.starts, t, side="right") - 1
        ok = i >= 0
        out = np.zeros(t.shape, dtype=bool)
        out[ok] = t[ok] <= self.ends[i[ok]]
        return out

    def adjust(self, t: np.ndarray) -> np.ndarray:
        """Move a time that falls in a gap to the start of the next interval.
        Times before the first interval or after the last are left alone
        (no evidence either way)."""
        t = np.asarray(t, dtype=np.int64).copy()
        if self.starts.size == 0:
            return t
        i = np.searchsorted(self.starts, t, side="right") - 1
        in_gap = (i >= 0) & (i + 1 < self.starts.size)
        in_gap[in_gap] &= t[in_gap] > self.ends[i[in_gap]]
        t[in_gap] = self.starts[i[in_gap] + 1]
        return t


def modeled_t_known(t_event: np.ndarray, ids: np.ndarray, lag: LagModel, alive: Alive,
                    stream: int) -> np.ndarray:
    """t_event + a per-row lag draw, moved into the next alive interval.
    Before the first poll: t_event + the model's p99."""
    t_event = np.asarray(t_event, dtype=np.int64)
    out = t_event + lag.draw(unit_draw(ids, stream))
    out = alive.adjust(out)
    if alive.first is not None:
        pre = t_event < alive.first
        out[pre] = t_event[pre] + lag.quantile(0.99)
    return np.maximum(out, t_event)
