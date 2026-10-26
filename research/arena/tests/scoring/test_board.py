import argparse

import duckdb

from arena.cli_board import register
from test_compare import SCHEMA, make_db


def test_board_prints_leaderboard(tmp_path, capsys):
    src = make_db({"naive": 10.0, "good": 5.0})
    db = tmp_path / "arena.duckdb"
    con = duckdb.connect(str(db))
    con.execute(SCHEMA)
    con.close()
    src.execute(f"ATTACH '{db}' AS d")
    for t in ("models", "runs", "scores"):
        src.execute(f"INSERT INTO d.{t} SELECT * FROM {t}")
    src.execute("DETACH d")
    p = argparse.ArgumentParser()
    register(p.add_subparsers())
    args = p.parse_args(["board", "--db", str(db), "--baseline", "naive"])
    assert args.func(args) == 0
    out = capsys.readouterr().out
    assert "== meter.five_hour ==" in out
    good = next(l for l in out.splitlines() if l.startswith("good"))
    assert "tied for best" in good and "0.5" in good


def test_board_never_mixes_snapshots(tmp_path, capsys):
    """Two snapshots' runs (synthetic and real, say) get separate boards."""
    src = make_db({"naive": 10.0, "good": 5.0})
    src.execute("INSERT INTO runs SELECT 'r2', kind, tier, 'other', seed, harness_version, mode, requested_by, "
                "started_at, finished_at FROM runs WHERE run_id = 'r1'")
    src.execute("INSERT INTO scores SELECT 'r2', episode_id, model_hash, checkpoint_t, target_key, target, metric, "
                "lead_s, value * 100 FROM scores WHERE run_id = 'r1'")
    db = tmp_path / "arena.duckdb"
    con = duckdb.connect(str(db))
    con.execute(SCHEMA)
    con.close()
    src.execute(f"ATTACH '{db}' AS d")
    for t in ("models", "runs", "scores"):
        src.execute(f"INSERT INTO d.{t} SELECT * FROM {t}")
    src.execute("DETACH d")
    p = argparse.ArgumentParser()
    register(p.add_subparsers())
    args = p.parse_args(["board", "--db", str(db)])
    assert args.func(args) == 0
    out = capsys.readouterr().out
    assert "######## snapshot other" in out and "######## snapshot s" in out
    args = p.parse_args(["board", "--db", str(db), "--snapshot", "s"])
    assert args.func(args) == 0
    out = capsys.readouterr().out
    assert "########" not in out and "500.000" not in out
