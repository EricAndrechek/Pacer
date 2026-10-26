"""Deterministic quantiles (kit/detq.py) and the port fixtures
(arena/cli_portfix.py): the exact quantiles agree with the quantiles of the
model's own sampled paths within Monte-Carlo error, a fixture's outputs are
reproduced from its inputs alone, and real snapshots are refused."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import numpy as np
import polars as pl
import pytest

from arena.types import Request, Scope, Target, TargetRequest
from kit import detq
from kit.calib import read_sorted

N_MC = 4000


def _weights_cached(spec: str) -> bool:
    try:
        from kit.fm.weights import local_snapshot
        local_snapshot(spec)
        return True
    except Exception:  # noqa: BLE001 - absent weights or extras: the test skips
        return False


TIMESTRAL_5M = "mistralai/Timestral-5M@bdd20cfc15a3fea0e4cb5ccef37f8d3ca7aa335f"
needs_timestral = pytest.mark.skipif(not _weights_cached(TIMESTRAL_5M), reason="Timestral-5M weights not cached")


@pytest.fixture(scope="module")
def cases(calib_data):
    from arena.cli_portfix import pick_cases
    from arena.episodes import TierIndex
    return pick_cases(TierIndex(calib_data), 4, 7)


def _request(case, n_paths=N_MC):
    from arena.cli_portfix import fixture_grid
    from arena.episodes import target_key
    grid = fixture_grid(case["target"], case["now"], case["reset_at"])
    key = target_key(case["target"], (case["account"],))
    tr = TargetRequest(key, case["target"], (case["account"],), grid, "pct", n_paths, None, None, case["reset_at"])
    return Request(case["now"], Scope((case["account"],)), (tr,)), key


def _fitted(calib_data, info, case):
    from arena.cli_portfix import Local
    local = Local(calib_data)
    view = calib_data.view(Scope((case["account"],)), "current_code", case["start"])
    return local.instance(info, view, case["now"])


def _within_mc(exact: np.ndarray, paths: np.ndarray, levels, slack: float = 0.0) -> bool:
    """Each exact quantile lies between the paths' order statistics at the
    level -/+ 5 standard errors of an n-sample quantile (plus `slack`
    points). Order statistics, not interpolation: the analog's values are
    whole points, and an interpolated band edge would fall between two atoms."""
    S = np.sort(paths, axis=0)
    n = S.shape[0]
    lv = np.asarray(levels)
    d = 5.0 * np.sqrt(lv * (1 - lv) / n)
    lo = S[np.clip(np.floor((lv - d) * n).astype(int), 0, n - 1)]
    hi = S[np.clip(np.ceil((lv + d) * n).astype(int), 0, n - 1)]
    return bool(((exact >= lo - slack - 1e-9) & (exact <= hi + slack + 1e-9)).all())


def test_analog_quantiles_agree_with_its_paths(calib_data, calib_registry, cases):
    info = calib_registry.load("g1-10-fable-analog")
    seen_exact = 0
    for case in cases:
        req, key = _request(case)
        m = _fitted(calib_data, info, case)
        d = detq.quantiles(m, req)[key]
        P = m.forecast(req).by_key[key].paths
        # slack 1: the model shrinks its draws toward their SAMPLE median, the
        # exact form toward the distribution's; when the weight below an atom
        # is within noise of 1/2 the two medians are adjacent whole points,
        # which moves a shrunk value by at most one.
        assert _within_mc(d.q, P, d.levels, slack=1.0), (case, d.exact)
        assert np.allclose(d.median, d.q[list(d.levels).index(0.5)])
        if case["target"] is Target.METER_5H and d.exact:
            seen_exact += 1
            assert np.all(d.q == np.rint(d.q))                     # whole points, like the paths
        if not d.exact:
            assert d.mc_paths == detq.MC_PATHS and (d.lo <= d.q).all() and (d.q <= d.hi).all()
    assert seen_exact >= 1


@needs_timestral
@pytest.mark.skipif(importlib.util.find_spec('torch') is None, reason='needs the fm extra (torch)')
def test_timestral_quantiles_agree_with_its_paths(calib_data, calib_registry, cases):
    info = calib_registry.load("fm-timestral-5m-meter")
    for case in cases:
        req, key = _request(case)
        m = _fitted(calib_data, info, case)
        d = detq.quantiles(m, req)[key]
        assert d.exact
        P = m.forecast(req).by_key[key].paths
        # Comonotone stratified paths: path i sits at level (i + 0.5) / n, so
        # the exact quantile at a level lies between the paths read one 1/n
        # step either side of it (a bend, like the clip at 100, can sit in
        # between).
        S, n = np.sort(P, axis=0), P.shape[0]
        lo, hi = read_sorted(S, d.levels - 1.0 / n), read_sorted(S, d.levels + 1.0 / n)
        assert ((d.q >= lo - 1e-6) & (d.q <= hi + 1e-6)).all()
        assert np.abs(read_sorted(S, d.levels) - d.q).mean() < 0.05
        assert set(d.detail) >= {"context", "used", "horizon_steps"}


@needs_timestral
@pytest.mark.skipif(importlib.util.find_spec('torch') is None, reason='needs the fm extra (torch)')
def test_calibrated_quantiles_agree_with_calibrated_paths(calib_data, calib_registry, cases):
    """The layer applied to the child's exact quantile curves gives what it
    gives applied to the child's paths, within Monte-Carlo error."""
    info = calib_registry.load("calib-fm-timestral-5m-meter")
    for case in cases[:2]:
        req, key = _request(case)
        m = _fitted(calib_data, info, case)
        d = detq.quantiles(m, req)[key]
        fit = d.detail["fit"]
        assert fit is not None
        P = m.forecast(req).by_key[key].paths
        assert _within_mc(d.q, P, d.levels, slack=0.05), case


@pytest.mark.parametrize("name,target", [("g1-10-fable-analog", Target.METER_5H),
                                         ("spend-decay-30m", Target.METER_5H),
                                         ("spend-decay-6h", Target.METER_7D)])
def test_fixture_reproduces_from_its_own_inputs(calib_data, calib_registry, cases, name, target):
    """A fixture's outputs come back exactly from its inputs alone: a
    snapshot rebuilt from the JSON's readings (and spend), nothing else
    (what a port's test does)."""
    from arena.cli_portfix import Local, fixture_pricing, is_spend_model, make_case, snapshot_from_case
    info = calib_registry.load(name)
    case = next(c for c in cases if c["target"] is target)
    io, out = make_case(calib_data, info, case, include_raw=True)
    doc = json.loads(json.dumps({"io": io, "out": out}))            # what lands on disk
    inp, rq = doc["io"]["inputs"], doc["io"]["request"]
    assert ("turns" in inp) == is_spend_model(info)
    small = snapshot_from_case(doc["io"])
    local = Local(small, tz_offset_min=inp["tz_offset_min"])
    tr = TargetRequest(rq["key"], Target(rq["target"]), (rq["account"],), np.asarray(rq["grid"], np.int64), "pct",
                       200, None, None, rq["reset_at"])
    req = Request(rq["now"], Scope((rq["account"],)), (tr,))
    view = small.view(req.scope, "current_code", inp["history_start"])
    with fixture_pricing():
        m = local.instance(info, view, rq["now"])
        d = detq.quantiles(m, req)[rq["key"]]
    assert d.exact == doc["out"]["exact"]
    assert np.allclose(d.q, np.asarray(doc["out"]["quantiles"], dtype=float), atol=1e-6)


@pytest.mark.parametrize("name,target", [("spend-decay-30m", Target.METER_5H), ("spend-decay-6h", Target.METER_7D)])
def test_spend_decay_quantiles_agree_with_its_paths(calib_data, calib_registry, cases, name, target):
    info = calib_registry.load(name)
    seen = 0
    for case in cases:
        if case["target"] is not target:
            continue
        req, key = _request(case)
        m = _fitted(calib_data, info, case)
        d = detq.quantiles(m, req)[key]
        assert d.exact
        P = m.forecast(req).by_key[key].paths
        assert _within_mc(d.q, P, d.levels), (case, d.detail.get("mode"))
        seen += 1
    assert seen


def test_port_fixtures_refuse_a_real_snapshot(tmp_path, monkeypatch):
    from arena import cli_portfix
    home = tmp_path / "home"
    snap = home / "snapshots" / "real-one"
    snap.mkdir(parents=True)
    (snap / "manifest.json").write_text(json.dumps({"snapshot_id": "real-one", "frozen": True}))
    monkeypatch.setenv("ARENA_HOME", str(home))
    rc = cli_portfix.main(["port-fixtures", "--model", "g1-10-fable-analog", "--snapshot", "real-one",
                           "--cases", "1", "--out", str(tmp_path / "out")])
    assert rc == 2 and not (tmp_path / "out").exists()
    (snap / "manifest.json").write_text(json.dumps({"snapshot_id": "real-one", "synthetic": True}))
    assert not cli_portfix.is_synthetic("real-one")                   # no truth/ folder: still refused


# ---------------------------------------------------------------------------
# The committed fixtures (findings/2026-10-port/fixtures)
# ---------------------------------------------------------------------------

FIXTURES = Path(__file__).resolve().parents[2] / "findings" / "2026-10-port" / "fixtures"
needs_fixtures = pytest.mark.skipif(not (FIXTURES / "cases.json").is_file(), reason="no committed fixtures")


@needs_fixtures
def test_committed_fixtures_are_small_and_consistent():
    files = sorted(FIXTURES.glob("*.json"))
    assert sum(f.stat().st_size for f in files) < 1_400_000
    cases = {c["id"]: c for c in json.loads((FIXTURES / "cases.json").read_text())["cases"]}
    spend = {c["id"]: c for c in json.loads((FIXTURES / "cases-spend.json").read_text())["cases"]}
    assert len(cases) >= 20 and len(spend) >= 12
    for cs in (cases, spend):
        assert {c["request"]["target"] for c in cs.values()} == {"meter.five_hour", "meter.seven_day"}
    assert all("turns" in c["inputs"] for c in spend.values())
    cases.update(spend)
    models = [f for f in files if not f.name.startswith("cases")]
    assert {json.loads(f.read_text())["model"] for f in models} >= {
        "spend-decay-30m", "spend-decay-6h", "calib-spend-decay-30m", "calib-spend-decay-6h",
        "g1-10-fable-analog", "fm-timestral-5m-meter", "calib-g1-10-fable-analog", "calib-fm-timestral-5m-meter"}
    for f in models:
        doc = json.loads(f.read_text())
        assert doc["format"].startswith("pacer-arena-port-fixture/")
        for out in doc["outputs"]:
            case = cases[out["case"]]
            G = len(case["request"]["grid"])
            q = np.asarray(out["quantiles"], dtype=float)
            assert q.shape == (7, G) and len(out["median"]) == G
            assert (np.diff(q, axis=0) >= -1e-9).all()                 # levels never cross
            assert np.allclose(out["median"], q[3])
            if not out["exact"]:
                lo, hi = np.asarray(out["mc_bounds"]["lo"], float), np.asarray(out["mc_bounds"]["hi"], float)
                assert (lo <= q + 1e-9).all() and (q <= hi + 1e-9).all()


@needs_fixtures
def test_fit_parity_records_refit_to_the_stored_maps():
    from kit import calib as C
    seen = 0
    for f in FIXTURES.glob("calib-*.json"):
        for fp in json.loads(f.read_text()).get("fit_parity", []):
            r = fp["records"]
            args = (fp["kind"], np.asarray(r["q"], float), np.asarray(r["y"], float), np.asarray(r["lead_s"], float),
                    np.asarray(r["origin"], np.int64))
            for meth, want in fp["fits"].items():
                got = C.fit_kind(*args, meth, fp["n0"], fp["n0_bin"], fp["min_origins"],
                                 np.asarray(r["floor"], float), np.asarray(r["whole"], bool), fp["s_max"]).to_json()
                for k in C.SIDES:
                    assert np.allclose(got[k], want[k], rtol=1e-9, atol=1e-12), (f.name, fp["kind"], meth, k)
                seen += 1
    assert seen >= 2
