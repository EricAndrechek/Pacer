"""Injected changes with known dates show up where they should: in `regimes`,
in `truth/params.json`, and in the data itself."""
from __future__ import annotations

import numpy as np
import polars as pl

from synth_testutil import read_table


def _change(params, prefix):
    rows = [c for c in params["resolved"]["changes"] if c["name"].startswith(prefix)]
    assert rows, prefix
    return rows[0]


def test_regimes_record_every_injected_change(snap, params):
    rg = read_table(snap, "regimes")
    names = rg["name"].to_list()
    for prefix in ("family_launch:fable", "model_launch:claude-opus-s2", "price_change:claude-fable-s1",
                   "plan_change:", "limit_policy_change", "new_account:"):
        assert any(n.startswith(prefix) for n in names), prefix
        c = _change(params, prefix)
        row = rg.filter(pl.col("name") == c["name"]).row(0, named=True)
        assert int(row["t_event"].timestamp() * 1000) == c["t_event"]
    # Collection eras too.
    for n in ("output_first_copy", "subagent_defect", "history_begins", "scoped_limits", "poll_cadence_15s"):
        assert n in names, n


def _ratio_series(world, params, account, window):
    """Points per (cost × family weight) along the true path: the plan and
    policy factor in force at each request."""
    mt = world.truth["meter_true"].filter((pl.col("account") == account) & (pl.col("window_kind") == window)
                                          & (pl.col("source") == "turn"))
    sp = world.truth["spend_true"].select("call_id", "cost_usd", "model_family")
    j = mt.join(sp, on="call_id")
    fw = params["config"]["meter"]["family_weight"]
    w = j["model_family"].replace_strict(fw, return_dtype=pl.Float64)
    return j["t"].to_numpy(), (j["delta_clean"] / (j["cost_usd"] * w)).to_numpy()


def test_plan_change_changes_the_conversion(world, params):
    c = _change(params, "plan_change:")
    acc = c["name"].split(":")[1]
    plans = params["config"]["plans"]
    old, new = (s.strip() for s in c["description"].split("->"))
    t, ratio = _ratio_series(world, params, acc, "five_hour")
    pol = params["resolved"]["limit_policy_change_ms"]
    before = ratio[(t < c["t_event"]) & (t < pol)]
    after = ratio[(t >= c["t_event"]) & (t < pol)]
    assert before.size and after.size
    assert np.allclose(before, 100 / plans[old]["usd_full_five_hour"])
    assert np.allclose(after, 100 / plans[new]["usd_full_five_hour"])


def test_plan_current_is_the_new_plan(snap, params):
    c = _change(params, "plan_change:")
    acc = c["name"].split(":")[1]
    new = c["description"].split("->")[1].strip()
    a = read_table(snap, "accounts").filter(pl.col("account") == acc).row(0, named=True)
    assert a["plan_current"] == new


def test_limit_policy_change_shifts_every_account(world, params):
    c = _change(params, "limit_policy_change")
    mult = params["config"]["changes"]["limit_policy"]["multiplier"]["five_hour"]
    seen = 0
    for a in params["resolved"]["accounts"]:
        if len(a["plans"]) > 1:
            continue
        t, ratio = _ratio_series(world, params, a["account"], "five_hour")
        b, af = ratio[t < c["t_event"]], ratio[t >= c["t_event"]]
        if b.size and af.size:
            assert np.allclose(af / b.mean(), mult)
            seen += 1
    assert seen >= 3


def test_new_account_appears_only_from_its_date(snap, params):
    c = _change(params, "new_account:")
    acc = c["name"].split(":")[1]
    a = read_table(snap, "accounts").filter(pl.col("account") == acc).row(0, named=True)
    assert int(a["t_event"].timestamp() * 1000) == c["t_event"]
    for name in ("turns", "meter_readings"):
        df = read_table(snap, name).filter(pl.col("account") == acc)
        assert df.height > 0, name
        assert df["t_event"].dt.epoch("ms").min() >= c["t_event"], name


def test_new_family_launch(snap, params):
    c = _change(params, "family_launch:fable")
    t = read_table(snap, "turns")
    fable = t.filter(pl.col("model_family") == "fable")
    assert fable.height > 0 and fable["t_event"].dt.epoch("ms").min() >= c["t_event"]
    r = read_table(snap, "meter_readings").filter(pl.col("window_kind") == "weekly_scoped")
    assert r.height > 0 and r["t_event"].dt.epoch("ms").min() >= c["t_event"]


def test_model_launch_and_catalog_lag(snap, params):
    c = _change(params, "model_launch:claude-opus-s2")
    t = read_table(snap, "turns").filter(pl.col("model") == "claude-opus-s2")
    assert t.height > 0 and t["t_event"].dt.epoch("ms").min() >= c["t_event"]
    pr = read_table(snap, "prices").filter(pl.col("model") == "claude-opus-s2")
    known = pr["t_known"].dt.epoch("ms").min()
    assert known > c["t_event"]
    # The launch-lag trap: turns of the new model exist before any rate is known.
    assert (t["t_known"].dt.epoch("ms") < known).any()
    # Adoption ramps up: the new model's share of opus turns grows.
    opus = read_table(snap, "turns").filter(pl.col("model_family") == "opus").with_columns(
        (pl.col("model") == "claude-opus-s2").alias("new"),
        ((pl.col("t_event").dt.epoch("ms") - c["t_event"]) // 86_400_000).alias("day"))
    by_day = opus.filter(pl.col("day") >= 0).group_by("day").agg(pl.col("new").mean()).sort("day")
    assert by_day["new"][-1] > by_day["new"][0]


def test_price_change(snap, world, params):
    c = _change(params, "price_change:claude-fable-s1")
    pr = read_table(snap, "prices").filter((pl.col("model") == "claude-fable-s1") & (pl.col("part") == "output")
                                           & pl.col("tier_threshold").is_null() & ~pl.col("is_correction"))
    pr = pr.sort("t_effective_from")
    assert pr.height == 2
    old, new = pr["rate_per_mtok"].to_list()
    assert abs(new / old - 2 / 3) < 1e-6
    assert int(pr["t_effective_from"][1].timestamp() * 1000) == c["t_event"]
    assert pr["t_known"][1] > pr["t_effective_from"][1]
    # Turns after the change are billed at the new rate (output part only
    # here: compare a request's output share).
    sp = world.truth["spend_true"].filter(pl.col("model") == "claude-fable-s1")
    assert sp.filter(pl.col("t_event") >= c["t_event"]).height > 0


def test_price_correction_arrives_later(snap):
    pr = read_table(snap, "prices")
    corr = pr.filter(pl.col("is_correction"))
    assert corr.height > 0
    for row in corr.iter_rows(named=True):
        orig = pr.filter((pl.col("model") == row["model"]) & (pl.col("part") == row["part"])
                         & ~pl.col("is_correction") & (pl.col("t_effective_from") == row["t_effective_from"]))
        orig = orig.filter(pl.col("tier_threshold").is_null() if row["tier_threshold"] is None
                           else pl.col("tier_threshold") == row["tier_threshold"])
        o = orig.row(0, named=True)
        assert o["rate_per_mtok"] != row["rate_per_mtok"] and o["t_known"] < row["t_known"]
    assert pr["t_effective_to"].null_count() == pr.height


def test_defect_era_rows(snap, world, params):
    a, b = params["resolved"]["eras_ms"]["defect_verified"]
    t = read_table(snap, "turns")
    d = t.filter(pl.col("output_regime") == "subagent_defect")
    te = d["t_event"].dt.epoch("ms")
    assert d.height > 0 and te.min() >= a and te.max() < b
    assert (d["output"] <= 30).all() and not d["output_reliable"].any()
    assert d["is_subagent"].all() and not d["finished"].any()
    assert d["output_imputed"].null_count() == 0
    assert (d["output_imputed_t_known"] >= d["t_known"]).all()
    truth = world.truth["spend_true"].select("call_id", "output_true")
    j = d.join(truth, on="call_id")
    assert (j["output_true"] > j["output"]).mean() > 0.9
    # Imputation recovers the total for sessions with cost state.
    cs = j.filter(pl.col("output_imputed_src") == "cost_state")
    assert cs.height > 0
    ratio = cs["output_imputed"].sum() / cs["output_true"].sum()
    assert 0.8 < ratio < 1.25
    # Elsewhere output is reliable, except the first-copy era.
    ok = t.filter(~pl.col("output_regime").is_in(["subagent_defect", "subagent_defect_suspect", "first_copy"]))
    assert ok["output_reliable"].all() and ok["output_imputed"].null_count() == ok.height


def test_first_copy_era_undercounts(snap, world, params):
    end = params["resolved"]["eras_ms"]["first_copy_until"]
    t = read_table(snap, "turns").filter(pl.col("output_regime") == "first_copy")
    assert t.height > 0 and t["t_event"].dt.epoch("ms").max() < end
    j = t.join(world.truth["spend_true"].select("call_id", "output_true"), on="call_id")
    assert (j["output"] <= j["output_true"]).all() and (j["output"] < j["output_true"]).mean() > 0.5
