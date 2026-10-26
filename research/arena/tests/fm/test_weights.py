"""Weights resolve offline from a hub cache, and every forecaster loads and
forecasts from the local cache alone (each skipped when its weights are
absent or the fm extra is not installed)."""
from __future__ import annotations

import socket

import numpy as np
import pytest

from kit.fm import weights as W

REAL = {
    "timestral": "mistralai/Timestral-5M@bdd20cfc15a3fea0e4cb5ccef37f8d3ca7aa335f",
    "chronos2": "amazon/chronos-2@29ec3766d36d6f73f0696f85560a422f50e8498c",
    "timesfm25": "google/timesfm-2.5-200m-pytorch@1d952420fba87f3c6dee4f240de0f1a0fbc790e3",
    "tirex": "NX-AI/TiRex@63c740922493f5fbe60b277609ec62babfba2762",
    "toto": "Datadog/Toto-Open-Base-1.0@0411ceb27bdf7fc3e4892e99edc8ad08192dc3c5",
    "moirai2": "Salesforce/moirai-2.0-R-small@30f43ff08c8494f4943ae1521e9d4e94a0fbb389",
}


def _fake_cache(root, repo="org/net", revs=("aaa", "bbb"), main="bbb"):
    org, name = repo.split("/")
    d = root / f"models--{org}--{name}"
    for r in revs:
        (d / "snapshots" / r).mkdir(parents=True)
        (d / "snapshots" / r / "config.json").write_text("{}")
    (d / "refs").mkdir()
    (d / "refs" / "main").write_text(main)
    return d


def test_local_snapshot_pinned_main_and_missing(tmp_path, monkeypatch):
    d = _fake_cache(tmp_path)
    monkeypatch.setenv("HF_HUB_CACHE", str(tmp_path))
    assert W.local_snapshot("org/net@aaa") == d / "snapshots" / "aaa"
    assert W.local_snapshot("org/net") == d / "snapshots" / "bbb"          # refs/main
    assert W.local_snapshot("org/net@main") == d / "snapshots" / "bbb"     # a branch name
    with pytest.raises(W.WeightsMissing):
        W.local_snapshot("org/net@ccc")
    with pytest.raises(W.WeightsMissing):
        W.local_snapshot("org/other")
    with pytest.raises(ValueError):
        W.parse_spec("no-slash")
    assert not W.has_weights("org/other") and W.has_weights("org/net@aaa")


def test_hf_home_is_searched(tmp_path, monkeypatch):
    _fake_cache(tmp_path / "hf" / "hub")
    monkeypatch.delenv("HF_HUB_CACHE", raising=False)
    monkeypatch.setenv("HF_HOME", str(tmp_path / "hf"))
    assert W.local_snapshot("org/net@aaa").name == "aaa"


def test_offline_flags_are_set_before_any_hf_import():
    import os
    assert os.environ["HF_HUB_OFFLINE"] == "1" and os.environ["TRANSFORMERS_OFFLINE"] == "1"


@pytest.mark.parametrize("backend", sorted(REAL))
def test_each_forecaster_loads_offline_and_forecasts(backend, torch, monkeypatch):
    if not W.has_weights(REAL[backend]):
        pytest.skip(f"{REAL[backend]} not in the local Hugging Face cache")
    from kit.fm.backends import BACKENDS

    def no_network(*a, **k):
        raise AssertionError("tried to open a network connection")
    monkeypatch.setattr(socket.socket, "connect", no_network)
    b = BACKENDS[backend](REAL[backend], threads=2)
    rng = np.random.default_rng(0)
    x = np.maximum(rng.normal(0.4, 1.0, size=(2, 1, 96)), 0).cumsum(-1)
    x[1, 0, 20:30] = np.nan
    if backend == "toto":
        b.n_samples = 16
    levels, q = b.quantiles(x, 12)
    assert q.shape == (2, 1, 12, len(levels)) and np.isfinite(q).all()
    assert (np.diff(q, axis=-1) >= 0).all()
    assert 0.0 < levels.min() < levels.max() < 1.0
