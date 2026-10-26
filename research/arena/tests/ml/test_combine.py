"""Combiners: weights move toward the better child, both from a synthetic
ledger and end to end through the runner (children run by the runner,
backtests without hindsight, truth arriving through update)."""
from __future__ import annotations

import shutil
import tomllib
from pathlib import Path

import numpy as np
import pytest

from arena.cache import ChildCache
from arena.registry import Registry
from arena.runner import RunConfig, Runner
from arena.types import Target
from kit.ml.combine import (
    FformaWeights, Group, Entry, ewa_weights, pool_median, pool_mixture, pool_quantile, relative_losses,
    stack_weights,
)
from kit.ml.paths import crps_paths, crps_sorted, sorted_samples

HERE = Path(__file__).parent
ARENA = HERE.parent.parent
H = 3_600_000


def _group(origin, y, children, rng, m=40):
    """One forecast origin with truth y at 12 readings; `children` maps a
    name to (bias, spread) of its samples around the truth."""
    times = origin + np.arange(1, 13) * 600_000
    grid = origin + np.arange(1, 25) * 300_000
    g = Group(origin, "meter.five_hour:A1", "five_hour", Target.METER_5H, "A1", None, origin + 5 * H)
    for name, (bias, spread) in children.items():
        center = np.interp(grid, times, y) + bias
        q = np.sort(center[None, :] + rng.normal(0, spread, size=(m, len(grid))), axis=0)
        g.entries[name] = Entry(name, origin, g.key, g.kind, g.target, "A1", None, g.reset, grid, q.astype(np.float32))
    g.times, g.y, g.scored_at, g.final = times.astype(np.int64), np.asarray(y, float), origin + 6 * H, True
    return g


def _groups(n, spec, seed=0, start=0):
    rng = np.random.default_rng(seed)
    out = []
    for k in range(n):
        y = np.cumsum(rng.uniform(0, 2, 12)) + 10
        out.append(_group(start + k * H, y, spec, rng))
    return out


SPEC = {"good": (0.0, 1.5), "bad": (12.0, 1.5)}


def test_crps_helpers_agree():
    rng = np.random.default_rng(1)
    P = rng.normal(5, 2, size=(200, 7))
    y = rng.normal(5, 2, size=7)
    assert np.allclose(crps_paths(P, y), crps_sorted(sorted_samples(P, 200), y))
    # The empirical CRPS: E|X - y| - E|X - X'| / 2, by brute force.
    brute = np.abs(P - y).mean(0) - 0.5 * np.abs(P[:, None, :] - P[None, :, :]).mean((0, 1))
    assert np.allclose(crps_paths(P, y), brute)


def test_relative_losses_rank_the_children():
    R = relative_losses(_groups(10, SPEC), ["good", "bad"])
    assert (R[:, 0] < R[:, 1]).all()


@pytest.mark.parametrize("rule", ["ewa", "stack-mixture", "stack-quantile", "fforma"])
def test_weights_favour_the_better_child(rule):
    groups = _groups(30, SPEC)
    now = 31 * H
    kids = ["good", "bad"]
    if rule == "ewa":
        w = ewa_weights(groups, kids, now, eta=0.5, half_life=48)
    elif rule.startswith("stack"):
        w = stack_weights(groups, kids, now, pool=rule.split("-")[1], half_life=48)
    else:
        fw = FformaWeights(kids, ["five_hour"], lam=0.1)
        X = np.random.default_rng(3).normal(size=(len(groups), 4))
        fw.fit(X, relative_losses(groups, kids), np.ones(len(groups)))
        w = fw.weights(X[0])
    assert w[0] > 0.8, (rule, w)
    assert abs(w.sum() - 1) < 1e-9


def test_ewa_moves_toward_whoever_is_better_as_truth_arrives():
    """The bad child is better first, then the good one: the weight on the
    good one rises as the later truth comes in."""
    early = _groups(15, {"good": (12.0, 1.5), "bad": (0.0, 1.5)}, seed=1)
    late = _groups(15, {"good": (0.0, 1.5), "bad": (12.0, 1.5)}, seed=2, start=15 * H)
    kids = ["good", "bad"]
    w = [ewa_weights(early + late[:k], kids, (15 + k) * H, eta=0.5, half_life=6)[0] for k in (0, 5, 10, 15)]
    assert w[0] < 0.2 and w[-1] > 0.8 and all(b >= a for a, b in zip(w, w[1:])), w


def test_fforma_weights_depend_on_features():
    """Child A is better when x > 0, B when x < 0: the map learns it."""
    rng = np.random.default_rng(5)
    x = rng.normal(size=(80, 1))
    R = np.where(x > 0, [[0.5, 1.5]], [[1.5, 0.5]])
    fw = FformaWeights(["a", "b"], ["five_hour"], lam=0.01)
    fw.fit(x, R, np.ones(len(x)))
    assert fw.weights(np.array([2.0]))[0] > 0.8
    assert fw.weights(np.array([-2.0]))[0] < 0.2


def test_pools_keep_shape_and_order():
    rng = np.random.default_rng(2)
    a, b = rng.normal(0, 1, (200, 5)), rng.normal(10, 1, (200, 5))
    mix = pool_mixture([a, b], np.array([0.75, 0.25]), 200, rng)
    assert mix.shape == (200, 5) and abs((mix[:, 0] > 5).mean() - 0.25) < 0.02
    q = pool_quantile([a, b], np.array([0.5, 0.5]), 200)
    assert q.shape == (200, 5) and abs(np.median(q[:, 0]) - 5) < 0.5
    med = pool_median([a, b, b], 200)
    assert abs(np.median(med[:, 0]) - 10) < 0.5


# ---------------------------------------------------------------------------
# End to end
# ---------------------------------------------------------------------------

def _combiner_copy(tmp_path: Path, name: str, children: list[str], **config) -> Path:
    """The committed combiner's code with a test model.toml: test children
    and a small backtest."""
    src = ARENA / "models" / name
    dst = tmp_path / "models" / f"{name}-t"
    dst.mkdir(parents=True)
    shutil.copy(src / "model.py", dst / "model.py")
    meta = tomllib.loads((src / "model.toml").read_text())
    cfg = {**meta.get("config", {}), "children": children, **config}

    def val(v):
        if isinstance(v, dict):
            return "{ " + ", ".join(f"{k} = {val(x)}" for k, x in v.items()) + " }"
        if isinstance(v, str):
            return f'"{v}"'
        if isinstance(v, bool):
            return "true" if v else "false"
        if isinstance(v, list):
            return "[" + ", ".join(val(x) for x in v) + "]"
        return repr(v)
    lines = [f'name = "{name}-t"', f'targets = {val(meta["targets"])}', f"children = {val(children)}", "[config]"]
    lines += [f"{k} = {val(v)}" for k, v in cfg.items()]
    (dst / "model.toml").write_text("\n".join(lines) + "\n")
    return dst


@pytest.mark.parametrize("name", ["combo-ewa", "combo-stack", "combo-fforma"])
def test_runner_weights_move_to_the_better_child(synth_visible, tmp_path, name):
    folder = _combiner_copy(tmp_path, name, ["mltest-flat", "mltest-low"],
                            backtest_every_h={"five_hour": 2, "seven_day": 6, "weekly_scoped": 6}, min_groups=4)
    reg = Registry([tmp_path / "models", HERE / "models", ARENA / "models"])
    cfg = RunConfig(episodes=3, seed=11, in_process=True, checkpoint_cap=4, max_backtest_points=12,
                    targets=("meter.seven_day",))
    out = Runner(synth_visible, cfg, cache=ChildCache(enabled=False)).run([reg.load(folder)])
    assert not out.failures, out.failures[:3]
    w = [lg for lg in out.logs if lg["message"].startswith("weights ")]
    assert w, [lg["message"] for lg in out.logs][:10]
    by: dict = {}
    for lg in w:
        key = (lg["episode_id"], lg["message"].split(" ")[1])
        by.setdefault(key, []).append(float(lg["message"].split("mltest-flat=")[1].split(",")[0]))
    flat = [x for v in by.values() for x in v]
    assert np.mean(flat) > 0.6, by
    assert all(v[-1] > 0.6 for v in by.values()), by
    if name == "combo-ewa":
        # EWA's weight moves further toward it as the episode's truth arrives
        # (stacking re-optimizes and may trade a little weight for spread).
        assert all(v[-1] >= v[0] - 1e-3 for v in by.values()), by
        assert any(v[-1] > v[0] + 1e-3 for v in by.values()), by
    assert any(lg["message"].startswith("backtest mltest-flat") and " 0 origins" not in lg["message"]
               for lg in out.logs)
