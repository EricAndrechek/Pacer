"""`arena runs merge`: two runs with the same tier, snapshot, seed, episode
count and --targets get the same episodes, and fold into one board."""
from pathlib import Path

import duckdb
import pytest

from arena.cli import main
from arena.cli_runs import MergeError, merge

SPY = Path(__file__).resolve().parents[1] / "core" / "models" / "spy"
TARGETS = "meter.five_hour,meter.seven_day,spend.hourly"


def _run(db: Path, models: str, seed: int = 3) -> str:
    rc = main(["run", "--models", models, "--tier", "lockbox", "--snapshot", "fx", "--episodes", "3",
               "--seed", str(seed), "--checkpoints", "3", "--targets", TARGETS, "--in-process",
               "--results-db", str(db)])
    assert rc == 0
    con = duckdb.connect(str(db), read_only=True)
    try:
        return con.execute("SELECT run_id FROM runs ORDER BY started_at DESC LIMIT 1").fetchone()[0]
    finally:
        con.close()


def test_merge_folds_identical_episodes(arena_home, tmp_path):
    main_db, other_db = tmp_path / "main" / "a.duckdb", tmp_path / "other" / "b.duckdb"
    ra = _run(main_db, "example-linear")
    rb = _run(other_db, str(SPY))
    assert merge(main_db, other_db, rb, ra, dry_run=True)["episodes"] == 3
    out = merge(main_db, other_db, rb, ra)
    assert out["scores"] > 0
    con = duckdb.connect(str(main_db), read_only=True)
    assert con.execute("SELECT count(DISTINCT model_hash) FROM scores WHERE run_id = ?", [ra]).fetchone()[0] == 2
    assert con.execute("SELECT count(*) FROM runs").fetchone()[0] == 1
    paths = [p for (p,) in con.execute("SELECT path FROM forecast_files WHERE run_id = ?", [ra]).fetchall()]
    assert len(paths) == 2 and all((main_db.parent / p).is_file() for p in paths)
    con.close()
    with pytest.raises(MergeError, match="already have scores"):
        merge(main_db, other_db, rb, ra)


def test_merge_refuses_different_episodes(arena_home, tmp_path):
    main_db, other_db = tmp_path / "a.duckdb", tmp_path / "o" / "b.duckdb"
    ra = _run(main_db, "example-linear", seed=3)
    rb = _run(other_db, str(SPY), seed=4)
    with pytest.raises(MergeError, match="differ"):
        merge(main_db, other_db, rb, ra)
