"""Frames → Arrow tables with exactly the pinned schema (`schema.py`): every
column in order, with its type; columns the generator has no value for are
null. Helper columns (prefixed `_`) are dropped; any other unexpected column
is an error, so a typo can't silently produce a null column."""
from __future__ import annotations

import pyarrow as pa
import pyarrow.compute as pc
import polars as pl

from arena.snapshot.schema import TABLES


def to_arrow(name: str, df: pl.DataFrame) -> pa.Table:
    spec = TABLES[name]
    want = [c for c, _ in spec.columns]
    extra = [c for c in df.columns if c not in want and not c.startswith("_")]
    if extra:
        raise ValueError(f"{name}: columns not in the schema: {extra}")
    n = df.height
    arrays = []
    for col, typ in spec.columns:
        if col not in df.columns:
            arrays.append(pa.nulls(n, type=typ))
            continue
        a = df[col].to_arrow()
        if isinstance(a, pa.ChunkedArray):
            a = a.combine_chunks()
        if pa.types.is_timestamp(typ) and not pa.types.is_timestamp(a.type):
            a = pc.cast(a, pa.int64()).cast(typ) if not pa.types.is_null(a.type) else pa.nulls(n, typ)
        elif pa.types.is_null(a.type):
            a = pa.nulls(n, type=typ)
        else:
            a = a.cast(typ)
        arrays.append(a)
    return pa.Table.from_arrays(arrays, schema=spec.arrow_schema())
