"""Small shared helpers: model families, version numbers, eras, and the one
frame -> Arrow conversion every table goes through (so a column's type is
decided by `schema.py`, never by pandas' inference)."""
from __future__ import annotations

import re
from datetime import datetime, timezone

import numpy as np
import pandas as pd
import pyarrow as pa

from arena.snapshot.schema import TABLES


def ms(iso: str) -> int:
    """'2026-09-24T17:50:00Z' or '2026-09-24' -> epoch ms UTC."""
    if len(iso) == 10:
        iso += "T00:00:00+00:00"
    return int(datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(timezone.utc).timestamp() * 1000)


def iso(t_ms: int | None) -> str | None:
    if t_ms is None:
        return None
    return datetime.fromtimestamp(t_ms / 1000, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


FAMILIES = ("fable", "opus", "sonnet", "haiku")


def model_family(model: str | None) -> str:
    if not isinstance(model, str) or not model:
        return "other"
    m = model.lower()
    for f in FAMILIES:
        if f in m:
            return f
    return "other"


_VER = re.compile(r"^(\d+)\.(\d+)\.(\d+)")


def version_num(v: str | None) -> int | None:
    """'2.1.280' -> 2_001_280; sorts as semver, unlike the string."""
    if not isinstance(v, str) or not v:
        return None
    m = _VER.match(v)
    if not m:
        return None
    return int(m.group(1)) * 1_000_000 + int(m.group(2)) * 1_000 + int(m.group(3))


def canonical_model(model: str | None) -> str | None:
    """Catalog key for a model id: drop a trailing -YYYYMMDD and any
    bracketed suffix ("[1m]")."""
    if model is None:
        return None
    m = re.sub(r"\[.*?\]$", "", model)
    return re.sub(r"-\d{8}$", "", m)


# Collection eras (spec §2.3). Dates are boundaries of how Pacer and Claude
# Code collected data, documented in docs/snapshot-spec.md.
OUTPUT_CLEAN_FROM = ms("2026-07-03")
SUSPECT_FROM, SUSPECT_TO = ms("2026-08-25"), ms("2026-09-16")
VERIFIED_FROM, VERIFIED_TO = ms("2026-09-23"), ms("2026-10-22")
# Claude Code versions whose subagent transcripts lose the finished copy.
VERIFIED_DEFECT = (version_num("2.1.280"), version_num("2.1.306"))
SUSPECT_DEFECT = [(version_num("2.1.245"), version_num("2.1.246")),
                  (version_num("2.1.252"), version_num("2.1.258")),
                  (version_num("2.1.260"), version_num("2.1.268"))]
DEFECT_TINY_OUTPUT = 16          # defect copies carry 1–16 output tokens


def in_verified_defect(vn) -> np.ndarray:
    v = pd.array(vn, dtype="Int64")
    return np.asarray(((v >= VERIFIED_DEFECT[0]) & (v <= VERIFIED_DEFECT[1])).fillna(False), dtype=bool)


def in_suspect_defect(vn) -> np.ndarray:
    v = pd.array(vn, dtype="Int64")
    out = np.zeros(len(v), dtype=bool)
    for lo, hi in SUSPECT_DEFECT:
        out |= np.asarray(((v >= lo) & (v <= hi)).fillna(False), dtype=bool)
    return out


def era_output_clean(t_ms: np.ndarray) -> np.ndarray:
    t = np.asarray(t_ms, dtype=np.int64)
    return ((t >= OUTPUT_CLEAN_FROM) & (t < SUSPECT_FROM)) | ((t >= SUSPECT_TO) & (t < VERIFIED_FROM)) | (t >= VERIFIED_TO)


# ---------------------------------------------------------------------------
# frame -> Arrow
# ---------------------------------------------------------------------------

def _column(values, typ: pa.DataType) -> pa.Array:
    s = values if isinstance(values, pd.Series) else pd.Series(values)
    if pa.types.is_timestamp(typ) or (pa.types.is_integer(typ) and not pa.types.is_unsigned_integer(typ)):
        v = pd.array(s, dtype="Int64")
        mask = np.asarray(v.isna(), dtype=bool)
        data = np.asarray(v.fillna(0).to_numpy(dtype=np.int64))
        base = pa.array(data, type=pa.int64(), mask=mask)
        return base.cast(typ) if not pa.types.is_timestamp(typ) else base.cast(pa.timestamp("ms")).cast(typ)
    if pa.types.is_unsigned_integer(typ):
        if s.dtype == np.uint64:
            return pa.array(s.to_numpy(), type=typ)
        obj = s.astype(object)
        return pa.array([None if (x is None or x is pd.NA or (isinstance(x, float) and np.isnan(x))) else int(x)
                         for x in obj], type=typ)
    if pa.types.is_floating(typ):
        v = pd.array(s, dtype="Float64")
        mask = np.asarray(v.isna(), dtype=bool)
        return pa.array(np.asarray(v.fillna(0.0).to_numpy(dtype=np.float64)), type=typ, mask=mask)
    if pa.types.is_boolean(typ):
        obj = s.astype(object)
        return pa.array([None if (x is None or x is pd.NA or (isinstance(x, float) and np.isnan(x))) else bool(x)
                         for x in obj], type=typ)
    if pa.types.is_string(typ):
        obj = s.astype(object)
        return pa.array([None if (x is None or x is pd.NA or (isinstance(x, float) and np.isnan(x))) else str(x)
                         for x in obj], type=typ)
    if pa.types.is_list(typ):
        return pa.array(list(s), type=typ)
    raise TypeError(f"unhandled type {typ}")


def to_arrow(name: str, df: pd.DataFrame, extra: list[tuple[str, pa.DataType]] | None = None) -> pa.Table:
    """The frame as table `name`, with exactly the schema's columns and
    types, in schema order. `extra` (name, type) columns are appended only
    for open_columns tables."""
    t = TABLES[name]
    if extra and not t.open_columns:
        raise ValueError(f"{name} has no open columns")
    arrays, fields = [], []
    for col, typ in list(t.columns) + list(extra or []):
        if col not in df.columns:
            raise KeyError(f"{name}: missing column {col}")
        arrays.append(_column(df[col].reset_index(drop=True), typ))
        fields.append(pa.field(col, typ))
    return pa.Table.from_arrays(arrays, schema=pa.schema(fields))
