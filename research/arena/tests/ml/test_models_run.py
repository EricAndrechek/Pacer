"""Every learned model and combiner, as committed, runs on synth-default:
no failures, a valid forecast for every requested meter target, scores."""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from arena.cache import ChildCache
from arena.runner import RunConfig, Runner

ARENA = Path(__file__).parent.parent.parent
LEARNED = sorted(p.name for p in (ARENA / "models").iterdir() if p.name.startswith("ml-"))
COMBOS = sorted(p.name for p in (ARENA / "models").iterdir() if p.name.startswith("combo-"))
METERS = ("meter.five_hour", "meter.seven_day", "meter.scoped")


def _run(data, info, *, episodes, targets, in_process=True, **kw):
    cfg = RunConfig(episodes=episodes, seed=5, in_process=in_process, checkpoint_cap=3, targets=targets, **kw)
    return Runner(data, cfg, cache=ChildCache(enabled=False)).run([info])


def _check(out, targets):
    assert not out.failures, [(f["kind"], f["message"][-600:]) for f in out.failures[:3]]
    scored = {s["target"] for s in out.scores if s["metric"] == "crps" and s["lead_s"] is None}
    asked = {t.target.value for ep in out.episodes for t in ep.targets if t.target.value in targets}
    assert asked and asked <= scored, (asked, scored)
    assert all(np.isfinite(s["value"]) for s in out.scores if s["metric"] == "crps")


def test_the_model_lists_are_what_this_branch_ships():
    assert LEARNED == ["ml-gbm-quantile", "ml-qrf"]
    assert COMBOS == ["combo-ewa", "combo-fforma", "combo-median", "combo-stack"]


@pytest.mark.parametrize("name", LEARNED)
def test_learned_model_runs(synth_visible, registry, name):
    out = _run(synth_visible, registry.load(ARENA / "models" / name), episodes=3, targets=METERS)
    _check(out, METERS)
    assert any("trained" in lg["message"] for lg in out.logs), [lg["message"] for lg in out.logs]


def test_learned_model_runs_in_a_worker_process(synth_visible, registry):
    out = _run(synth_visible, registry.load(ARENA / "models" / "ml-gbm-quantile"), episodes=1,
               targets=("meter.five_hour",), in_process=False)
    _check(out, ("meter.five_hour",))


PRODUCTION_CHILDREN = ["port-engine-rule", "spend-decay-30m", "struct-timestral-28m"]
LIGHT_CHILDREN = ["mltest-flat", "mltest-low"]


def _light_copy(tmp_path: Path, name: str) -> Path:
    """The committed combiner with its production children swapped for the
    two light test children (struct-timestral-28m needs torch and the
    weights, and a fresh fit of it per checkpoint and backtest origin is
    minutes; the combining logic is what is under test here)."""
    import shutil
    import tomllib
    d = tmp_path / "models" / name
    shutil.copytree(ARENA / "models" / name, d, ignore=shutil.ignore_patterns("__pycache__"))
    text = (d / "model.toml").read_text()
    assert text.count(json.dumps(PRODUCTION_CHILDREN)) == 2, "production children changed: update this test"
    (d / "model.toml").write_text(text.replace(json.dumps(PRODUCTION_CHILDREN), json.dumps(LIGHT_CHILDREN)))
    meta = tomllib.loads((d / "model.toml").read_text())
    assert meta["children"] == meta["config"]["children"] == LIGHT_CHILDREN
    return d


@pytest.mark.parametrize("name", COMBOS)
def test_combiner_declares_the_production_children(registry, name):
    import tomllib
    meta = tomllib.loads((ARENA / "models" / name / "model.toml").read_text())
    assert meta["children"] == meta["config"]["children"] == PRODUCTION_CHILDREN


@pytest.mark.parametrize("name", COMBOS)
def test_combiner_runs_with_light_children(synth_visible, tmp_path, name):
    from arena.registry import Registry
    d = _light_copy(tmp_path, name)
    info = Registry([d.parent, Path(__file__).parent / "models", ARENA / "models"]).load(d)
    assert set(info.config["children"]) <= set(info.children)
    out = _run(synth_visible, info, episodes=1, targets=("meter.five_hour",), max_backtest_points=3)
    _check(out, ("meter.five_hour",))
    assert any(lg["message"].startswith("weights ") for lg in out.logs)
