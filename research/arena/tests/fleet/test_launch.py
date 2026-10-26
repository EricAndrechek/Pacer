"""The launcher: clones, settings, wrappers, the exact command line, the
parallel cap, Pacer gating, and attribution recorded by the launcher."""
import json
import uuid

import pytest

from fleet import template as tmpl
from fleet.launch import FleetState, check_resume, launch
from fleet.plan import parse_plan
from fleet.sandbox import check_settings

PLAN = """
[fleet]
max_parallel = 2
eval_budget = 5
eval_episodes = 9

[[agent]]
name = "a1"
niche = "structural"
model = "claude-opus-5-5"
effort = "high"
max_turns = 50
budget_usd = 5

[[agent]]
name = "a2"
niche = "statistical"
model = "claude-sonnet-5-5"
effort = "medium"
max_turns = 40
budget_usd = 4

[[agent]]
name = "a3"
niche = "ensembles"
model = "claude-haiku-4-5"
effort = "low"
max_turns = 30
budget_usd = 3
eval_budget = 2
"""


@pytest.fixture
def ready(paths, snapshot):
    tmpl.build_template(paths, 1, "snap1", t_train="2026-01-01")
    return paths


def run(paths, fake_claude, fake_pacer, plan=PLAN, **kw):
    return launch(paths, 1, parse_plan(plan), claude=str(fake_claude[0]), pacer=fake_pacer[0], presync=False,
                  backend="selftest", poll_s=0.05, log=lambda *a: None, **kw)


def test_attribution_recorded_by_the_launcher(ready, fake_claude, fake_pacer):
    paths = ready
    assert run(paths, fake_claude, fake_pacer) == 0
    fleet = json.loads(paths.fleet_json(1).read_text())
    assert fleet["generation"] == 1 and fleet["snapshot"] == "snap1" and fleet["claude_version"].startswith("9.9.9")
    assert fleet["template_commit"] == tmpl.template_info(paths.template(1))["commit"]
    plan = parse_plan(PLAN)
    for spec in plan.agents:
        rec = fleet["agents"][spec.name]
        uuid.UUID(rec["session_id"])
        for f in ("niche", "model", "effort", "max_turns", "budget_usd", "eval_budget"):
            assert rec[f] == getattr(spec, f), f
        assert rec["generation"] == 1 and rec["status"] == "finished" and rec["exit_code"] == 0
        assert rec["start"] <= rec["end"]
        assert rec["init"]["session_id"] == rec["session_id"] and rec["init"]["model"] == spec.model
        assert rec["result"]["num_turns"] == 3
        assert rec["cwd"] == str(paths.agent_dir(1, spec.name))
    assert len({r["session_id"] for r in fleet["agents"].values()}) == 3


def test_command_line_follows_the_verified_recipe(ready, fake_claude, fake_pacer):
    paths = ready
    run(paths, fake_claude, fake_pacer, dry_run=True)
    rec = json.loads(paths.fleet_json(1).read_text())["agents"]["a1"]
    argv = rec["argv"]
    s = " ".join(argv)
    for frag in ("-p", "--model claude-opus-5-5", "--effort high", "--max-turns 50", "--max-budget-usd 5",
                 "--restricted", "--tools Bash,Read,Write,Edit,WebFetch,WebSearch", "--strict-mcp-config",
                 "--disable-slash-commands", f"--settings {rec['settings']}", "--permission-mode dontAsk",
                 f"--append-system-prompt-file {paths.agent_dir(1, 'a1') / 'BRIEF.md'}",
                 f"--session-id {rec['session_id']}", "--output-format stream-json", "--verbose"):
        assert frag in s, frag
    from fleet.launch import launch_env
    env = launch_env(paths, paths.agent_dir(1, "a1"), str(fake_claude[0]))
    assert set(env) == {"HOME", "USER", "LOGNAME", "PATH", "SHELL", "TMPDIR", "LANG",
                        "CLAUDE_CODE_DISABLE_AUTO_MEMORY", "CLAUDE_CODE_DISABLE_ADVISOR_TOOL"}
    assert env["TMPDIR"].startswith(str(paths.agent_dir(1, "a1")))
    assert rec["status"] == "prepared"


def test_each_agent_is_prepared_safely(ready, fake_claude, fake_pacer):
    paths = ready
    run(paths, fake_claude, fake_pacer, dry_run=True)
    fleet = json.loads(paths.fleet_json(1).read_text())
    for name in ("a1", "a2", "a3"):
        d = paths.agent_dir(1, name)
        settings = json.loads(paths.settings_file(1, name).read_text())
        must = [paths.agent_dir(1, o) for o in ("a1", "a2", "a3") if o != name] + [
            paths.home / "snapshots" / "snap1" / "holdout", paths.home / "salt", paths.state]
        assert check_settings(settings, agent_dir=d, wrapper=paths.eval_wrapper(1, name),
                              train=paths.visible_view("snap1"), must_deny=must) == []
        assert tmpl.git("log", "--oneline", cwd=d).stdout.count("\n") == 1      # template history only
        cfg = tmpl.git("config", "--local", "--list", cwd=d).stdout
        assert f"user.name=arena-gen1-{name}" in cfg and "commit.gpgsign=false" in cfg
        brief = (d / "BRIEF.md").read_text()
        assert name in brief and str(paths.eval_wrapper(1, name)) in brief
        assert fleet["agents"][name]["niche"] in brief
        assert ("calls in total" in brief) and str(fleet["agents"][name]["eval_budget"]) in brief
        assert "BRIEF.md" in (d / ".git" / "info" / "exclude").read_text()
        assert tmpl.git("status", "--porcelain", cwd=d).stdout == ""
        assert (d / ".arena-home" / "snapshots" / "snap1" / "manifest.json").is_file()
        assert json.loads((paths.agent_state(1, name) / "budget.json").read_text())["used"] == 0
        assert paths.eval_wrapper(1, name).is_file()
    assert json.loads((paths.agent_state(1, "a3") / "budget.json").read_text())["budget"] == 2


def test_parallel_cap(ready, fake_claude, fake_pacer, monkeypatch):
    monkeypatch.setenv("FAKE_SLEEP", "0.6")
    run(ready, fake_claude, fake_pacer)
    events = []
    for line in fake_claude[1].read_text().splitlines():
        kind, name, t = line.split()[:3]
        events.append((float(t), 1 if kind == "start" else -1))
    live = peak = 0
    for _, d in sorted(events):
        live += d
        peak = max(peak, live)
    assert peak == 2


def test_pacer_pause_waits_then_resumes(ready, fake_claude, fake_pacer):
    exe, calls, codes = fake_pacer
    codes.write_text("10\n")
    assert run(ready, fake_claude, fake_pacer) == 0
    log = calls.read_text().splitlines()
    assert log[0] == "gate --model opus" and log[1] == "wait --model opus"
    fleet = json.loads(ready.fleet_json(1).read_text())
    assert fleet["gates"][0]["verdict"] == "go" and all(a["status"] == "finished" for a in fleet["agents"].values())


def test_resume_skips_finished_and_refuses_changed_specs(ready, fake_claude, fake_pacer):
    run(ready, fake_claude, fake_pacer)
    n = fake_claude[1].read_text().count("start")
    run(ready, fake_claude, fake_pacer)
    assert fake_claude[1].read_text().count("start") == n
    state = FleetState.load(ready.fleet_json(1))
    with pytest.raises(ValueError, match="already ran"):
        check_resume(state, parse_plan(PLAN.replace('effort = "high"', 'effort = "max"')))


def test_handback_commit_saves_uncommitted_work(ready, fake_claude, fake_pacer):
    from fleet.launch import handback_commit
    paths = ready
    run(paths, fake_claude, fake_pacer, dry_run=True)
    d = paths.agent_dir(1, "a1")
    rec = json.loads(paths.fleet_json(1).read_text())["agents"]["a1"]
    assert (d / ".gitconfig").read_text().startswith("[user]")
    assert handback_commit(paths, 1, "a1", rec) is None                 # nothing to hand back
    (d / "models" / "a1-x").mkdir()
    (d / "models" / "a1-x" / "model.py").write_text("class Model: pass\n")
    (d / "REPORT.md").write_text("report\n")
    (d / "scratch.txt").write_text("not collected\n")
    sha = handback_commit(paths, 1, "a1", rec)
    assert sha and len(sha) == 40
    files = tmpl.git("show", "--name-only", "--format=%an|%s", "HEAD", cwd=d).stdout
    assert "arena-gen1-a1|hand-back" in files and "models/a1-x/model.py" in files and "REPORT.md" in files
    assert "scratch.txt" not in files
    cfg = d / ".git" / "config"
    cfg.write_text(cfg.read_text() + "[core]\n\tfsmonitor = touch /tmp/pwned-handback\n")
    (d / "REPORT.md").write_text("changed\n")
    assert handback_commit(paths, 1, "a1", rec) is None                 # tampered: hands off
