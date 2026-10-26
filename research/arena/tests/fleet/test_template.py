"""The template repo: one fresh commit, the harness without the fleet's own
machinery, AGENTS.md, earlier models with hashes, aggregate scores only, and
never any data."""
import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

from fleet import template as tmpl
from fleet.visible import publish_visible_view


def _files(root: Path) -> set[str]:
    return {str(p.relative_to(root)) for p in root.rglob("*") if p.is_file() and ".git" not in p.parts}


def test_template_contents(paths, snapshot):
    publish_visible_view(paths, "snap1")
    t = tmpl.build_template(paths, 1, "snap1")
    files = _files(t)
    assert "AGENTS.md" in files and "MODELS.md" in files and "TEMPLATE.json" in files
    assert "pyproject.toml" in files and "uv.lock" in files and ".gitignore" in files
    assert "arena/types.py" in files and "arena/snapshot/schema.py" in files
    assert "models/example-linear/model.py" in files
    assert "arena/cli_fleet.py" not in files and "arena/cli_export.py" not in files
    assert not any(f.startswith(("fleet/", "docs/", "export/", "tests/")) for f in files)
    assert not {"DESIGN.md", "CONTRACTS.md"} & files
    assert not any(f.endswith((".parquet", ".duckdb", ".pyc")) for f in files)
    assert tmpl.scan_template(t, salt=(paths.home / "salt").read_bytes()) == []
    # the hidden marker and the snapshot's paths are nowhere in it
    blob = b"".join(p.read_bytes() for p in t.rglob("*") if p.is_file() and ".git" not in p.parts)
    assert b"HIDDEN-MARKER" not in blob and str(paths.home).encode() not in blob

    agents = (t / "AGENTS.md").read_text()
    for needed in ("arena test", "$ARENA_EVAL", "REPORT.md", "UPSTREAM.md", "Copy, don't modify",
                   "disqualifies", "children", "deps", "weights", "snap1", "2026-01-01", "`turns`",
                   "`meter_readings`", "meter.five_hour"):
        assert needed in agents, needed
    assert "{{" not in agents
    assert "cycles" not in agents.split("## The data")[1].split("## Two ways")[0]   # label tables not advertised

    info = tmpl.template_info(t)
    assert info["snapshot"] == "snap1" and set(info["models"]) == {"example-linear"}
    assert len(info["models"]["example-linear"]) == 64


def test_template_is_one_fresh_commit(paths, snapshot):
    t = tmpl.build_template(paths, 1, "snap1", t_train="2026-01-01")
    log = tmpl.git("log", "--format=%an <%ae>|%s", cwd=t).stdout.strip().splitlines()
    assert log == ["arena coordinator <coordinator@arena.invalid>|arena template, generation 1"]
    assert tmpl.git("status", "--porcelain", cwd=t).stdout == ""
    assert tmpl.git("remote", cwd=t).stdout.strip() == ""
    with pytest.raises(FileExistsError):
        tmpl.build_template(paths, 1, "snap1", t_train="x")


def test_earlier_models_and_their_scores(paths, snapshot, tmp_path):
    src = tmp_path / "src"
    for part in ("arena", "kit", "models/example-linear"):
        shutil.copytree(tmpl.ARENA_SRC / part, src / part, ignore=shutil.ignore_patterns("__pycache__"))
    for f in ("pyproject.toml", "uv.lock"):
        shutil.copy2(tmpl.ARENA_SRC / f, src / f)
    shutil.copytree(src / "models" / "example-linear", src / "models" / "port-a")
    (src / "models" / "port-a" / "model.toml").write_text('name = "port-a"\n')
    h = tmpl.model_hash(src / "models" / "port-a")

    import duckdb
    db = paths.home / "results" / "arena.duckdb"
    db.parent.mkdir(parents=True)
    con = duckdb.connect(str(db))
    con.execute((tmpl.ARENA_SRC / "arena" / "results_schema.sql").read_text())
    for run, tier in (("r-lb", "leaderboard"), ("r-lock", "lockbox")):
        con.execute("INSERT INTO runs VALUES (?, 'tournament', ?, 'snap1', 1, 'v', 'current_code', NULL, now(), NULL)",
                    [run, tier])
        for ep, v in ((1, 2.0), (2, 4.0)):
            con.execute("INSERT INTO scores VALUES (?, ?, ?, now(), 'meter.five_hour:A1', 'meter.five_hour', 'crps', NULL, ?)",
                        [run, ep, h, v])
            con.execute("INSERT INTO scores VALUES (?, ?, ?, now(), 'meter.five_hour:A1', 'meter.five_hour', 'crps', 3600, 99)",
                        [run, ep, h])
    con.close()

    t = tmpl.build_template(paths, 2, "snap1", models=("port-a",), from_results="r-lb", src=src, t_train="x")
    assert (t / "models" / "port-a" / "model.py").is_file()
    assert h[:16] in (t / "MODELS.md").read_text()
    scores = (t / "SCORES.md").read_text()
    assert "| meter.five_hour | crps | 3.0 | 2 |" in scores and "99" not in scores
    with pytest.raises(ValueError, match="lockbox"):
        tmpl.build_template(paths, 3, "snap1", models=("port-a",), from_results="r-lock", src=src, t_train="x")
    t4 = tmpl.build_template(paths, 4, "snap1", models=("port-a",), from_results="r-lock", src=src,
                             t_train="x", allow_tiers=("lockbox",))
    assert "lockbox" in (t4 / "SCORES.md").read_text()
    with pytest.raises(ValueError, match="no model"):
        tmpl.build_template(paths, 5, "snap1", models=("ghost",), src=src, t_train="x")


def test_scan_refuses_data_and_ids(tmp_path):
    root = tmp_path / "t"
    (root / "models" / "x").mkdir(parents=True)
    (root / "ok.py").write_text("print('hi')\n")
    assert tmpl.scan_template(root) == []
    (root / "models" / "x" / "data.parquet").write_bytes(b"PAR1")
    (root / "holdout").mkdir()
    (root / "acct.txt").write_text("owner 123e4567-e89b-12d3-a456-426614174000\n")
    (root / "salted.txt").write_bytes(b"xx" + b"S" * 32)
    os.symlink("/etc/hosts", root / "link")
    problems = "\n".join(tmpl.scan_template(root, salt=b"S" * 32))
    for frag in ("data file", "forbidden name: holdout", "UUID", "salt", "symlink"):
        assert frag in problems, frag


def test_protect_clone_makes_harness_read_only(paths, snapshot, tmp_path):
    t = tmpl.build_template(paths, 1, "snap1", t_train="x")
    clone = tmp_path / "clone"
    tmpl.git("clone", "-q", str(t), str(clone), cwd=tmp_path)
    tmpl.protect_clone(clone, ["example-linear"])
    assert not os.access(clone / "arena" / "types.py", os.W_OK)
    assert not os.access(clone / "arena", os.W_OK)
    assert not os.access(clone / "models" / "example-linear" / "model.py", os.W_OK)
    assert not os.access(clone / "AGENTS.md", os.W_OK)
    assert os.access(clone / "models", os.W_OK)              # new models go here
    assert tmpl.git("status", "--porcelain", cwd=clone).stdout == ""


def test_visible_view_holds_only_the_visible_tier(paths, snapshot):
    view = publish_visible_view(paths, "snap1")
    m = json.loads((view / "manifest.json").read_text())
    assert m["T_train"] == m["T_end"] == m["T_leaderboard_end"]
    assert m["visible_only"] is True and m["train_rows"] == {"turns": 1}
    assert "source_fingerprints" not in m and "row_counts" not in m
    assert not (view / "train").is_symlink()
    raw = paths.home / "snapshots" / "snap1" / "train" / "turns" / "month=2025-12" / "p.parquet"
    assert (view / "train" / "turns" / "month=2025-12" / "p.parquet").read_bytes() != b""
    assert not (view / "holdout").exists() and raw.exists()
    import pyarrow.parquet as pq
    labels = pq.read_table(view / "labels" / "cycles.parquet")
    assert labels["cycle_id"].to_pylist() == ["a"]
    assert not os.access(view / "manifest.json", os.W_OK)


def test_visible_train_masks_late_columns(paths):
    """A column whose final value became known after T_train must not show in
    the agents' copy, nor its known-time column (core's LATE_COLUMNS rule)."""
    import pyarrow as pa
    import pyarrow.parquet as pq
    from fleet_helpers import T_TRAIN, make_snapshot
    from arena.snapshot.views import LATE_COLUMNS
    from fleet.visible import late_columns

    snap = make_snapshot(paths.home)
    ts = pa.timestamp("ms", tz="UTC")
    early, late = T_TRAIN - 1000, T_TRAIN + 1000
    turns = snap / "train" / "turns" / "month=2025-12" / "p.parquet"
    pq.write_table(pa.table({
        "t_known": pa.array([early] * 3, ts),
        "output": [10, 20, 30],
        "output_imputed": [1.0, 2.0, 3.0],
        "output_imputed_src": ["a", "b", "c"],
        "output_imputed_t_known": pa.array([early, late, None], ts),
        "t_first_recorded": pa.array([early, late, None], ts),      # backfilled: recorded after T_train
        "t_final_recorded": pa.array([early, early, late], ts),
    }), turns)
    pq.write_table(pa.table({"t_known": pa.array([early], ts), "account": ["A1"], "plan": ["max"],
                             "plan_current": ["pro"], "tier_current": ["t5"]}),
                   snap / "train" / "accounts.parquet")
    pq.write_table(pa.table({"t_known": pa.array([early, early], ts), "account": ["A1", "A2"],
                             "t_end": pa.array([early, late], ts), "t_end_known": pa.array([early, late], ts)}),
                   snap / "train" / "account_events.parquet")
    pq.write_table(pa.table({"t_known": pa.array([early, early, early], ts),
                             "t_end": pa.array([early, late, None], ts)}), snap / "train" / "sessions.parquet")
    pq.write_table(pa.table({"t_known": pa.array([early], ts), "model": ["m"]}), snap / "train" / "prices.parquet")
    view = publish_visible_view(paths, "snap1")
    t = pq.read_table(view / "train" / "turns" / "month=2025-12" / "p.parquet").to_pydict()
    assert t["output_imputed"] == [1.0, None, None] and t["output_imputed_src"] == ["a", None, None]
    assert t["output_imputed_t_known"][1:] == [None, None] and t["output"] == [10, 20, 30]
    assert t["t_first_recorded"][1:] == [None, None] and t["t_first_recorded"][0] is not None
    assert t["t_final_recorded"][:2] != [None, None] and t["t_final_recorded"][2] is None
    acc = pq.read_table(view / "train" / "accounts.parquet").to_pydict()
    assert acc["plan_current"] == [None] and acc["tier_current"] == [None] and acc["plan"] == ["max"]
    a = pq.read_table(view / "train" / "account_events.parquet").to_pydict()
    assert a["t_end"][1] is None and a["t_end_known"][1] is None and a["t_end"][0] is not None
    assert pq.read_table(view / "train" / "sessions.parquet")["t_end"].to_pylist()[1:] == [None, None]
    assert (view / "train" / "prices.parquet").read_bytes() == (snap / "train" / "prices.parquet").read_bytes()
    assert late_columns() is LATE_COLUMNS
