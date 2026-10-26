"""Registry (hashes, pinned children, loops, depth), the results database,
and the command line."""
import json
from pathlib import Path

import duckdb
import pytest

from arena.cli import main
from arena.registry import MAX_DEPTH, Registry, RegistryError, content_hash

HERE = Path(__file__).parent
EXAMPLE = HERE.parent.parent / "models" / "example-linear"


def _model(root: Path, name: str, children=()):
    d = root / name
    d.mkdir(parents=True)
    kids = ", ".join(f'"{c}"' for c in children)
    (d / "model.toml").write_text(f'name = "{name}"\ntargets = ["meter.five_hour"]\nchildren = [{kids}]\n')
    (d / "model.py").write_text("class Model:\n    def __init__(self, ctx): pass\n")
    return d


def test_content_hash_is_stable_and_ignores_caches(tmp_path):
    d = _model(tmp_path, "m")
    h = content_hash(d)
    (d / "__pycache__").mkdir()
    (d / "__pycache__" / "model.cpython-312.pyc").write_bytes(b"x")
    (d / ".DS_Store").write_bytes(b"x")
    assert content_hash(d) == h
    (d / "helper.py").write_text("X = 1\n")
    assert content_hash(d) != h


def test_children_pinned_by_hash(tmp_path):
    _model(tmp_path, "base")
    _model(tmp_path, "top", ["base"])
    reg = Registry([tmp_path])
    top = reg.load("top")
    assert top.children["base"].hash == content_hash(tmp_path / "base")
    (tmp_path / "base" / "model.py").write_text("class Model:\n    pass\n")
    with pytest.raises(RegistryError, match="changed"):
        Registry.verify(top.children["base"])
    good = Registry([tmp_path]).load("base").hash
    _model(tmp_path, "pinned", [f"base@{good[:10]}"])
    assert Registry([tmp_path]).load("pinned").children["base"].hash == good
    _model(tmp_path, "wrongpin", ["base@deadbeef"])
    with pytest.raises(RegistryError, match="pinned"):
        Registry([tmp_path]).load("wrongpin")


def test_child_loops_and_depth_cap(tmp_path):
    _model(tmp_path, "a", ["b"])
    _model(tmp_path, "b", ["c"])
    _model(tmp_path, "c", ["a"])
    with pytest.raises(RegistryError, match="loop"):
        Registry([tmp_path]).load("a")
    chain = tmp_path / "chain"
    names = [f"m{i}" for i in range(MAX_DEPTH + 2)]
    for i, n in enumerate(names):
        _model(chain, n, [names[i + 1]] if i + 1 < len(names) else [])
    with pytest.raises(RegistryError, match="deeper"):
        Registry([chain]).load("m0")
    assert Registry([chain]).load(names[1]).depth() == MAX_DEPTH


def test_cli_test_runs_example_linear(arena_home, capsys):
    rc = main(["test", str(EXAMPLE), "--snapshot", "fx", "--episodes", "3", "--seed", "4", "--checkpoints", "6"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "summary" in out and "FAILURE" not in out
    assert "meter." in out


def test_cli_eval_prints_only_rounded_aggregates(arena_home, capsys):
    rc = main(["eval", str(EXAMPLE), "--tier", "leaderboard", "--snapshot", "fx", "--episodes", "4",
               "--seed", "1", "--checkpoints", "4", "--json"])
    assert rc == 0
    report = json.loads(capsys.readouterr().out)
    assert set(report) == {"model", "tier", "seed", "episodes", "targets", "failures", "fallback_scoring"}
    for metrics in report["targets"].values():
        for v in metrics.values():
            assert v == float(f"{v:.3g}")                 # rounded to 3 significant digits


def test_cli_run_records_results(arena_home, tmp_path, capsys):
    db = tmp_path / "r.duckdb"
    rc = main(["run", "--models", f"example-linear,{HERE / 'models' / 'spy'}", "--tier", "lockbox",
               "--snapshot", "fx", "--episodes", "3", "--seed", "2", "--checkpoints", "4",
               "--results-db", str(db), "--in-process"])
    assert rc == 0
    con = duckdb.connect(str(db), read_only=True)
    assert con.execute("select count(*) from runs").fetchone()[0] == 1
    assert con.execute("select count(*) from models").fetchone()[0] == 2
    assert con.execute("select count(*) from episodes").fetchone()[0] == 3
    assert con.execute("select count(distinct model_hash) from scores").fetchone()[0] >= 1
    assert con.execute("select finished_at is not null from runs").fetchone()[0]
    files = con.execute("select path from forecast_files").fetchall()
    assert files and all((db.parent / p).is_file() for (p,) in files)


def test_identity_covers_kit_and_harness_code_but_not_scoring(tmp_path):
    """A model is its folder AND the shared code it runs: editing kit/ or the
    worker-side harness is a different model (new scores, a cold child
    cache, broken pins); editing scoring or the command line is not."""
    from arena.registry import code_hash, folder_hash
    root = tmp_path / "arena-root"
    for rel in ("kit/spend.py", "arena/worker.py", "arena/scoring/checkpoint.py", "arena/cli.py",
                "arena/cli_board.py", "arena/results.py"):
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text(f"# {rel}\n")
    (root / "uv.lock").write_text("lock\n")
    d = _model(tmp_path / "models", "m")
    base = code_hash(root)
    ident = content_hash(d, code=base)
    assert ident != folder_hash(d)

    def changed(rel: str) -> bool:
        p = root / rel
        old = p.read_text()
        p.write_text(old + "x = 1\n")
        try:
            return code_hash(root) != base
        finally:
            p.write_text(old)
            assert code_hash(root) == base

    assert changed("kit/spend.py") and changed("arena/worker.py") and changed("uv.lock")
    assert not changed("arena/scoring/checkpoint.py")
    assert not changed("arena/cli.py") and not changed("arena/cli_board.py") and not changed("arena/results.py")
    (root / "kit" / "__pycache__").mkdir()
    (root / "kit" / "__pycache__" / "spend.cpython-312.pyc").write_bytes(b"junk")
    assert code_hash(root) == base
    # The registry's hash is this harness's identity of the folder, and that
    # is what the child cache keys on.
    from arena.cache import cache_key
    info = Registry([tmp_path / "models"]).load("m")
    assert info.hash == content_hash(d) == content_hash(d, code=code_hash())
    assert cache_key(content_hash(d, code=base), "s", {}, 0, "r") != cache_key(info.hash, "s", {}, 0, "r")
