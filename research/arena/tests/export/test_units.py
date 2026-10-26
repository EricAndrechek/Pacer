"""Unit tests: pseudonymization, lag-model determinism, tier boundaries,
ACHANGE bitmap decoding, the leak scan."""
import os
import stat

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq
import pytest

from arena.snapshot.schema import TABLES
from export import achange, clocks, layout, validate
from export.pseudo import Hasher, label_accounts, load_or_create_salt, salt_id
from export.util import to_arrow


# --- pseudonymization -------------------------------------------------------

def test_salt_created_0600_and_stable(tmp_path):
    s1 = load_or_create_salt(tmp_path)
    assert len(s1) == 32
    assert stat.S_IMODE((tmp_path / "salt").stat().st_mode) == 0o600
    assert load_or_create_salt(tmp_path) == s1
    assert len(salt_id(s1)) == 8


def test_salt_refuses_loose_permissions(tmp_path):
    load_or_create_salt(tmp_path)
    os.chmod(tmp_path / "salt", 0o644)
    with pytest.raises(PermissionError):
        load_or_create_salt(tmp_path)


def test_hashes_stable_namespaced_and_salted():
    a, b = Hasher(b"\x01" * 32), Hasher(b"\x01" * 32)
    assert a.h("session", "abc") == b.h("session", "abc")
    assert a.h("session", "abc") != a.h("project", "abc")
    assert Hasher(b"\x02" * 32).h("session", "abc") != a.h("session", "abc")
    assert 0 <= a.h("session", "abc") < 2 ** 64
    assert a.h("session", None) is None


def test_accounts_labelled_by_first_seen():
    h = Hasher(b"\x03" * 32)
    labels = label_accounts({"zzz": 100, "aaa": 300, "mmm": 200}, h)
    assert labels == {"zzz": "A1", "mmm": "A2", "aaa": "A3"}
    # equal times: broken by the salted hash, the same every time
    tie = label_accounts({"x": 5, "y": 5}, h)
    assert tie == label_accounts({"y": 5, "x": 5}, h)


# --- lag model ----------------------------------------------------------------

def test_unit_draw_is_a_pure_function_of_id():
    ids = np.array([1, 2, 3, 2 ** 63 + 7], dtype=np.uint64)
    u = clocks.unit_draw(ids, stream=1)
    assert ((u >= 0) & (u < 1)).all()
    np.testing.assert_array_equal(clocks.unit_draw(ids[::-1], stream=1), u[::-1])
    assert not np.array_equal(clocks.unit_draw(ids, stream=2), u)


def test_lag_model_fit_and_draw_deterministic():
    rng = np.random.default_rng(0)
    lags = rng.lognormal(10, 1.5, 5000)
    m1, m2 = clocks.LagModel.fit("x", lags), clocks.LagModel.fit("x", lags[::-1])
    assert m1 == m2
    q = np.array(m1.quantiles_ms)
    assert (np.diff(q) >= 0).all()
    ids = np.arange(1000, dtype=np.uint64)
    d1 = m1.draw(clocks.unit_draw(ids, 1))
    np.testing.assert_array_equal(d1, m2.draw(clocks.unit_draw(ids, 1)))
    assert abs(np.median(d1) - np.median(lags)) / np.median(lags) < 0.2
    assert m1.params()["p99_ms"] >= m1.params()["p50_ms"]


def test_alive_adjust_and_modeled_t_known():
    alive = clocks.Alive.from_polls(np.array([100, 200, 300, 5_000_000, 5_000_100], dtype=np.int64), gap_ms=1000)
    assert list(alive.starts) == [100, 5_000_000] and list(alive.ends) == [300, 5_000_100]
    t = np.array([50, 150, 1000, 6_000_000], dtype=np.int64)
    np.testing.assert_array_equal(alive.adjust(t), [50, 150, 5_000_000, 6_000_000])
    lag = clocks.LagModel("l", tuple(range(0, 201)), 201)
    ids = np.arange(4, dtype=np.uint64)
    tk = clocks.modeled_t_known(t, ids, lag, alive, 1)
    assert (tk >= t).all()
    assert tk[0] == 50 + lag.quantile(0.99)       # before the first poll: p99
    assert tk[2] == 5_000_000                     # in a gap: next poll interval


# --- tiers ------------------------------------------------------------------

W = 7 * 24 * 3_600_000


def test_tier_bounds_3w_3w():
    b = layout.tier_bounds(100 * W, "3w,3w")
    assert b == {"T_train": 94 * W, "T_leaderboard_end": 97 * W, "T_end": 100 * W}
    b = layout.tier_bounds(100 * W, "2w,1w", t_train=90 * W)
    assert b == {"T_train": 90 * W, "T_leaderboard_end": 92 * W, "T_end": 100 * W}
    with pytest.raises(ValueError):
        layout.parse_tiers("3w")
    with pytest.raises(ValueError):
        layout.parse_tiers("3x,1w")


def _table(name, t_known):
    import pandas as pd
    cols = {c: [None] * len(t_known) for c, _ in TABLES[name].columns}
    cols["t_event"] = t_known
    cols["t_known"] = t_known
    cols["t_known_src"] = ["observed"] * len(t_known)
    if name == "meter_readings":
        cols["window_kind"] = ["five_hour"] * len(t_known)
    return to_arrow(name, pd.DataFrame(cols))


def test_write_tables_splits_at_t_train(tmp_path):
    from arena.snapshot.schema import DATA_TABLES, LABEL_TABLES
    day = 86_400_000
    t0 = 1_790_812_800_000
    tables = {n: _table(n, [t0 + i * day for i in range(40)]) for n in list(DATA_TABLES) + list(LABEL_TABLES)}
    t_train = t0 + 20 * day
    counts = layout.write_tables(tmp_path, tables, t_train, t0 + 35 * day)
    assert counts["turns"]["rows"] == {"train": 21, "holdout": 15}
    assert counts["turns"]["dropped_after_T_end"] == 4
    tr = pq.read_table(tmp_path / "train" / "turns", partitioning=None)
    assert tr.column_names == [c for c, _ in TABLES["turns"].columns]
    assert max(tr["t_known"].cast(pa.int64()).to_pylist()) <= t_train
    ho = pq.read_table(tmp_path / "holdout" / "prices.parquet")
    assert min(ho["t_known"].cast(pa.int64()).to_pylist()) > t_train
    assert (tmp_path / "train" / "meter_readings" / "window=five_hour").is_dir()
    assert (tmp_path / "labels" / "cycles.parquet").exists()
    assert sorted(p.name for p in (tmp_path / "train" / "turns").iterdir())[0].startswith("month=")


# --- ACHANGE ----------------------------------------------------------------

TS_COLUMNS = ["Z_PK", "Z_ENT", "Z_OPT", "ZCACHECREATION1HTOKENS", "ZCACHECREATION5MTOKENS", "ZCACHEREADTOKENS",
              "ZINPUTTOKENS", "ZOUTPUTTOKENS", "ZSAMPLEDAT", "ZSOURCECOSTUSD", "ZCCVERSION", "ZDATE", "ZDEDUPKEY",
              "ZMODEL", "ZPROJECTPATH", "ZSESSIONID", "ZORIGINALPROJECTPATH", "ZLOCALHOUR", "ZACCOUNTID",
              "ZINFERENCEGEO", "ZSPEED"]


def test_bitmap_is_msb_first():
    assert achange.decode_bits(bytes([0x80])) == [0]
    assert achange.decode_bits(bytes([0x01])) == [7]
    assert achange.decode_bits(bytes.fromhex("000800")) == [12]
    assert achange.decode_bits(bytes.fromhex("010040")) == [7, 17]
    assert achange.decode_bits(b"") == [] and achange.decode_bits(None) == []


def test_tokensample_attribute_bits():
    order = achange.attribute_order(TS_COLUMNS)
    achange.check_tokensample_order(order)
    assert achange.changed_attributes(bytes.fromhex("800000"), order) == ["ACCOUNTID"]
    assert achange.changed_attributes(bytes.fromhex("000800"), order) == ["OUTPUTTOKENS"]
    assert achange.changed_attributes(bytes.fromhex("000400"), order) == ["PROJECTPATH"]
    assert achange.changed_attributes(bytes.fromhex("010040"), order) == ["INFERENCEGEO", "SPEED"]


def test_attribute_order_change_is_caught():
    with pytest.raises(ValueError):
        achange.check_tokensample_order(achange.attribute_order(TS_COLUMNS + ["ZAAANEW"]))


# --- leak scan ----------------------------------------------------------------

def _strings_table(values):
    return {"t": pa.table({"s": pa.array(values, pa.string()), "l": pa.array([[v] for v in values], pa.list_(pa.string()))})}


def test_leak_scan_catches_each_kind():
    acct = "abcdef12-3456-4789-8abc-def012345678"
    cases = {
        "path": "/Users/someone/x",
        "at_sign": "a@b.example",
        "uuid": acct,
        "account_prefix": "rl-five_hour#abcdef12",
        "project_name": "work on proj-alpha today",
    }
    for kind, v in cases.items():
        g = validate.gate_leak_scan(_strings_table(["ok", v]), ["abcdef12"], ["proj-alpha"])
        assert not g["passed"], kind
        assert kind in g["details"]["hits"]["t.s"], kind
        assert kind in g["details"]["hits"]["t.l"], kind
    g = validate.gate_leak_scan(_strings_table(["finished", "claude-opus-5-5", "A1"]), ["abcdef12"], ["proj-alpha"])
    assert g["passed"]


def test_distinctive_project_names():
    assert validate.distinctive("proj-alpha")
    assert validate.distinctive("research-notes")
    assert not validate.distinctive("history")
    assert not validate.distinctive("Models")
    assert not validate.distinctive("2026-10-21")
    assert validate.distinctive("longwordname")
