"""Meter semantics: integer readings capped at 100, idle rows, monotone within
a cycle, and cycles that start at the first use after the previous reset."""
from __future__ import annotations

import numpy as np
import polars as pl

from synth.config import HOUR_MS, WINDOW_MS
from synth_testutil import read_table

CANON = ("five_hour", "seven_day", "weekly_scoped")


def _cycle_groups(r: pl.DataFrame) -> pl.DataFrame:
    """Split readings into cycles the way a reader must: a new cycle when
    resets_at moves by more than half a window (never ==)."""
    r = r.filter(pl.col("state") == "active").sort(["account", "window_kind", "source", "t_event"])
    half = pl.col("window_kind").replace_strict({k: v // 2 for k, v in WINDOW_MS.items()}, return_dtype=pl.Int64)
    jump = (pl.col("resets_at").dt.epoch("ms").diff().abs() > half).over(["account", "window_kind", "source"])
    return r.with_columns(jump.fill_null(True).cast(pl.Int32).cum_sum().over(
        ["account", "window_kind", "source"]).alias("grp"))


def test_utilisation_is_integer_and_capped(snap):
    r = read_table(snap, "meter_readings")
    u = r["util_pct"]
    assert (u == u.round()).all() and u.min() >= 0 and u.max() <= 100
    assert (u == 100).any(), "some cycle should reach the limit"


def test_idle_rows(snap):
    r = read_table(snap, "meter_readings")
    idle = r.filter(pl.col("state") == "idle")
    assert idle.height > 0
    assert idle["resets_at"].null_count() == idle.height
    assert (idle["util_pct"] == 0).all()
    assert r.filter(pl.col("state") == "active")["resets_at"].null_count() == 0


def test_monotone_within_a_cycle_except_flagged(snap):
    r = _cycle_groups(read_table(snap, "meter_readings").filter(pl.col("window_kind").is_in(list(CANON))))
    r = r.with_columns(pl.col("util_pct").cum_max().shift(1).over(["account", "window_kind", "source", "grp"])
                       .alias("prev_max"))
    fell = r.filter(pl.col("prev_max").is_not_null() & (pl.col("util_pct") < pl.col("prev_max")))
    assert fell.height > 0, "the generator injects a few backwards readings"
    assert (fell["backwards_pp"] == fell["prev_max"] - fell["util_pct"]).all()
    assert r.filter(pl.col("backwards_pp") > 0).height == fell.height
    # Rare: most drops are a single point.
    assert (fell["backwards_pp"] == 1).mean() > 0.5
    assert fell.height < 0.01 * r.height


def test_reset_jitter_is_milliseconds(snap):
    r = _cycle_groups(read_table(snap, "meter_readings").filter(pl.col("window_kind").is_in(list(CANON))))
    spread = r.group_by(["account", "window_kind", "source", "grp"]).agg(
        (pl.col("resets_at").dt.epoch("ms").max() - pl.col("resets_at").dt.epoch("ms").min()).alias("s"))
    assert spread["s"].max() <= 5_000
    assert spread["s"].quantile(0.5) > 0, "resets_at must jitter, so == never matches a cycle"


def test_true_cycles_start_at_first_use_after_reset(world, params):
    floor = params["config"]["meter"]["start_floor_min"]
    cyc = world.truth["cycles_true"].filter(pl.col("window_kind") != "weekly_scoped")
    mt = world.truth["meter_true"].filter(pl.col("window_kind") != "weekly_scoped")
    for (acc, wk), g in cyc.group_by(["account", "window_kind"]):
        g = g.sort("start")
        start, first, reset = (g[c].to_numpy() for c in ("start", "first_use", "reset_at"))
        assert (reset - start == WINDOW_MS[wk]).all()
        assert (start == first - first % (floor[wk] * 60_000)).all()
        assert (first < reset).all()
        assert (start[1:] >= reset[:-1]).all(), "cycles never overlap"
        inc_t = np.sort(mt.filter((pl.col("account") == acc) & (pl.col("window_kind") == wk))["t"].to_numpy())
        # Every increment lies in a cycle; the first increment at or after a
        # reset is the next cycle's first use.
        k = np.searchsorted(first, inc_t, side="right") - 1
        assert (k >= 0).all() and (inc_t < reset[k]).all()
        nxt = np.searchsorted(inc_t, reset[:-1], side="left")
        has = nxt < inc_t.size
        assert (inc_t[nxt[has]] == first[1:][has]).all()


def test_true_path_is_cumulative_within_cycles(world):
    mt = world.truth["meter_true"].sort(["account", "window_kind", "cycle_idx", "t", "util_clean"])
    chk = mt.with_columns(
        pl.col("delta_clean").cum_sum().over(["account", "window_kind", "cycle_idx"]).alias("c"),
        pl.col("delta_actual").cum_sum().over(["account", "window_kind", "cycle_idx"]).alias("a"))
    assert np.allclose(chk["c"], chk["util_clean"], rtol=1e-9, atol=1e-9)
    assert np.allclose(chk["a"], chk["util_actual"], rtol=1e-9, atol=1e-9)


def test_nothing_is_served_past_the_limit(world):
    """Once a cycle's actual value reaches 100, the account serves no more
    requests until it resets (5h/7d), and no more premium requests (scoped)."""
    mt = world.truth["meter_true"].sort(["account", "window_kind", "cycle_idx", "t"])
    after = mt.with_columns(
        (pl.col("util_actual") - pl.col("delta_actual")).alias("before"))
    over = after.filter(pl.col("before") >= 100.0)
    assert over.height == 0, over.head()
    # And some cycles did reach it.
    assert (mt["util_actual"] >= 100).any()


def test_limit_hits_happen_on_full_accounts(world):
    lh = world.tables["limit_hits"]
    mt = world.truth["meter_true"].filter(pl.col("window_kind").is_in(["five_hour", "seven_day"]))
    full = mt.filter(pl.col("util_actual") >= 100).group_by(["account", "window_kind", "cycle_idx"]).agg(
        pl.col("t").min().alias("full_t"), pl.col("reset_at").first())
    j = lh.join(full, on="account").filter((pl.col("t_event") >= pl.col("full_t")) & (pl.col("t_event") < pl.col("reset_at")))
    assert j.select("t_event", "account", "session_h").unique().height == lh.height


def test_readings_match_the_true_meter(world, params):
    """A reading is the server's actual value at t - server_lag, floored and
    capped (backwards readings aside)."""
    r = world.tables["meter_readings"].filter(pl.col("_active") & (pl.col("backwards_pp") == 0))
    exp = np.minimum(100.0, np.floor(r["_util_true"].to_numpy() + 1e-9))
    assert (r["util_pct"].to_numpy() == exp).all()


def test_twins_carry_the_canonical_values(snap):
    r = read_table(snap, "meter_readings").filter(pl.col("dup_group").is_not_null())
    twin_of = {"session": "five_hour", "weekly_all": "seven_day"}
    tw = r.filter(pl.col("window_kind").is_in(list(twin_of))).with_columns(
        pl.col("window_kind").replace_strict(twin_of).alias("canon"))
    j = tw.join(r, left_on=["dup_group", "canon"], right_on=["dup_group", "window_kind"], suffix="_c")
    assert j.height == tw.height
    assert (j["util_pct"] == j["util_pct_c"]).all() and (j["t_event"] == j["t_event_c"]).all()


def test_cycles_label_matches_truth(snap, world):
    """The cycles label (from readings) finds the true cycles, resets within
    the jitter, and never invents one."""
    lab = pl.read_parquet(snap / "labels" / "cycles.parquet")
    tru = world.truth["cycles_true"]
    j = lab.with_columns(pl.col("reset_at").dt.epoch("ms").alias("r")).join(
        tru.with_columns(pl.col("reset_at").alias("tr")), on=["account", "window_kind"])
    j = j.filter((pl.col("r") - pl.col("tr")).abs() <= 5_000)
    assert j.select("cycle_id").n_unique() == lab.height
    # Every true 5h cycle with an active poll inside it is labelled.
    assert lab.filter(pl.col("window_kind") == "five_hour").height >= 0.8 * \
        tru.filter(pl.col("window_kind") == "five_hour").height


def test_anchored_seven_day_mode():
    """The alternative weekly rule: a fixed weekly reset per account."""
    from synth import simulate
    from synth.writer import validate
    from synth.tables import to_arrow
    from synth_testutil import small_config

    w = simulate(small_config(users=2, days=28, meter={"seven_day_mode": "anchored"}))
    cyc = w.truth["cycles_true"].filter(pl.col("window_kind") == "seven_day")
    added = {a["account"]: a["added_ms"] for a in w.params["resolved"]["accounts"]}
    for row in cyc.iter_rows(named=True):
        anchor = added[row["account"]] - added[row["account"]] % HOUR_MS
        assert (row["start"] - anchor) % WINDOW_MS["seven_day"] == 0
    assert validate(w, {n: to_arrow(n, df) for n, df in w.tables.items()})["ok"]
