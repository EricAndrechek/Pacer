"""The visible tier as a snapshot of its own, so `arena test` runs unchanged
inside an agent's sandbox.

A full snapshot directory holds `holdout/` and `labels/` (the hidden tiers'
truth) and a manifest whose row counts, hashes and validation summary describe
the hidden period too. An agent may read none of that. The visible view is a
snapshot-shaped directory that holds only what was knowable by T_train:

    <ARENA_HOME>/visible/<id>/
      manifest.json      allow-listed keys; tier boundaries collapsed to T_train
      train/             a copy of the snapshot's train/, with late columns masked
      labels/<table>.parquet                         rows with t_known <= T_train

**Late columns.** A row of train/ is known by T_train, but some of its columns
hold a final value that became known later (a turn's imputed output, the end
of an account activation or a session, when the store recorded a backfilled
turn). Core lists them in `arena.snapshot.views.LATE_COLUMNS`, {table: {column:
known-time column}}; the harness masks them per cutoff. Agents read train/
directly too, so the copy nulls each such column, and its known-time column,
wherever the known time is null or after T_train; and it nulls the
current-only columns (`views.ALWAYS_NULL`) the harness never serves. Tables without late columns are copied as they are (an
APFS clone where possible: no extra space).

Each agent's own arena home (`<agent>/.arena-home`, its `$ARENA_HOME`) links
`snapshots/<id>` to this view and keeps writable `cache/` and `results/`, so the
harness never needs to write anywhere the sandbox forbids.
"""
from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq

from arena.snapshot.views import ALWAYS_NULL, LATE_COLUMNS
from fleet.paths import FleetPaths

# Manifest keys an agent may see. Everything else (source fingerprints, the
# validation summary, per-table counts and hashes over the hidden period) is
# dropped: each of those says something about the hidden weeks.
MANIFEST_KEEP = (
    "id", "snapshot_id", "schema_version", "created_at", "frozen", "T_train",
    "salt_id", "lag_model", "lag_model_params", "exporter_version", "harness_version",
)
TIER_KEYS = ("T_leaderboard_end", "T_end")



def late_columns() -> dict[str, dict[str, str]]:
    """Core's map, the one the harness masks by: one definition, so the
    agents' copy and the runner's views can never disagree."""
    return LATE_COLUMNS


def masked_tables() -> set[str]:
    return set(LATE_COLUMNS) | set(ALWAYS_NULL)


def _millis(col: pa.ChunkedArray) -> pa.ChunkedArray:
    if pa.types.is_timestamp(col.type):
        return pc.cast(pc.cast(col, pa.timestamp("ms", tz=col.type.tz)), pa.int64())
    return pc.cast(col, pa.int64())


def null_current_only(table: pa.Table, cols: tuple[str, ...]) -> pa.Table:
    """Current-only attributes (`views.ALWAYS_NULL`, e.g. accounts.plan_current)
    are today's values, never history: the harness never serves them, so the
    agents' copy holds none either."""
    for name in cols:
        if name in table.column_names:
            col = table[name]
            table = table.set_column(table.column_names.index(name), name,
                                     pa.nulls(table.num_rows, type=col.type))
    return table


def mask_late(table: pa.Table, late: dict[str, str], t_train_ms: int) -> pa.Table:
    """Null every late column, and its known-time column, on rows whose known
    time is null or after T_train. A column mapped to itself is hidden while
    it lies after T_train."""
    groups: dict[str, list[str]] = {}
    for col, kt in late.items():
        groups.setdefault(kt, []).append(col)
    for kt, cols in groups.items():
        if kt not in table.column_names:
            continue
        known = _millis(table[kt])
        hide = pc.fill_null(pc.greater(known, t_train_ms), True)
        for name in dict.fromkeys(cols + [kt]):
            if name not in table.column_names:
                continue
            col = table[name]
            masked = pc.if_else(hide, pa.scalar(None, type=col.type), col)
            table = table.set_column(table.column_names.index(name), name, masked)
    return table


def _clone(src: Path, dst: Path) -> None:
    """APFS clone (copy-on-write) when possible, else a plain copy."""
    if subprocess.run(["cp", "-c", str(src), str(dst)], capture_output=True).returncode != 0:
        shutil.copy2(src, dst)


def copy_train(src: Path, dst: Path, t_train_ms: int) -> dict[str, int]:
    """Copy train/ to the view, masking late columns. Returns rows masked per table."""
    late = late_columns()
    masked: dict[str, int] = {}
    for f in sorted(src.rglob("*")):
        if not f.is_file() or f.is_symlink():
            continue
        rel = f.relative_to(src)
        out = dst / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        table_name = rel.parts[0].removesuffix(".parquet")
        if f.suffix == ".parquet" and table_name in masked_tables():
            t = pq.read_table(f)
            cols = [*late.get(table_name, {}), *ALWAYS_NULL.get(table_name, ())]
            before = sum(t[c].null_count for c in cols if c in t.column_names)
            t = mask_late(t, late.get(table_name, {}), t_train_ms)
            t = null_current_only(t, ALWAYS_NULL.get(table_name, ()))
            after = sum(t[c].null_count for c in cols if c in t.column_names)
            masked[table_name] = masked.get(table_name, 0) + after - before
            pq.write_table(t, out, compression="zstd")
        else:
            _clone(f, out)
    return masked


def to_millis(value) -> int:
    """T_train as epoch ms, from epoch ms, epoch s or an ISO string."""
    if isinstance(value, (int, float)):
        return int(value if value > 1e11 else value * 1000)
    dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1000)


def sanitize_manifest(manifest: dict, train_rows: dict[str, int]) -> dict:
    if "T_train" not in manifest:
        raise ValueError("manifest has no T_train")
    out = {k: manifest[k] for k in MANIFEST_KEEP if k in manifest}
    for k in TIER_KEYS:
        out[k] = manifest["T_train"]
    out["visible_only"] = True
    out["train_rows"] = dict(sorted(train_rows.items()))
    return out


def _train_rows(train: Path) -> dict[str, int]:
    rows: dict[str, int] = {}
    for f in sorted(train.rglob("*.parquet")):
        table = f.relative_to(train).parts[0].removesuffix(".parquet")
        rows[table] = rows.get(table, 0) + pq.ParquetFile(f).metadata.num_rows
    return rows


def _filter_labels(src: Path, dst: Path, t_train_ms: int) -> dict[str, int]:
    """Copy every label parquet keeping rows known by T_train. A table without
    t_known is dropped rather than copied whole: we cannot tell what it reveals."""
    kept: dict[str, int] = {}
    if not src.is_dir():
        return kept
    for f in sorted(src.rglob("*.parquet")):
        table = pq.read_table(f)
        if "t_known" not in table.column_names:
            continue
        col = table["t_known"]
        ms = pc.cast(col, "int64") if str(col.type).startswith("timestamp") else col
        table = table.filter(pc.less_equal(ms, t_train_ms))
        out = dst / f.relative_to(src)
        out.parent.mkdir(parents=True, exist_ok=True)
        pq.write_table(table, out)
        kept[str(f.relative_to(src))] = table.num_rows
    return kept


def publish_visible_view(paths: FleetPaths, snapshot_id: str, *, force: bool = False) -> Path:
    """Build (or keep) `<ARENA_HOME>/visible/<id>/`. Idempotent; read-only after."""
    snap = paths.home / "snapshots" / snapshot_id
    view = paths.visible_view(snapshot_id)
    manifest_path = snap / "manifest.json"
    if not manifest_path.is_file():
        raise FileNotFoundError(f"no manifest at {manifest_path}")
    if view.exists() and not force:
        return view
    if view.exists():
        _make_writable(view)
        _rmtree(view)
    view.mkdir(parents=True)
    manifest = json.loads(manifest_path.read_text())
    t_train = to_millis(manifest["T_train"])
    copy_train(snap / "train", view / "train", t_train)
    (view / "manifest.json").write_text(json.dumps(sanitize_manifest(manifest, _train_rows(view / "train")), indent=2) + "\n")
    _filter_labels(snap / "labels", view / "labels", t_train)
    _make_read_only(view)
    return view


def link_agent_home(agent_dir: Path, view: Path, snapshot_id: str) -> Path:
    """`<agent>/.arena-home`: snapshots/<id> -> the visible view, plus writable
    cache/ and results/ for the harness's own use."""
    home = agent_dir / ".arena-home"
    (home / "snapshots").mkdir(parents=True, exist_ok=True)
    (home / "cache").mkdir(exist_ok=True)
    (home / "results").mkdir(exist_ok=True)
    link = home / "snapshots" / snapshot_id
    if link.is_symlink() or link.exists():
        link.unlink()
    link.symlink_to(view, target_is_directory=True)
    return home


def _make_read_only(root: Path) -> None:
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for f in filenames:
            p = Path(dirpath) / f
            if not p.is_symlink():
                p.chmod(0o444)
        Path(dirpath).chmod(0o555)


def _make_writable(root: Path) -> None:
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        Path(dirpath).chmod(0o755)
        for f in filenames:
            p = Path(dirpath) / f
            if not p.is_symlink():
                p.chmod(0o644)


def _rmtree(root: Path) -> None:
    import shutil

    def onexc(func, path, exc):
        os.chmod(path, stat.S_IWUSR | stat.S_IRUSR | stat.S_IXUSR)
        func(path)

    shutil.rmtree(root, onexc=onexc)
