"""A synthetic snapshot is laid out and typed exactly like a real one."""
from __future__ import annotations

import pyarrow.parquet as pq
import polars as pl

from arena.snapshot.schema import (OUTPUT_REGIMES, T_KNOWN_SOURCES, TABLES, WINDOW_KINDS, Where)
from synth.writer import PARTITIONED
from synth_testutil import read_table


def _files(snap, name):
    spec = TABLES[name]
    if spec.where is Where.LABELS:
        return [snap / "labels" / f"{name}.parquet"]
    out = []
    for sp in ("train", "holdout"):
        if name in PARTITIONED:
            out += sorted((snap / sp / name).glob("**/*.parquet"))
        else:
            out.append(snap / sp / f"{name}.parquet")
    return out


def test_every_table_has_exactly_the_pinned_schema(snap):
    for name, spec in TABLES.items():
        files = _files(snap, name)
        assert files, name
        for f in files:
            assert f.exists(), f
            assert pq.read_schema(f).remove_metadata() == spec.arrow_schema(), f


def test_layout_and_manifest(snap, manifest):
    assert (snap / "validation" / "report.json").exists()
    assert (snap / "truth" / "params.json").exists() and (snap / "truth" / "meter_true.parquet").exists()
    for k in ("snapshot_id", "created_at", "frozen", "T_train", "T_leaderboard_end", "T_end", "salt_id",
              "tables", "lag_model", "validation", "source_fingerprints"):
        assert k in manifest, k
    assert manifest["synthetic"] is True and manifest["validation"]["ok"] is True
    assert manifest["T_start"] < manifest["T_train"] < manifest["T_leaderboard_end"] < manifest["T_end"]
    assert set(manifest["tables"]) == set(TABLES)
    for name, info in manifest["tables"].items():
        if TABLES[name].where is Where.LABELS:
            assert pq.read_metadata(snap / "labels" / f"{name}.parquet").num_rows == info["rows"]["labels"]
            continue
        for sp in ("train", "holdout"):
            n = sum(pq.read_metadata(f).num_rows for f in _files(snap, name) if f"/{sp}/" in str(f))
            assert n == info["rows"][sp], (name, sp)


def test_split_by_t_known(snap, manifest):
    tt, te = manifest["T_train"], manifest["T_end"]
    for name, spec in TABLES.items():
        if spec.where is Where.LABELS:
            continue
        for sp in ("train", "holdout"):
            df = read_table(snap, name, splits=(sp,))
            if df.height == 0:
                continue
            k = df["t_known"].dt.epoch("ms")
            if sp == "train":
                assert k.max() <= tt, name
            else:
                assert k.min() > tt and k.max() <= te, name
            assert df["t_known"].null_count() == 0, name


def test_partitions_match_their_rows(snap):
    for name in PARTITIONED:
        for f in (snap / "train" / name).glob("**/*.parquet"):
            df = pl.read_parquet(f, hive_partitioning=False)
            month = next(p for p in f.parts if p.startswith("month=")).split("=")[1]
            assert (df["t_known"].dt.strftime("%Y-%m") == month).all(), f
            if name == "meter_readings":
                window = next(p for p in f.parts if p.startswith("window=")).split("=")[1]
                assert (df["window_kind"] == window).all(), f
            k = df["t_known"].dt.epoch("ms").to_numpy()
            assert (k[1:] >= k[:-1]).all(), f"{f} not sorted by t_known"


def test_vocabularies(snap):
    t = read_table(snap, "turns")
    assert set(t["model_family"].unique()) <= {"fable", "opus", "sonnet", "haiku", "other"}
    assert set(t["output_regime"].unique()) <= set(OUTPUT_REGIMES)
    assert set(t["attribution_src"].unique()) <= {"manual_range", "observed", "credential", "retro_reassign",
                                                   "desktop_restamp"}
    assert set(t["agent_kind"].drop_nulls().unique()) <= {"main", "fork", "builtin", "custom"}
    assert t["call_id"].n_unique() == t.height
    r = read_table(snap, "meter_readings")
    assert set(r["window_kind"].unique()) <= set(WINDOW_KINDS)
    assert set(r["state"].unique()) == {"active", "idle"}
    assert set(r["source"].unique()) <= {"oauth", "cswap", "switcher"}
    assert set(r["origin"].unique()) <= {"live", "archive"}
    assert set(r.filter(pl.col("window_kind") == "weekly_scoped")["scope_model"].unique()) == {"Fable"}
    assert r.filter(pl.col("window_kind") != "weekly_scoped")["scope_model"].null_count() == \
        r.filter(pl.col("window_kind") != "weekly_scoped").height
    rv = read_table(snap, "turn_revisions")
    assert set(rv["kind"].unique()) <= {"insert", "output_upgrade", "account_restamp", "project_rewrite",
                                         "geo_speed_patch"}
    ae = read_table(snap, "account_events")
    assert set(ae["kind"].unique()) <= {"activation", "switch", "rotation_tick"}
    assert set(ae["row_scope"].unique()) <= {"M", "S"}
    p = read_table(snap, "prompts")
    assert set(p["origin"].unique()) <= {"human", "tool_result", "scheduled", "task_notification", "compact",
                                         "unknown"}
    for name, spec in TABLES.items():
        if spec.where is Where.DATA:
            df = read_table(snap, name)
            if df.height:
                assert set(df["t_known_src"].unique()) <= set(T_KNOWN_SOURCES), name
    acc = read_table(snap, "accounts")["account"].to_list()
    assert all(a.startswith("A") and a[1:].isdigit() for a in acc)


def test_stress_features_are_present(snap, world):
    """The traps a real snapshot has, each at least once."""
    r = read_table(snap, "meter_readings")
    assert r.filter((pl.col("state") == "idle") & pl.col("resets_at").is_null()).height > 0
    assert r.filter(pl.col("backwards_pp") > 0).height > 0
    assert r.filter(pl.col("dup_group").is_not_null() & (pl.col("window_kind") == "session")).height > 0
    assert r.filter(pl.col("source") == "cswap").height > 0
    assert read_table(snap, "limit_hits").height > 0
    ae = read_table(snap, "account_events")
    assert ae.filter(pl.col("kind") == "switch").height > 0
    assert ae.filter(pl.col("kind") == "rotation_tick").height > 0
    t = read_table(snap, "turns")
    assert t.filter(pl.col("output_regime") == "subagent_defect").height > 0
    assert t.filter(pl.col("output_regime") == "first_copy").height > 0
    assert t.filter(pl.col("attribution_src") == "retro_reassign").height > 0
    assert t["is_subagent"].null_count() > 0 and t["is_subagent"].drop_nulls().any()
    assert (t["cache_read"] > 0).mean() > 0.5
    rv = read_table(snap, "turn_revisions")
    assert {"insert", "output_upgrade", "geo_speed_patch"} <= set(rv["kind"].unique())
    assert read_table(snap, "app_alive").height > 3
    assert pl.read_parquet(snap / "labels" / "cycles.parquet")["censored"].any()
