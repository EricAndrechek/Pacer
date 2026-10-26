"""Helpers for the kit/fm tests: tiny tables built to the snapshot schema,
and the places the real weights and snapshots live (tests that need them
skip when they are absent)."""
from __future__ import annotations

import os
from pathlib import Path

import pyarrow as pa
import polars as pl
import pytest

from arena.snapshot.schema import TABLES

MIN = 60_000
HOUR = 60 * MIN
DAY = 24 * HOUR
T0 = 1_780_000_000_000 - (1_780_000_000_000 % DAY)      # a midnight, UTC


def table(name: str, rows: list[dict]) -> pl.DataFrame:
    """Rows (times in epoch ms) as a frame with the table's schema."""
    spec = TABLES[name]
    cols = {}
    for col, typ in spec.columns:
        vals = [r.get(col) for r in rows]
        cols[col] = pa.array(vals, type=pa.int64()).cast(typ) if pa.types.is_timestamp(typ) else pa.array(vals, type=typ)
    return pl.from_arrow(pa.table(cols))


def reading(t, acct, kind, util, reset, scope_model=None, tk=None):
    return dict(t_event=t, t_known=t + 2000 if tk is None else tk, t_known_src="history", account=acct,
                window_kind=kind, scope_model=scope_model, identity=kind, util_pct=float(util), resets_at=reset,
                state="active" if reset is not None else "idle", source="oauth", origin="live")


def default_arena_home_with(snapshot_id: str) -> Path | None:
    """An ARENA_HOME holding the snapshot: $ARENA_HOME (other suites point it
    at their fixtures), else the default location."""
    for home in (os.environ.get("ARENA_HOME"), str(Path.home() / ".local/share/pacer-arena")):
        if home and (Path(home) / "snapshots" / snapshot_id / "manifest.json").is_file():
            return Path(home)
    return None


@pytest.fixture
def torch():
    return pytest.importorskip("torch", reason="the fm extra is not installed (uv sync --extra fm)")
