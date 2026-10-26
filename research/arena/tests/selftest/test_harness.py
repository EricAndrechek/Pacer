"""`arena selftest` as a whole: every check passes on the core fixture (no
truth/) and on a small synthetic snapshot (truth/), and the CLI prints a
pass/fail table with the right exit code."""
from __future__ import annotations

import numpy as np
import pytest

from arena.selftest import CheckResult, SelfTest, run_selftest

FX_CHECKS = ("oracle", "known_answers", "determinism", "leak_probes", "leak_caught")
SYN_CHECKS = FX_CHECKS + ("synthetic_recovery", "calibration")


def _by_name(rows):
    return {r.name: r for r in rows}


def test_all_checks_pass_on_fixture(arena_home):
    rows = run_selftest("fx", tier="visible", seed=3, episodes=12, only=FX_CHECKS)
    by = _by_name(rows)
    for name in FX_CHECKS:
        assert by[name].passed, f"{name}: {by[name].detail}"
    assert not any(r.skipped for r in rows)       # all of these apply to fx


def test_all_checks_pass_on_synthetic(arena_home):
    rows = run_selftest("syn", tier="visible", seed=1, episodes=12, only=SYN_CHECKS)
    by = _by_name(rows)
    for name in SYN_CHECKS:
        assert by[name].passed, f"{name}: {by[name].detail}"
    assert "beats baselines" in by["synthetic_recovery"].detail


def test_recovery_and_calibration_skip_without_truth(arena_home):
    rows = _by_name(run_selftest("fx", tier="visible", seed=1, episodes=8,
                                 only=("synthetic_recovery", "calibration")))
    assert rows["synthetic_recovery"].skipped and rows["calibration"].skipped


def test_oracle_is_near_perfect_and_shift_is_caught(arena_home):
    st = SelfTest("syn", tier="visible", seed=2, episodes=12)
    r = st.check_oracle()
    assert r.passed, r.detail
    assert "shift raises crps" in r.detail


def test_probe_gains_nothing_over_a_constant(arena_home):
    """The adversary's score rows equal the constant model's exactly, and it
    reports no null-slot value, no post-now row and no cross-episode state."""
    st = SelfTest("fx", tier="visible", seed=4, episodes=10)
    r = st.check_leak_probes()
    assert r.passed, r.detail
    assert "gained nothing" in r.detail


def test_leak_caught_control_finds_the_hidden_values(arena_home):
    """With scrubbing off the probe DOES see values under null slots, so an
    empty report with scrubbing on means there was nothing to find."""
    st = SelfTest("fx", tier="visible", seed=4, episodes=8)
    r = st.check_leak_caught()
    assert r.passed and "scrub off exposes" in r.detail


def test_known_answers_match_hand_computation(arena_home):
    st = SelfTest("fx", tier="visible", seed=0, episodes=1)
    r = st.check_known_answers()
    assert r.passed, r.detail


def test_determinism_across_workers(arena_home):
    st = SelfTest("fx", tier="visible", seed=5, episodes=10)
    r = st.check_determinism()
    assert r.passed, r.detail
    assert "byte-identical" in r.detail


def test_cli_table_and_exit_code(arena_home, capsys):
    from arena import cli_selftest
    code = cli_selftest.main(["--snapshot", "fx", "--episodes", "8", "--seed", "1",
                              "--only", "determinism,leak_probes"])
    out = capsys.readouterr().out
    assert code == 0
    assert "PASS" in out and "determinism" in out and "leak_probes" in out
    assert "passed" in out.splitlines()[-1]


def test_cli_reports_failure_nonzero(arena_home, monkeypatch):
    """A failing check makes the CLI exit 1 and print FAIL (without needing a
    real broken harness: a stubbed check)."""
    from arena import cli_selftest
    monkeypatch.setattr(cli_selftest, "run_selftest",
                        lambda *a, **k: [CheckResult("determinism", False, "stubbed failure")])
    code = cli_selftest.main(["--snapshot", "fx", "--only", "determinism"])
    assert code == 1


def test_selftest_models_load(arena_home):
    """Every selftest-* model folder is a valid, loadable model."""
    from arena.registry import Registry
    from arena.selftest import MODELS_ROOT
    reg = Registry([MODELS_ROOT])
    for name in ("selftest-constant", "selftest-last", "selftest-line", "selftest-oracle",
                 "selftest-probe", "selftest-spy", "selftest-walk-truth"):
        info = reg.load(name)
        assert info.hash and info.targets


def test_child_gets_the_parents_moment_not_the_request(arena_home):
    """A parent asks its spy child to forecast a LATER now and another scope;
    the runner must answer for the parent's own moment and view. The spy logs
    what it actually saw."""
    import json
    import tempfile
    from pathlib import Path

    from arena.cache import ChildCache
    from arena.registry import Registry
    from arena.runner import RunConfig, Runner
    from arena.selftest import MODELS_ROOT
    from arena.snapshot.views import SnapshotData

    root = Path(tempfile.mkdtemp())
    (root / "models").mkdir()
    # A tiny parent that calls the spy for request.now + 10 days.
    import shutil
    shutil.copytree(MODELS_ROOT / "selftest-spy", root / "models" / "selftest-spy")
    parent = root / "models" / "late-parent"
    parent.mkdir()
    (parent / "model.toml").write_text(
        'name = "late-parent"\ntargets = ["meter.five_hour"]\nchildren = ["selftest-spy"]\n')
    (parent / "model.py").write_text(
        "import numpy as np\n"
        "from dataclasses import replace\n"
        "from arena.types import Forecast, TargetForecast\n"
        "DAY=86400000\n"
        "class Model:\n"
        "    def __init__(self, ctx): self.ctx=ctx\n"
        "    def fit(self, h): self.h=h\n"
        "    def forecast(self, request):\n"
        "        later = replace(request, now=request.now+10*DAY,\n"
        "                        targets=tuple(replace(t, grid=t.grid+10*DAY) for t in request.targets))\n"
        "        self.ctx.model('selftest-spy').forecast(later)\n"
        "        return Forecast({t.key: TargetForecast.point(np.zeros(len(t.grid))) for t in request.targets})\n")

    data = SnapshotData.load("fx", "visible")
    cfg = RunConfig(tier="visible", episodes=4, seed=1, targets=("meter.five_hour",),
                    in_process=True, cache=False, checkpoint_cap=2)
    r = Runner(data, cfg, cache=ChildCache(enabled=False))
    out = r.run([Registry([root / "models"]).load("late-parent")])
    spy = [json.loads(m["message"][4:]) for m in out.logs if m["message"].startswith("SPY ")]
    assert spy, "the spy never ran"
    for s in spy:
        if s["event"] == "fit":
            # The child's view never reaches past the moment it was fitted at.
            assert s["max_known"] is None or s["max_known"] <= s["now"]
        if s["event"] == "forecast":
            # It answered for its own fitted moment, not the +10 day request.
            assert s["history_now"] == s["now"]
    shutil.rmtree(root, ignore_errors=True)
