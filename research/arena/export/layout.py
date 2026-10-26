"""Stage 5: tiers, files, manifest (CONTRACTS.md "Locations", spec §2.7).

    <snapshot>/train/<table>/…parquet      t_known <= T_train
    <snapshot>/holdout/<table>/…parquet    t_known >  T_train
    <snapshot>/labels/<table>.parquet      label tables, whole span

`turns`, `turn_revisions` and `meter_readings` are partitioned by month of
`t_known` (`<table>/month=YYYY-MM/part-0.parquet`), readings also by
`window=` first; every other data table is one file, `<tier>/<table>.parquet`
(the layout the synthetic generator writes too). Files hold exactly the
schema's columns: a partition key lives only in the path, so readers turn
hive partitioning off. A partitioned table with no rows in a tier gets one
empty `<table>/part-0.parquet`, so every reader sees every table.
Files are zstd, row groups of 100k, sorted by t_known, with statistics, so a
`t_known <= T` filter prunes whole files and row groups.
"""
from __future__ import annotations

import re
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq

from arena.snapshot.schema import DATA_TABLES, LABEL_TABLES

from . import clocks

PARTITIONED = {"turns": ("month",), "turn_revisions": ("month",), "meter_readings": ("window", "month")}
ROW_GROUP = 100_000
WEEK = 7 * clocks.DAY


def parse_tiers(spec: str) -> tuple[int, int]:
    """'3w,3w' -> (leaderboard_ms, lockbox_ms). Units: w, d, h."""
    out = []
    for part in spec.split(","):
        m = re.fullmatch(r"\s*(\d+)\s*([wdh])\s*", part)
        if not m:
            raise ValueError(f"bad tier length {part!r}; use e.g. 3w,3w")
        n, u = int(m.group(1)), m.group(2)
        out.append(n * {"w": WEEK, "d": clocks.DAY, "h": clocks.HOUR}[u])
    if len(out) != 2:
        raise ValueError("--tiers takes two lengths: leaderboard,lockbox")
    return out[0], out[1]


def tier_bounds(t_end: int, tiers: str, t_train: int | None = None) -> dict:
    """lockbox = the last `lockbox` before T_end, leaderboard = the
    `leaderboard` before that; T_train = start of the leaderboard (or as
    given, with the leaderboard following it)."""
    lb, lock = parse_tiers(tiers)
    if t_train is None:
        t_lb_end = t_end - lock
        t_train = t_lb_end - lb
    else:
        t_lb_end = min(t_train + lb, t_end)
    if not t_train < t_lb_end <= t_end:
        raise ValueError("tier boundaries out of order")
    return {"T_train": int(t_train), "T_leaderboard_end": int(t_lb_end), "T_end": int(t_end)}


def _month(ts: pa.ChunkedArray) -> np.ndarray:
    t = ts.cast(pa.int64()).to_numpy(zero_copy_only=False)
    return np.array([datetime.fromtimestamp(x / 1000, tz=timezone.utc).strftime("%Y-%m") for x in t], dtype=object) \
        if len(t) else np.array([], dtype=object)


def _write(t: pa.Table, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pq.write_table(t, path, compression="zstd", row_group_size=ROW_GROUP, write_statistics=True,
                   use_dictionary=True)


def _write_table(t: pa.Table, base: Path, name: str) -> int:
    keys = PARTITIONED.get(name)
    if not keys:
        _write(t, base / f"{name}.parquet")
        return 1
    if t.num_rows == 0:
        _write(t, base / name / "part-0.parquet")
        return 1
    month = _month(t["t_known"])
    parts = [month] if keys == ("month",) else [np.array(t["window_kind"].to_pylist(), dtype=object), month]
    combo = np.array(["/".join(f"{k}={v}" for k, v in zip(keys, vals)) for vals in zip(*parts)], dtype=object)
    files = 0
    for c in sorted(set(combo)):
        idx = np.flatnonzero(combo == c)
        _write(t.take(pa.array(idx)), base / name / c / "part-0.parquet")
        files += 1
    return files


def write_tables(root: Path, tables: dict[str, pa.Table], t_train: int, t_end: int, hasher=None) -> dict:
    """Split and write. Rows known after T_end are not part of the snapshot.
    Returns per-table row counts and content hashes by tier."""
    counts = {}
    ts = lambda v: pa.scalar(int(v), type=pa.int64()).cast(pa.timestamp("ms")).cast(pa.timestamp("ms", tz="UTC"))
    for name in DATA_TABLES:
        t = tables[name]
        t = t.filter(pc.less_equal(t["t_known"], ts(t_end)))
        tr = t.filter(pc.less_equal(t["t_known"], ts(t_train)))
        ho = t.filter(pc.greater(t["t_known"], ts(t_train)))
        _write_table(tr, root / "train", name)
        _write_table(ho, root / "holdout", name)
        counts[name] = {"rows": {"train": tr.num_rows, "holdout": ho.num_rows},
                        "sha256": {"train": hasher(tr), "holdout": hasher(ho)} if hasher else None,
                        "dropped_after_T_end": tables[name].num_rows - t.num_rows}
    for name in LABEL_TABLES:
        _write(tables[name], root / "labels" / f"{name}.parquet")
        counts[name] = {"rows": {"labels": tables[name].num_rows},
                        "sha256": {"labels": hasher(tables[name])} if hasher else None}
    return counts


def clip_to_end(tables: dict[str, pa.Table], t_end: int) -> dict[str, pa.Table]:
    """The data tables as the snapshot holds them (rows known by T_end), for
    the gates that compare files with memory."""
    ts = pa.scalar(int(t_end), type=pa.int64()).cast(pa.timestamp("ms")).cast(pa.timestamp("ms", tz="UTC"))
    return {n: (t.filter(pc.less_equal(t["t_known"], ts)) if n in DATA_TABLES else t) for n, t in tables.items()}
