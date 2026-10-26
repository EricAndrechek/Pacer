import datetime as dt
import json
import re
import sys
from pathlib import Path

import duckdb
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = (ROOT / "arena" / "results_schema.sql").read_text()


import pytest


@pytest.fixture(autouse=True)
def no_provenance(monkeypatch):
    """Default: arena.provenance is absent, so the fleet.json fallback is what is tested."""
    monkeypatch.setitem(sys.modules, "arena.provenance", None)


def make_db(path: Path, with_agent: bool):
    con = duckdb.connect(str(path))
    con.execute(SCHEMA)
    con.execute("INSERT INTO runs VALUES ('r1','tournament','leaderboard','snap',7,'v','current_code',NULL,now(),NULL)")
    models = {"port-engine-rule": 10.0, "naive-flat": 12.0, "fm-good": 5.0, "ml-ok": 8.0}
    if with_agent:
        models["g1-01-sonnet-cqr"] = 4.0
    for i, n in enumerate(models):
        kind = "agent" if n.startswith("g1-") else "coordinator"
        con.execute("INSERT INTO models VALUES (?,?,'p',NULL,?,?,?,?,?,?,NULL,now())",
                    [f"h{i}", n, 1 if kind == "agent" else None, None, kind, "sess1" if kind == "agent" else None,
                     "claude-sonnet-4-6" if kind == "agent" else None, "low" if kind == "agent" else None])
    rng = np.random.default_rng(0)
    t0 = dt.datetime(2026, 1, 5, tzinfo=dt.timezone.utc)
    rows = []
    for e in range(30):
        shared = rng.normal(0, 1)
        for i, (n, base) in enumerate(models.items()):
            for tgt in ("meter.five_hour", "meter.seven_day", "spend.hourly", "tokens.hourly"):
                v = (base + shared + rng.normal(0, .05)) * (1234.5 if tgt in ("spend.hourly", "tokens.hourly") else 1)
                rows.append(("r1", e, f"h{i}", t0 + dt.timedelta(days=e), f"{tgt}:A", tgt, "crps", None, float(v)))
    con.executemany("INSERT INTO scores VALUES (?,?,?,?,?,?,?,?,?)", rows)
    con.close()


def fleet(root: Path):
    g = root / "gen1"
    g.mkdir(parents=True)
    (g / "fleet.json").write_text(json.dumps({"generation": 1, "agents": {"g1-01-sonnet": {
        "name": "g1-01-sonnet", "generation": 1, "niche": "ml", "model": "claude-sonnet-4-6", "effort": "low",
        "session_id": "sess1", "eval_budget": 20, "status": "finished"}}}))
    (g / "g1-01-sonnet").mkdir()
    (g / "g1-01-sonnet" / "REPORT.md").write_text("# Report\n\nBuilt one model. It is good.\n")


def build(tmp_path, with_agent, narrative=None, selftest=None):
    from report import data, render
    db = tmp_path / "arena.duckdb"
    make_db(db, with_agent)
    fleet(tmp_path / "fleet")
    rep = data.build(db, ["r1"], baseline="port-engine-rule", gens=None,
                     fleet_root=tmp_path / "fleet", home=tmp_path / "home")
    return rep, render.render(rep, narrative=narrative, selftest=selftest)


def test_report_without_agent_models(tmp_path):
    rep, page = build(tmp_path, False)
    assert "No agent models scored yet" in page
    assert "fm-good" in page and "No summary yet" in page
    assert rep.boards["meter.five_hour"].leader == "fm-good"
    assert "http://" not in page.replace("http://www.w3.org", "") and "<script" not in page
    assert "g1-01-sonnet" in page and "Built one model." in page


def test_report_with_agent_and_narrative(tmp_path):
    from report.md import split_caveats
    narr = "Plain **words**.\n\n## Caveats\n\nOnly 30 episodes.\n"
    assert split_caveats(narr)[1].strip() == "Only 30 episodes."
    st = [{"name": "leak scan", "status": "pass", "detail": "ok"}, {"name": "x", "status": "fail", "detail": "<b>"}]
    rep, page = build(tmp_path, True, narrative=narr, selftest=st)
    assert "No agent models scored yet" not in page
    ag = rep.agents[0]
    assert ag["models"] == ["g1-01-sonnet-cqr"] and ag["best"]["meter.five_hour"] > 0.5
    assert "Only 30 episodes." in page and "<strong>words</strong>" in page
    assert "leak scan" in page and "&lt;b&gt;" in page


def _stub_provenance(monkeypatch, root_seen=None):
    import types
    m = types.ModuleType("arena.provenance")
    m.generations = lambda root=None: [1]
    m.agents = lambda g, root=None: [{
        "name": "agent-a", "claude_model": "claude-opus-4-9", "effort": "high", "niche": "stats", "turns": 41,
        "cost_usd": 12.34, "eval_calls": 9, "exit": "finished", "models": ["g1-01-sonnet-cqr"],
        "summary": "Built a quantile model. It cost $12.34 and used 4.5M tokens. Ends well."}]
    m.load = lambda models_root=None: {"g1-01-sonnet-cqr": {
        "kind": "agent", "generation": 1, "agent": "agent-a", "claude_model": "claude-opus-4-9", "effort": "high",
        "niche": "stats", "copied_from": "naive-flat"}}
    monkeypatch.setitem(sys.modules, "arena.provenance", m)


def test_provenance_preferred_over_fleet_json(tmp_path, monkeypatch):
    _stub_provenance(monkeypatch)
    rep, page = build(tmp_path, True)
    assert rep.provenance and [a["name"] for a in rep.agents] == ["agent-a"]   # fleet.json's g1-01-sonnet ignored
    cat = {c["name"]: c for c in rep.models}["g1-01-sonnet-cqr"]
    assert cat["agent"] == "agent-a" and cat["copied_from"] == "naive-flat" and cat["niche"] == "stats"
    assert "agent-a" in page and "g1-01-sonnet</" not in page


def test_provenance_missing_falls_back(tmp_path):
    rep, _ = build(tmp_path, True)
    assert not rep.provenance and rep.agents[0]["name"] == "g1-01-sonnet"


FIGURES = [re.compile(p) for p in (r"\$\s?\d", r"(?i)\d[\d,.]*\s?[kmb]?\s*tokens?\b", r"1,?234", r"12\.34", r"4\.5M")]


def _public(tmp_path, monkeypatch, **kw):
    from report import public
    _stub_provenance(monkeypatch)
    rep, _ = build(tmp_path, True)
    return rep, public.render(rep, narrative=kw.get("narrative"), selftest=kw.get("selftest"), public=True)


def test_public_md_is_relative_only(tmp_path, monkeypatch):
    st = [{"name": "leak scan", "status": "pass", "detail": "no hits"}]
    rep, md = _public(tmp_path, monkeypatch, narrative="Models beat the baseline by 20%.\n\n## Caveats\n\nOnly 30 episodes.\n",
                      selftest=st)
    for section in ("## Summary", "## Results by target", "## Model catalogue", "## Agents per generation",
                    "## Harness checks", "## Caveats and method"):
        assert section in md
    assert "### Hourly spend (`spend.hourly`)" in md and "### Hourly tokens" in md
    for rx in FIGURES:
        assert not rx.search(md), rx.pattern
    assert not re.search(r"\bCRPS\s*\|", md) and "claude-opus" not in md           # no absolute CRPS column
    assert "%" in md and "fm-good" in md and "naive-flat" in md and "Only 30 episodes." in md
    assert "Ends well." in md and "Built a quantile model." in md and "$12" not in md


def test_public_rejects_figures_in_narrative(tmp_path, monkeypatch):
    with pytest.raises(SystemExit):
        _public(tmp_path, monkeypatch, narrative="We spent " + "$" + "4,000 on this.\n")


def test_private_md_carries_absolute_values(tmp_path, monkeypatch):
    from report import public
    _stub_provenance(monkeypatch)
    rep, _ = build(tmp_path, True)
    md = public.render(rep, narrative=None, selftest=None, public=False)
    assert "CRPS" in md and "$12.34" in md


def test_cli_md_public(tmp_path, monkeypatch, capsys):
    import argparse
    from arena import cli_report
    monkeypatch.setenv("ARENA_HOME", str(tmp_path / "home"))
    db = tmp_path / "arena.duckdb"
    make_db(db, True)
    fleet(tmp_path / "fleet")
    out = tmp_path / "RESULTS.md"
    ap = argparse.ArgumentParser()
    cli_report.register(ap.add_subparsers())
    a = ap.parse_args(["report", "--runs", "r1", "--db", str(db), "--fleet-root", str(tmp_path / "fleet"),
                       "--public", "--out", str(out)])
    assert a.func(a) == 0
    assert out.read_text().startswith("# Forecast arena results")
    a = ap.parse_args(["report", "--runs", "r1", "--db", str(db), "--fleet-root", str(tmp_path / "fleet"),
                       "--public", "--format", "html", "--out", str(tmp_path / "x.html")])
    with pytest.raises(SystemExit):
        a.func(a)
