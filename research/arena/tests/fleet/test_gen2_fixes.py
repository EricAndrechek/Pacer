"""Gen-2 fleet fixes: Bash limits, the fm extra, offline weights, the agent
instructions, and honest turn/cap accounting."""
import json
import subprocess
from pathlib import Path

from fleet import launch as L
from fleet.sandbox import AgentSandbox

TEMPLATES = Path(L.__file__).parent / "templates"


def test_bash_time_limits_in_every_agent_env(paths):
    sb = AgentSandbox(paths=paths, gen=1, name="alice", snapshot_id="s", other_agents=("alice",),
                      earlier_models=(), repo_roots=())
    env = sb.settings()["env"]
    assert env["BASH_DEFAULT_TIMEOUT_MS"] == "1800000"
    assert env["BASH_MAX_TIMEOUT_MS"] == "3600000"


def test_presync_installs_the_fm_extra():
    cmd = L.presync_cmd("/x/python3.12")
    assert cmd[:2] == ["uv", "sync"] and cmd[cmd.index("--extra") + 1] == "fm"
    assert "--python" in cmd and "--extra" in L.presync_cmd(None)


def test_hf_cache_cloned_into_the_agent(tmp_path):
    src = tmp_path / "hub"
    (src / "models--org--repo" / "snapshots" / "r1").mkdir(parents=True)
    (src / "models--org--repo" / "snapshots" / "r1" / "w.bin").write_text("weights")
    agent = tmp_path / "agent"
    agent.mkdir()
    assert L.clone_hf_cache(agent, src, log=lambda *a: None) in ("clone", "copy")
    assert (agent / ".hf-cache" / "hub" / "models--org--repo" / "snapshots" / "r1" / "w.bin").read_text() == "weights"


def test_hf_cache_falls_back_to_copy_with_warning(tmp_path, monkeypatch):
    src = tmp_path / "hub"
    src.mkdir()
    (src / "f").write_text("x")
    agent = tmp_path / "agent"
    agent.mkdir()
    real_run = subprocess.run

    def fake_run(cmd, *a, **kw):
        if cmd[:2] == ["cp", "-c"]:
            return subprocess.CompletedProcess(cmd, 1, "", "clonefile failed")
        return real_run(cmd, *a, **kw)
    monkeypatch.setattr(L.subprocess, "run", fake_run)
    logs = []
    assert L.clone_hf_cache(agent, src, log=logs.append) == "copy"
    assert (agent / ".hf-cache" / "hub" / "f").read_text() == "x"
    assert any("warning" in m for m in logs)


def test_hf_cache_missing_source_is_not_fatal(tmp_path):
    assert L.clone_hf_cache(tmp_path, tmp_path / "nope", log=lambda *a: None) is None


def test_instructions_say_no_git():
    agents = (TEMPLATES / "AGENTS.md").read_text()
    brief = (TEMPLATES / "BRIEF.md").read_text()
    assert "## Practicalities" in agents
    for needle in ("--episodes 8", "chmod -R u+w", "offline", "an hour"):
        assert needle in agents
    for text in (agents, brief):
        assert "git commit" not in text and "committing as you go" not in text
        assert "Don't run git" in text or "No git" in text
    assert "committing" not in L.PROMPT


def _stream(tmp_path, events):
    f = tmp_path / "run.jsonl"
    f.write_text("\n".join(json.dumps(e) for e in events) + "\n")
    return L.read_stream(f)


def _asst(i):
    return {"type": "assistant", "message": {"id": f"m{i}", "content": []}}


def test_turns_counted_from_the_stream_when_result_undercounts(tmp_path):
    ev = [_asst(i) for i in range(5)] + [_asst(4)]   # one message split over two events
    ev.append({"type": "result", "subtype": "success", "num_turns": 3, "total_cost_usd": 13.9})
    res = _stream(tmp_path, ev)["result"]
    assert res["num_turns"] == 5 and res["assistant_turns"] == 5 and res["total_cost_usd"] == 13.9


def test_turns_counted_when_result_is_missing(tmp_path):
    out = _stream(tmp_path, [_asst(1), _asst(2), {"type": "assistant", "message": {}}, "garbage"])
    assert out["result"]["num_turns"] == 3
    assert L.final_status(1, out) == "failed"


def test_budget_and_turn_caps_report_capped(tmp_path):
    b = _stream(tmp_path, [_asst(1), {"type": "result", "subtype": "error_max_budget_usd", "num_turns": 1,
                                       "is_error": True}])
    assert b["result"]["capped_by"] == "budget" and b["result"]["num_turns"] == 1
    assert L.final_status(1, b) == "capped (budget)"
    t = _stream(tmp_path, [_asst(1), _asst(2), {"type": "result", "subtype": "error_max_turns", "num_turns": 2}])
    assert L.final_status(1, t) == "capped (turns)"
    ok = _stream(tmp_path, [_asst(1), {"type": "result", "subtype": "success", "num_turns": 1}])
    assert L.final_status(0, ok) == "finished"
    assert L.final_status(1, {}) == "failed"
