"""Write a simulated world as a snapshot, in the same layout a real export has
(CONTRACTS.md "Locations"):

    <ARENA_HOME>/snapshots/<id>/
      manifest.json
      train/   turns/month=YYYY-MM/part-0.parquet          t_known <= T_train
               turn_revisions/month=YYYY-MM/part-0.parquet
               meter_readings/window=<kind>/month=YYYY-MM/part-0.parquet
               <small table>.parquet                       one file each, always written
      holdout/ the same tree for T_train < t_known <= T_end
      labels/  cycles.parquet, predictions_of_record.parquet, eval_of_record.parquet
      validation/report.json
      truth/   params.json, meter_true.parquet, cycles_true.parquet,
               spend_true.parquet, unobserved.parquet       (synthetic only)

Partition files hold exactly the schema's columns; `month=`/`window=` live
only in the path. Rows are sorted by t_known; zstd, row groups of 100k.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import polars as pl
import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq

from arena.snapshot.schema import SCHEMA_VERSION, TABLES, Where

from .config import WINDOW_MS, ms_to_iso
from .tables import to_arrow
from .world import GENERATOR_VERSION, World

PARTITIONED = ("turns", "turn_revisions", "meter_readings")
JITTER_TOL_MS = 5_000


def _write(table: pa.Table, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pq.write_table(table, path, compression="zstd", row_group_size=100_000, write_statistics=True)


def table_hash(table: pa.Table) -> str:
    sink = pa.BufferOutputStream()
    with pa.ipc.new_stream(sink, table.schema) as w:
        w.write_table(table)
    return hashlib.sha256(sink.getvalue().to_pybytes()).hexdigest()


def _sorted(t: pa.Table) -> pa.Table:
    """Rows by t_known, then t_event, then every other scalar column: one
    canonical order, whatever order the rows were built in."""
    if t.num_rows == 0 or "t_known" not in t.column_names:
        return t
    keys = ["t_known", "t_event"] + [f.name for f in t.schema
                                     if f.name not in ("t_known", "t_event") and not pa.types.is_list(f.type)]
    return t.take(pc.sort_indices(t, sort_keys=[(k, "ascending") for k in keys]))


def _months(t: pa.Table) -> np.ndarray:
    """YYYY-MM of each row's t_known (UTC)."""
    ms = pc.cast(t.column("t_known"), pa.int64()).to_numpy(zero_copy_only=False)
    d = ms.astype("datetime64[ms]").astype("datetime64[M]")
    return np.datetime_as_string(d, unit="M").astype(object)


def _write_split(root: Path, name: str, t: pa.Table) -> None:
    t = _sorted(t)
    if name not in PARTITIONED:
        _write(t, root / f"{name}.parquet")
        return
    if t.num_rows == 0:
        return
    months = _months(t)
    keys = [("", None)]
    if name == "meter_readings":
        wk = t.column("window_kind").to_numpy(zero_copy_only=False).astype(object)
        keys = [(f"window={k}", k) for k in sorted(set(wk))]
    for sub, kval in keys:
        sel_k = np.ones(t.num_rows, bool) if kval is None else (wk == kval)
        for mo in sorted(set(months[sel_k])):
            sel = sel_k & (months == mo)
            part = t.filter(pa.array(sel))
            d = root / name
            if sub:
                d = d / sub
            _write(part, d / f"month={mo}" / "part-0.parquet")


def validate(world: World, arrow: dict[str, pa.Table]) -> dict:
    """The exporter's gates, as far as they apply to synthetic data."""
    b = world.bounds
    checks: dict[str, dict] = {}
    # Schema.
    bad = [n for n, t in arrow.items() if t.schema != TABLES[n].arrow_schema()]
    checks["schema"] = {"ok": not bad, "tables_wrong": bad}
    # Readings.
    rd = world.tables["meter_readings"]
    idle_nonzero = rd.filter((pl.col("state") == "idle") & (pl.col("util_pct") != 0)).height
    drops = rd.filter(pl.col("backwards_pp") > 1).height
    jit = rd.filter(pl.col("state") == "active").group_by(["account", "window_kind", "_cyc", "source"]).agg(
        (pl.col("resets_at").max() - pl.col("resets_at").min()).alias("spread"))
    p999 = float(jit["spread"].quantile(0.999) or 0) if jit.height else 0.0
    ints = rd.filter(pl.col("util_pct") != pl.col("util_pct").round()).height
    over = rd.filter(pl.col("util_pct") > 100).height
    checks["readings"] = {"ok": idle_nonzero == 0 and ints == 0 and over == 0 and p999 <= JITTER_TOL_MS,
                          "idle_nonzero": idle_nonzero, "drops_over_1pp": drops, "non_integer": ints,
                          "over_100": over, "reset_spread_ms_p999": p999}
    # Cycles: no overlap, resets strictly increasing, length == window.
    cy = world.tables["cycles"].sort(["account", "window_kind", "scope_model", "reset_at"], nulls_last=False)
    overl = cy.with_columns(pl.col("reset_at").shift(1).over(["account", "window_kind", "scope_model"]).alias("_prev"))
    win = cy["window_kind"].replace_strict(WINDOW_MS, return_dtype=pl.Int64)
    # Back-to-back cycles: `start` is reset - window, so it carries the
    # resets' millisecond jitter; overlap means more than that.
    n_overlap = overl.filter(pl.col("_prev").is_not_null()
                             & (pl.col("start") < pl.col("_prev") - JITTER_TOL_MS)).height
    n_too_long = cy.filter((pl.col("last_t") - pl.col("first_t")) > win + 120_000).height
    checks["cycles"] = {"ok": n_overlap == 0 and n_too_long == 0, "n": cy.height,
                        "overlapping": n_overlap, "longer_than_window": n_too_long}
    # Prices: every turn's model has a published rate by snapshot end.
    pr = world.tables["prices"]
    models_priced = set(pr["model"].unique().to_list())
    unpriced = world.tables["turns"].filter(~pl.col("model").is_in(list(models_priced))).height
    launch_lag = 0
    tdf = world.tables["turns"].select("model", "t_known")
    first_known = pr.filter(pl.col("tier_threshold").is_null()).group_by("model").agg(pl.col("t_known").min())
    launch_lag = tdf.join(first_known, on="model").filter(pl.col("t_known") < pl.col("t_known_right")).height
    checks["prices"] = {"ok": unpriced == 0, "turns_without_rate": unpriced,
                        "turns_before_rate_known (launch lag)": launch_lag}
    # Point in time: nothing in a data table that was known only after T_end.
    late = {}
    for n, t in arrow.items():
        if TABLES[n].where is Where.LABELS or t.num_rows == 0:
            continue
        k = int(pc.sum(pc.greater(pc.cast(t.column("t_known"), pa.int64()), b["T_end"])).as_py() or 0)
        nulls = t.column("t_known").null_count
        if k or nulls:
            late[n] = {"after_T_end": k, "null_t_known": nulls}
    checks["point_in_time"] = {"ok": not late, "tables": late}
    # Leak scan.
    hits = 0
    for n, t in arrow.items():
        for c, typ in TABLES[n].columns:
            if pa.types.is_string(typ):
                col = t.column(c)
                for pat in ("/Users/", "@"):
                    hits += int(pc.sum(pc.match_substring(col, pat)).as_py() or 0)
    checks["leak_scan"] = {"ok": hits == 0, "hits": hits}
    return {"ok": all(c["ok"] for c in checks.values()), "checks": checks}


def write_snapshot(world: World, out_dir: Path, snapshot_id: str, force: bool = False) -> Path:
    out_dir = Path(out_dir)
    if out_dir.exists():
        if not force:
            raise FileExistsError(f"{out_dir} exists (use --force to replace it)")
    tmp = out_dir.with_name(out_dir.name + f".tmp-{os.getpid()}")
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True)
    b = world.bounds
    arrow = {n: to_arrow(n, world.tables[n]) for n in TABLES}
    report = validate(world, arrow)
    if not report["ok"]:
        shutil.rmtree(tmp)
        raise RuntimeError(f"synthetic snapshot failed validation: {json.dumps(report['checks'], indent=1)}")

    manifest_tables = {}
    for name, t in arrow.items():
        spec = TABLES[name]
        if spec.where is Where.LABELS:
            t = _sorted(t)
            _write(t, tmp / "labels" / f"{name}.parquet")
            manifest_tables[name] = {"where": "labels", "scope": spec.scope.value,
                                     "rows": {"labels": t.num_rows}, "sha256": {"labels": table_hash(t)}}
            continue
        tk = pc.cast(t.column("t_known"), pa.int64())
        train = t.filter(pc.less_equal(tk, b["T_train"]))
        hold = t.filter(pc.greater(tk, b["T_train"]))
        _write_split(tmp / "train", name, train)
        _write_split(tmp / "holdout", name, hold)
        manifest_tables[name] = {
            "where": "data", "scope": spec.scope.value,
            "partitioned": name in PARTITIONED,
            "rows": {"train": train.num_rows, "holdout": hold.num_rows},
            "sha256": {"train": table_hash(_sorted(train)), "holdout": table_hash(_sorted(hold))},
        }

    # Truth.
    (tmp / "truth").mkdir()
    for name, df in world.truth.items():
        tt = df.to_arrow()
        for i, f in enumerate(tt.schema):
            if f.name in ("t", "t_event", "cycle_start", "cycle_first_use", "reset_at", "start", "first_use", "hit_t"):
                tt = tt.set_column(i, f.name, pc.cast(tt.column(i), pa.int64()).cast(pa.timestamp("ms", tz="UTC")))
        _write(tt, tmp / "truth" / f"{name}.parquet")
    with open(tmp / "truth" / "params.json", "w") as fh:
        json.dump(world.params, fh, indent=1, sort_keys=True, default=_json_default)

    (tmp / "validation").mkdir()
    with open(tmp / "validation" / "report.json", "w") as fh:
        json.dump(report, fh, indent=1, sort_keys=True, default=_json_default)

    cfg_json = json.dumps(world.cfg.to_dict(), sort_keys=True, default=_json_default)
    manifest = {
        "snapshot_id": snapshot_id,
        "schema_version": SCHEMA_VERSION,
        "synthetic": True,
        "generator": GENERATOR_VERSION,
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "frozen": True,
        **{k: v for k, v in b.items()},
        **{f"{k}_iso": ms_to_iso(v) for k, v in b.items()},
        "tiers": {
            "visible": [b["T_start"], b["T_train"]],
            "leaderboard": [b["T_train"], b["T_leaderboard_end"]],
            "lockbox": [b["T_leaderboard_end"], b["T_end"]],
        },
        "source_fingerprints": {"kind": "synthetic", "seed": world.cfg.seed,
                                "config_sha256": hashlib.sha256(cfg_json.encode()).hexdigest()},
        "salt_id": None,
        "tables": manifest_tables,
        "content_sha256": hashlib.sha256(json.dumps(
            {n: v["sha256"] for n, v in manifest_tables.items()}, sort_keys=True).encode()).hexdigest(),
        "lag_model": json.loads(json.dumps(world.cfg.to_dict()["lags"])),
        "validation": {"ok": report["ok"], **{k: v["ok"] for k, v in report["checks"].items()}},
    }
    with open(tmp / "manifest.json", "w") as fh:
        json.dump(manifest, fh, indent=1, sort_keys=True, default=_json_default)
    if out_dir.exists():
        shutil.rmtree(out_dir)
    tmp.rename(out_dir)
    return out_dir


def _json_default(o):
    if isinstance(o, (np.integer,)):
        return int(o)
    if isinstance(o, (np.floating,)):
        return float(o)
    if isinstance(o, (np.bool_,)):
        return bool(o)
    if isinstance(o, tuple):
        return list(o)
    raise TypeError(f"not JSON serializable: {type(o)}")
