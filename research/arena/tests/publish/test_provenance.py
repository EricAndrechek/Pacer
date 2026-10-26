"""Tracked attribution: models/PROVENANCE.toml, the generations' agents.toml,
the results database taking its attribution from them, the hidden-tier guard
for agent models, and folding a collected generation into the repo."""
import json
from pathlib import Path

import duckdb
import pytest

from arena import provenance
from arena.cli import main
from arena.registry import Registry, content_hash
from arena.results import ResultsDB

ARENA = Path(__file__).resolve().parents[2]
EXAMPLE = ARENA / "models" / "example-linear"


# --- the tracked files -----------------------------------------------------

def test_every_model_folder_is_attributed():
    from fleet.publish import check
    assert check(ARENA) == []


def test_load_shape_and_kinds():
    recs = provenance.load()
    assert recs["example-linear"]["kind"] == "example"
    assert recs["port-engine-rule"]["kind"] == "port"
    assert recs["selftest-oracle"]["kind"] == "selftest"
    for name, r in recs.items():
        assert set(r) == set(provenance.MODEL_KEYS)
        if name.startswith(("g1-", "g2-")):
            assert r["kind"] == "agent"
            assert r["generation"] == int(name[1])
            assert name.startswith(r["agent"] + "-")
            assert r["claude_model"].startswith("claude-")
        else:
            assert r["kind"] != "agent" and r["generation"] is None


def test_agents_and_generations():
    assert provenance.generations() == [1, 2]
    g1 = provenance.agents(1)
    assert [a["name"] for a in g1][:2] == ["g1-01-sonnet", "g1-02-haiku"]
    for g in (1, 2):
        for a in provenance.agents(g):
            assert set(provenance.AGENT_KEYS) <= set(a)
            assert isinstance(a["models"], list) and a["models"]
            assert isinstance(a["summary"], str) and a["summary"]
            assert a["exit"] in ("finished", "budget cap", "turns cap")
            for m in a["models"]:
                assert provenance.lookup(m)["agent"] == a["name"]
    assert sum(len(a["models"]) for g in (1, 2) for a in provenance.agents(g)) == 89


def test_tracked_files_hold_nothing_private():
    import re
    texts = [(ARENA / "models" / provenance.FILE).read_text()]
    texts += [p.read_text() for p in (ARENA / "fleet" / "generations").rglob("*") if p.is_file()]
    blob = "\n".join(texts)
    assert "/Users/" not in blob and "~/" not in blob
    assert not re.search(r"\b[0-9a-f]{8}-[0-9a-f]{4}-", blob)          # session / account uuids
    assert not re.search(r"[\w.+-]+@[\w-]+\.[\w.]+", blob.replace("@<", ""))   # emails


def test_dumps_round_trips(tmp_path):
    recs = {"m-a": {"kind": "agent", "generation": 3, "agent": "g3-01-x", "claude_model": "claude-x",
                    "effort": "high", "niche": "n", "copied_from": ["m-b"]},
            "m-b": {"kind": "port"}}
    (tmp_path / provenance.FILE).write_text(provenance.dumps(recs, header="# h"))
    got = provenance.load(tmp_path)
    assert got["m-a"]["copied_from"] == ["m-b"] and got["m-a"]["generation"] == 3
    assert got["m-b"] == {"kind": "port", "generation": None, "agent": None, "claude_model": None,
                          "effort": None, "niche": None, "copied_from": []}
    assert provenance.load(tmp_path / "missing") == {}


# --- the results database ----------------------------------------------------

def _models_root(tmp_path: Path) -> Path:
    """example-linear twice: as an agent's model and as a model it copied."""
    import shutil
    root = tmp_path / "models"
    for n in ("g9-01-x-lin", "base-lin"):
        shutil.copytree(EXAMPLE, root / n)
        t = root / n / "model.toml"
        t.write_text(t.read_text().replace('name = "example-linear"', f'name = "{n}"'))
    (root / provenance.FILE).write_text(provenance.dumps({
        "g9-01-x-lin": {"kind": "agent", "generation": 9, "agent": "g9-01-x", "claude_model": "claude-test-1",
                        "effort": "xhigh", "niche": "testing", "copied_from": ["base-lin"]},
        "base-lin": {"kind": "port"}}))
    return root


def test_register_model_fills_attribution_from_provenance(tmp_path):
    root = _models_root(tmp_path)
    info = Registry([root]).load("g9-01-x-lin")
    with ResultsDB(tmp_path / "r.duckdb") as db:
        db.register_model(info)
        db.register_model(Registry([root]).load("base-lin"))
        row = db.con.execute("SELECT author_kind, generation, niche, claude_model, claude_effort, copied_from "
                             "FROM models WHERE name = 'g9-01-x-lin'").fetchone()
        assert row == ("agent", 9, "testing", "claude-test-1", "xhigh", [content_hash(root / "base-lin")])
        assert db.con.execute("SELECT author_kind FROM models WHERE name = 'base-lin'").fetchone()[0] == "port"


def test_unlisted_model_stays_coordinator(tmp_path):
    root = _models_root(tmp_path)
    (root / provenance.FILE).unlink()
    with ResultsDB(tmp_path / "r.duckdb") as db:
        db.register_model(Registry([root]).load("g9-01-x-lin"))
        assert db.con.execute("SELECT author_kind, generation FROM models").fetchone() == ("coordinator", None)


def test_explicit_attribution_wins(tmp_path):
    root = _models_root(tmp_path)
    with ResultsDB(tmp_path / "r.duckdb") as db:
        db.register_model(Registry([root]).load("g9-01-x-lin"), author_kind="coordinator")
        assert db.con.execute("SELECT author_kind FROM models").fetchone()[0] == "coordinator"


def test_hidden_tiers_refuse_agent_models_on_host_workers(arena_home, tmp_path, capsys):
    root = _models_root(tmp_path)
    args = ["run", "--models", "g9-01-x-lin", "--models-root", str(root), "--snapshot", "fx",
            "--episodes", "2", "--seed", "1", "--checkpoints", "3", "--in-process",
            "--results-db", str(tmp_path / "r.duckdb")]
    assert main(args + ["--tier", "lockbox"]) == 2
    assert "agent models" in capsys.readouterr().err
    assert main(args + ["--tier", "visible"]) == 0                     # visible: what agents saw anyway
    assert main(args + ["--tier", "lockbox", "--trust-agent-models"]) == 0
    con = duckdb.connect(str(tmp_path / "r.duckdb"), read_only=True)
    assert con.execute("SELECT DISTINCT author_kind, generation FROM models").fetchall() == [("agent", 9)]


# --- folding a collected generation in ---------------------------------------

def _fleet(tmp_path: Path):
    from fleet.paths import FleetPaths
    paths = FleetPaths(tmp_path / "fleet-root", tmp_path / "home")
    gen = paths.gen_dir(9)
    src = gen / "collected" / "g9-01-x" / "models" / "g9-01-x-lin"
    import shutil
    shutil.copytree(EXAMPLE, src)
    (src / "model.toml").write_text((src / "model.toml").read_text().replace('"example-linear"', '"g9-01-x-lin"'))
    for junk in ("dev/try.py", "tools/fit.py", "tools_bench.sh", ".git-add-marker", "__pycache__/m.cpython.pyc"):
        (src / junk).parent.mkdir(parents=True, exist_ok=True)
        (src / junk).write_text("x")
    run_log = paths.run_dir(9, "g9-01-x") / "run.jsonl"
    run_log.parent.mkdir(parents=True)
    run_log.write_text("\n".join(json.dumps(e) for e in [
        {"type": "assistant", "message": {"id": "a"}}, {"type": "assistant", "message": {"id": "b"}},
        {"type": "result", "subtype": "success", "num_turns": 2, "total_cost_usd": 1.234}]) + "\n")
    st = paths.agent_state(9, "g9-01-x")
    st.mkdir(parents=True)
    (st / "calls.jsonl").write_text('{"event": "call"}\n{"event": "result"}\n{"event": "call"}\n')
    paths.fleet_json(9).write_text(json.dumps({"agents": {"g9-01-x": {
        "model": "claude-test-1", "effort": "low", "niche": "testing", "max_turns": 10, "budget_usd": 2,
        "eval_budget": 3, "run_log": str(run_log), "exit_code": 0}}}))
    (gen / "collect.json").write_text(json.dumps([{"name": "g9-01-x", "new_models": [
        {"name": "g9-01-x-lin", "copied_from": ["example-linear"]}]}]))
    return paths


def test_import_generation(tmp_path):
    from fleet import publish
    paths = _fleet(tmp_path)
    arena = tmp_path / "arena"
    import shutil
    shutil.copytree(EXAMPLE, arena / "models" / "example-linear")
    out = publish.import_generation(paths, 9, arena, summaries={"g9-01-x": "A line."}, log=lambda m: None)
    assert out["copied"] == ["g9-01-x-lin"]
    got = sorted(p.relative_to(arena / "models" / "g9-01-x-lin").as_posix()
                 for p in (arena / "models" / "g9-01-x-lin").rglob("*") if p.is_file())
    assert got == ["model.py", "model.toml"]
    assert set(out["dropped"]["g9-01-x-lin"]) >= {"dev/try.py", "tools/fit.py", "tools_bench.sh", ".git-add-marker"}
    recs = provenance.load(arena / "models")
    assert recs["example-linear"]["kind"] == "example"
    assert recs["g9-01-x-lin"]["agent"] == "g9-01-x" and recs["g9-01-x-lin"]["copied_from"] == ["example-linear"]
    (a,) = provenance.agents(9, arena)
    assert (a["turns"], a["cost_usd"], a["eval_calls"], a["eval_scored"], a["exit"]) == (2, 1.23, 2, 1, "finished")
    assert a["models"] == ["g9-01-x-lin"] and a["summary"] == "A line."
    assert provenance.generations(arena) == [9]
    assert publish.check(arena) == []
    # a second import never overwrites a model folder
    out2 = publish.import_generation(paths, 9, arena, log=lambda m: None)
    assert out2["copied"] == [] and out2["present"] == ["g9-01-x-lin"]


def test_import_refuses_a_model_that_imports_scratch(tmp_path):
    from fleet import publish
    paths = _fleet(tmp_path)
    src = paths.gen_dir(9) / "collected" / "g9-01-x" / "models" / "g9-01-x-lin"
    (src / "model.py").write_text("from tools import fit\n" + (src / "model.py").read_text())
    with pytest.raises(RuntimeError, match="scratch"):
        publish.import_generation(paths, 9, tmp_path / "arena", log=lambda m: None)
