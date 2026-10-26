"""Timestral end to end through the real runner on `synth-default`: the meter
model, the spend model and the structural model (child called through the
runner). Skipped without the snapshot, the weights or the fm extra."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest
from conftest import default_arena_home_with

from kit.fm.weights import has_weights

ARENA = Path(__file__).resolve().parents[2]
SPEC = "mistralai/Timestral-5M@bdd20cfc15a3fea0e4cb5ccef37f8d3ca7aa335f"
HOME = default_arena_home_with("synth-default")

pytestmark = [
    pytest.mark.skipif(HOME is None, reason="no synth-default snapshot (uv run arena synth --out synth-default --seed 1)"),
    pytest.mark.skipif(not has_weights(SPEC), reason="Timestral-5M not in the local Hugging Face cache"),
]


def _run(monkeypatch, model: str, targets: tuple[str, ...], episodes: int = 2):
    pytest.importorskip("torch", reason="the fm extra is not installed")
    monkeypatch.setenv("ARENA_HOME", str(HOME))
    from arena.cache import ChildCache
    from arena.registry import Registry
    from arena.runner import RunConfig, Runner
    from arena.snapshot.views import SnapshotData
    data = SnapshotData.load("synth-default", "visible")
    cfg = RunConfig(tier="visible", episodes=episodes, seed=3, targets=targets, in_process=True,
                    checkpoint_cap=4, n_paths=64)
    info = Registry([ARENA / "models"]).load(model)
    return Runner(data, cfg, cache=ChildCache(enabled=False)).run([info])


def _crps(out, target):
    v = [s["value"] for s in out.scores if s["target"] == target and s["metric"] == "crps" and s["lead_s"] is None]
    return np.asarray(v)


def test_meter_model_scores_on_synth(monkeypatch):
    out = _run(monkeypatch, "fm-timestral-5m-meter", ("meter.five_hour", "meter.seven_day"))
    assert not out.failures, [f["message"][-500:] for f in out.failures]
    for t in ("meter.five_hour", "meter.seven_day"):
        c = _crps(out, t)
        assert len(c) and np.isfinite(c).all() and (c >= 0).all()


def test_spend_model_scores_on_synth(monkeypatch):
    out = _run(monkeypatch, "fm-timestral-5m-spend", ("spend.hourly", "tokens.hourly"))
    assert not out.failures, [f["message"][-500:] for f in out.failures]
    c = _crps(out, "spend.hourly")
    assert len(c) and np.isfinite(c).all()


def test_structural_model_calls_its_child_through_the_runner(monkeypatch):
    out = _run(monkeypatch, "struct-timestral-5m", ("meter.five_hour",), episodes=1)
    assert not out.failures, [f["message"][-500:] for f in out.failures]
    assert not [lg for lg in out.logs if "failed" in lg["message"]], out.logs[:3]
    c = _crps(out, "meter.five_hour")
    assert len(c) and np.isfinite(c).all()
