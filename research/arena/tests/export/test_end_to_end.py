"""A tiny export, end to end, on synthetic inputs (conftest.py): every gate
passes, the layout and manifest follow the contract, no raw id or text
reaches a file, and a tampered archive leaves no snapshot behind."""
import json

import pyarrow as pa
import pyarrow.parquet as pq

from arena.snapshot.schema import DATA_TABLES, LABEL_TABLES, TABLES
from export_helpers import ACCT_X, ACCT_Y, ORG, PROJECT, SESSION_X, SESSION_Y, make_sources
from export import pipeline


def _export(paths, home, sid="fx"):
    return pipeline.run_export(sid, paths=paths, home=home, tiers="6h,6h")


def test_export_end_to_end(tmp_path, fixture_sources):
    home = tmp_path / "home"
    res = _export(fixture_sources, home)
    failed = [g for g in res.report["gates"] if not g["passed"]]
    assert res.ok, json.dumps(failed, default=str)[:2000]
    snap = home / "snapshots" / "fx"
    m = json.loads((snap / "manifest.json").read_text())
    for k in ("T_train", "T_leaderboard_end", "T_end"):
        assert isinstance(m[k], int) and isinstance(m[k + "_iso"], str)
    assert m["T_train"] < m["T_leaderboard_end"] < m["T_end"]
    assert set(m["tables"]) == set(TABLES)
    assert m["salt_id"] and len(m["salt_id"]) == 8
    assert all(m["validation"].values()) and len(m["validation"]) == 9

    turns = pq.read_table(snap / "train" / "turns", partitioning=None)
    hold = pq.read_table(snap / "holdout" / "turns", partitioning=None)
    assert turns.column_names == [c for c, _ in TABLES["turns"].columns]
    assert turns.num_rows + hold.num_rows == 49
    tk = turns["t_known"].cast(pa.int64()).to_pylist()
    assert max(tk) <= m["T_train"]
    allt = pa.concat_tables([turns, hold]).to_pandas()
    assert set(allt["account"]) == {"A1", "A2"}
    assert set(allt["t_known_src"]) == {"history", "modeled"}
    sub = allt[allt["is_subagent"] == True]  # noqa: E712
    assert len(sub) == 1 and sub["output_regime"].iloc[0] == "subagent_defect"
    assert not sub["output_reliable"].iloc[0]
    assert sub["output_imputed"].iloc[0] == 3 + 500 and sub["output_imputed_src"].iloc[0] == "cost_state"
    assert sub["output"].iloc[0] == 3                      # never overwritten
    assert (sub["output_imputed_t_known"] >= sub["t_known"]).all()
    assert (allt.loc[allt["output_regime"] == "finished", "output_reliable"]).all()
    assert (allt["output_imputed"].isna() == (allt["output_regime"] != "subagent_defect")).all()
    # revised_mask only counts revisions recorded by the row's t_known
    assert set(allt["revised_mask"].unique()) <= {0, 2}

    prices = pq.read_table(snap / "train" / "prices.parquet").to_pandas()
    assert prices["t_effective_to"].isna().all()
    cycles = pq.read_table(snap / "labels" / "cycles.parquet").to_pandas()
    assert (cycles["t_known_src"] == "unknown").all()
    for n in LABEL_TABLES:
        assert (snap / "labels" / f"{n}.parquet").exists()
        assert not (snap / "train" / f"{n}.parquet").exists()
    for n in DATA_TABLES:
        assert (snap / "train" / n).exists() or (snap / "train" / f"{n}.parquet").exists()

    # Nothing raw anywhere in the written bytes.
    blob = b"".join(p.read_bytes() for p in snap.rglob("*") if p.is_file())
    for raw in (ACCT_X, ACCT_Y, ORG, SESSION_X, SESSION_Y, PROJECT, "proj-alpha", "SECRET", "example.com", "/Users/"):
        assert raw.encode() not in blob, raw


def test_export_is_deterministic(tmp_path, fixture_sources):
    home = tmp_path / "home"
    a = _export(fixture_sources, home, "a").manifest
    b = _export(fixture_sources, home, "b").manifest
    assert {n: t["content_sha256"] for n, t in a["tables"].items()} == \
           {n: t["content_sha256"] for n, t in b["tables"].items()}


def test_failed_gate_leaves_no_snapshot(tmp_path):
    paths = make_sources(tmp_path, tamper_archive=True)
    home = tmp_path / "home"
    res = _export(paths, home)
    assert not res.ok
    gates = {g["gate"]: g["passed"] for g in res.report["gates"]}
    assert gates["2_store_vs_archive"] is False
    assert not (home / "snapshots" / "fx").exists()
    assert not any(p.name.startswith(".tmp-") for p in (home / "snapshots").iterdir())
    assert list((home / "export-failures").glob("fx-*.json"))


def test_gate7_reads_through_core_views(tmp_path, fixture_sources, monkeypatch):
    """Gate 7 slices the written files with the harness's own views. It passes
    on a good export, reports the cutoffs it checked, and fails when the views
    stop masking (a late value or a current-only column served too early)."""
    from arena.snapshot import views
    from export import validate

    home = tmp_path / "home"
    res = _export(fixture_sources, home)
    g7 = next(g for g in res.report["gates"] if g["gate"] == "7_point_in_time")
    assert g7["passed"] and g7["details"]["view_cutoffs"] >= 2
    snap = home / "snapshots" / "fx"
    m = json.loads((snap / "manifest.json").read_text())
    tables = {n: views.read_table([snap / "train", snap / "holdout"], n).to_arrow() for n in DATA_TABLES}
    cutoffs = [m["T_train"] - 3_600_000, m["T_train"], m["T_end"]]
    assert validate.core_view_problems(snap, tables, cutoffs, m["T_end"]) == []

    real = views._apply_masks

    def leaky(name, df, now, mode):          # serves every column unmasked
        return real(name, df, views.NEVER, mode)
    monkeypatch.setattr(views, "_apply_masks", leaky)
    lo = min(int(t["t_known"].cast(pa.int64()).to_numpy().min()) for t in tables.values() if t.num_rows)
    hourly = list(range(lo, m["T_end"] + 1, 4 * 3_600_000))
    problems = validate.core_view_problems(snap, tables, hourly, m["T_end"])
    assert any("before known" in p or "current-only" in p for p in problems), problems
