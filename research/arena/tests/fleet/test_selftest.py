"""The self-test's preparation (never its launch): dummy data, two agents,
the probe script and a settings file that passes the checker."""

import sys

import pytest

# The agent fleet launches through macOS: the Claude Code sandbox it relies on
# was verified with Seatbelt only (docs/fleet-verification.md), so these run
# on macOS. Everything else under tests/ runs everywhere, CI included.
pytestmark = pytest.mark.skipif(sys.platform != "darwin", reason="agent fleet: verified on macOS only")

import json

from fleet import selftest
from fleet.sandbox import check_settings


@pytest.mark.skipif(__import__("shutil").which("claude") is None, reason="needs the Claude Code CLI")
def test_prepare_builds_a_safe_probe(tmp_path, monkeypatch):
    monkeypatch.setenv("ARENA_SELFTEST_ROOT", str(tmp_path / "st"))
    ctx = selftest.prepare(log=lambda *a: None)
    paths, p = ctx["paths"], ctx["prepared"]
    s = json.loads(p.settings.read_text())
    must = [paths.home / "snapshots" / "st" / "holdout", paths.home / "salt", paths.agent_dir(0, "other"),
            paths.home / "snapshots" / "st" / "train"]
    assert check_settings(s, agent_dir=p.dir, wrapper=p.wrapper, train=paths.visible_view("st"), must_deny=must) == []
    probe = (p.dir / "probe.sh").read_text()
    assert "@" not in "".join(l for l in probe.splitlines() if "@HOLDOUT" in l or "@GATE" in l)
    assert str(paths.eval_wrapper(0, "probe")) in probe and ctx["marker"] not in probe
    assert "Sandbox self-test" in p.brief.read_text()
    assert (p.dir / "models" / "probe-model" / "model.toml").is_file()
    assert json.loads((paths.state / "gen0" / "eval.json").read_text())["episodes"] == 1
    assert "--max-turns" in p.argv and "claude-haiku-4-5" in p.argv
