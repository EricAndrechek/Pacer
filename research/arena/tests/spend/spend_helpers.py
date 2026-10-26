"""Hand-built histories for the spend kit's tests: a few turns, readings and
prices written to the pinned schema, served as a `HistoryView` at `now`.

Prices cover the input part only and turns carry input tokens only, so a
turn's cost is exactly `input × rate / 1e6`: with RATE = 1 per million, a turn
of 1,000,000 input tokens costs $1.
"""
from __future__ import annotations

import pyarrow as pa

from arena.snapshot.schema import TABLES
from arena.snapshot.views import HistoryView, conform
from arena.types import Scope

MIN = 60_000
HOUR = 60 * MIN
DAY = 24 * HOUR
T0 = 1_788_220_800_000          # 2026-09-01T00:00:00Z (a UTC midnight)
MODELS = {"opus": "claude-opus-4-5", "sonnet": "claude-sonnet-4-5", "haiku": "claude-haiku-4-5",
          "fable": "claude-fable-5-1"}
RATE = 1.0                      # USD per million input tokens, every model


def _table(name: str, rows: list[dict]) -> pa.Table:
    spec = TABLES[name]
    names = [c for c, _ in spec.columns]
    cols = {c: [r.get(c) for r in rows] for c in names}
    arrays = [pa.array(cols[c], type=t) for c, t in spec.columns]
    return conform(pa.Table.from_arrays(arrays, names=names), spec)


def turn(account: str, t: int, family: str, usd: float, *, known: int | None = None,
         tz: int = 0, call: int | None = None) -> dict:
    return {"t_event": t, "t_known": t if known is None else known, "t_known_src": "observed",
            "call_id": call if call is not None else (hash((account, t, family, usd)) & 0x7FFFFFFFFFFF),
            "account": account, "model": MODELS[family], "model_family": family,
            "input": int(round(usd * 1e6 / RATE)), "output": 0, "cache_read": 0,
            "cache_write_5m": 0, "cache_write_1h": 0, "output_reliable": True, "tz_offset_min": tz}


def reading(account: str, t: int, pct: float, reset: int | None, *, window: str = "five_hour",
            scope_model: str | None = None, known: int | None = None) -> dict:
    return {"t_event": t, "t_known": t if known is None else known, "t_known_src": "observed",
            "account": account, "window_kind": window, "scope_model": scope_model,
            "util_pct": float(pct), "resets_at": reset, "state": "active" if reset is not None else "idle",
            "source": "oauth", "origin": "live"}


def prices(known: int = T0 - 30 * DAY) -> list[dict]:
    return [{"t_event": known, "t_known": known, "t_known_src": "observed", "model": m, "part": "input",
             "tier_threshold": None, "rate_per_mtok": RATE, "source": "curated",
             "t_effective_from": known, "is_correction": False} for m in MODELS.values()]


def history(now: int, *, turns: list[dict] = (), readings: list[dict] = (),
            accounts: tuple[str, ...] = ("A1",), view: str = "scope_only") -> HistoryView:
    """Every row must already be known by `now` (the harness never serves
    anything else); this asserts it, so a test can't build a leak by hand."""
    tables = {"turns": _table("turns", list(turns)), "meter_readings": _table("meter_readings", list(readings)),
              "prices": _table("prices", prices())}
    for n, t in tables.items():
        tk = t.column("t_known").cast(pa.int64()).to_pylist()
        assert all(x <= now for x in tk), f"{n}: a row known after now"
    return HistoryView.from_arrow(tables, now, Scope(accounts, view))


def steady(account: str, start: int, end: int, step: int, pct0: float, reset: int,
           points_per_step: float, family_usd: dict[str, float], *, window: str = "five_hour",
           scope_model: str | None = None) -> tuple[list[dict], list[dict]]:
    """Readings every `step` from start to end climbing `points_per_step`
    each, and between each pair one turn per family of `family_usd[f]`
    dollars: (turns, readings)."""
    turns, reads = [], []
    p = pct0
    t = start
    reads.append(reading(account, t, p, reset, window=window, scope_model=scope_model))
    while t + step <= end:
        for i, (f, usd) in enumerate(family_usd.items()):
            if usd > 0:
                turns.append(turn(account, t + step // 2 + i, f, usd))
        t += step
        p += points_per_step
        reads.append(reading(account, t, p, reset, window=window, scope_model=scope_model))
    return turns, reads
