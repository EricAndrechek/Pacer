"""A model that knows the truth can rebuild the meter.

Independent of the generator's code: these tests read only the written files
(the snapshot, `truth/params.json`, `truth/spend_true.parquet`,
`truth/unobserved.parquet`) and recompute
1. every turn's cost from the published `prices` table (final rates), and
2. the whole meter path — cycles by the first-use rule, points by plan,
   family weight and policy — then compare with `truth/meter_true.parquet`
   and with the readings themselves.
"""
from __future__ import annotations

import numpy as np
import polars as pl

from synth_testutil import read_table

PARTS = ("input", "output", "cache_read", "cache_write_5m", "cache_write_1h")
TOKS = ("input", "output_true", "cache_read", "cache_write_5m", "cache_write_1h")


def _final_rates(prices: pl.DataFrame) -> dict:
    """(model, part, tier) -> sorted [(from_ms, rate)], each period's final
    rate: a correction beats the original, then the later t_known."""
    p = prices.with_columns(pl.col("t_effective_from").dt.epoch("ms").alias("f"),
                            pl.col("t_known").dt.epoch("ms").alias("k"))
    p = p.sort(["model", "part", "tier_threshold", "f", "is_correction", "k"], nulls_last=False)
    final = p.group_by(["model", "part", "tier_threshold", "f"], maintain_order=True).last()
    out: dict = {}
    for r in final.iter_rows(named=True):
        out.setdefault((r["model"], r["part"], r["tier_threshold"]), []).append((r["f"], r["rate_per_mtok"]))
    return out


def _rate(table, model, part, tier, t):
    periods = table.get((model, part, tier))
    if not periods:
        return None
    fs = [f for f, _ in periods]
    i = int(np.searchsorted(fs, t, side="right")) - 1
    return periods[i][1] if i >= 0 else None


def test_turn_costs_reprice_from_the_prices_table(snap):
    rates = _final_rates(read_table(snap, "prices"))
    sp = pl.read_parquet(snap / "truth" / "spend_true.parquet")
    thresholds = {m: t for (m, _, t) in rates if t is not None}
    got = []
    for r in sp.iter_rows(named=True):
        t = int(r["t_event"].timestamp() * 1000)
        prompt = r["input"] + r["cache_read"] + r["cache_write_5m"] + r["cache_write_1h"]
        thr = thresholds.get(r["model"])
        tier = thr if thr is not None and prompt > thr else None
        got.append(sum(r[tk] * _rate(rates, r["model"], part, tier, t) for part, tk in zip(PARTS, TOKS)) / 1e6)
    assert np.allclose(got, sp["cost_usd"].to_numpy(), rtol=1e-9, atol=1e-12)


def _reference_meter(snap, params) -> pl.DataFrame:
    cfg, res = params["config"], params["resolved"]
    plans, fw = cfg["plans"], cfg["meter"]["family_weight"]
    floor = {k: v * 60_000 for k, v in cfg["meter"]["start_floor_min"].items()}
    W = {"five_hour": 5 * 3_600_000, "seven_day": 7 * 86_400_000}
    pol_at = res["limit_policy_change_ms"]
    mult = cfg["changes"]["limit_policy"]["multiplier"]
    acc_plans = {a["account"]: [(p["from_ms"], p["plan"]) for p in a["plans"]] for a in res["accounts"]}

    def plan_at(acc, t):
        cur = acc_plans[acc][0][1]
        for f, p in acc_plans[acc]:
            if t >= f:
                cur = p
        return cur

    sp = pl.read_parquet(snap / "truth" / "spend_true.parquet").select(
        "account", pl.col("t_event").dt.epoch("ms").alias("t"), "cost_usd", "model_family", "meter_noise",
        pl.lit(0).alias("kind"))
    uo = pl.read_parquet(snap / "truth" / "unobserved.parquet").select(
        "account", pl.col("t").dt.epoch("ms").alias("t"),
        "cost_usd", pl.lit("other").alias("model_family"), "meter_noise", pl.lit(1).alias("kind"))
    ev = pl.concat([sp, uo]).sort(["account", "t", "kind"])
    rows = []
    for (acc,), g in ev.group_by(["account"], maintain_order=True):
        cyc = {w: None for w in W}
        val = {w: [0.0, 0.0] for w in W}
        scoped = [0.0, 0.0]
        for t, usd, fam, noise in zip(g["t"].to_list(), g["cost_usd"].to_list(), g["model_family"].to_list(),
                                      g["meter_noise"].to_list()):
            plan = plan_at(acc, t)
            for w in W:
                if cyc[w] is None or t >= cyc[w][1]:
                    start = t - t % floor[w]
                    cyc[w] = (start, start + W[w])
                    val[w] = [0.0, 0.0]
                    if w == "seven_day":
                        scoped = [0.0, 0.0]
                pts = usd * 100 / plans[plan][f"usd_full_{w}"] * (mult[w] if t >= pol_at else 1.0) * fw[fam]
                val[w][0] += pts
                val[w][1] += pts * noise
                rows.append((acc, w, t, cyc[w][1], val[w][0], val[w][1]))
            if fam == "fable":
                pts = usd * 100 / plans[plan]["usd_full_scoped"] * (mult["weekly_scoped"] if t >= pol_at else 1.0)
                scoped[0] += pts
                scoped[1] += pts * noise
                rows.append((acc, "weekly_scoped", t, cyc["seven_day"][1], scoped[0], scoped[1]))
    df = pl.DataFrame(rows, schema=["account", "window_kind", "t", "reset_ms", "clean", "actual"], orient="row")
    # Requests at the same millisecond: only the value after the last one is
    # defined (their order within the millisecond is arbitrary).
    return df.group_by(["account", "window_kind", "reset_ms", "t"]).agg(pl.col("clean").max(),
                                                                         pl.col("actual").max())


def test_reference_meter_reproduces_the_true_path(snap, params):
    ref = _reference_meter(snap, params).sort(["account", "window_kind", "reset_ms", "t"])
    mt = pl.read_parquet(snap / "truth" / "meter_true.parquet").with_columns(
        pl.col("t").dt.epoch("ms"), pl.col("reset_at").dt.epoch("ms").alias("reset_ms"))
    mt = mt.group_by(["account", "window_kind", "reset_ms", "t"]).agg(
        pl.col("util_clean").max(), pl.col("util_actual").max()).sort(["account", "window_kind", "reset_ms", "t"])
    assert ref.height == mt.height
    assert (ref["t"] == mt["t"]).all() and (ref["reset_ms"] == mt["reset_ms"]).all()
    assert np.allclose(ref["clean"], mt["util_clean"], rtol=1e-9, atol=1e-9)
    assert np.allclose(ref["actual"], mt["util_actual"], rtol=1e-9, atol=1e-9)


def test_readings_follow_the_reference_meter(snap, params):
    """From the snapshot's readings alone: each active reading equals the
    reference actual value at t - server_lag, floored, capped at 100."""
    lag = int(params["config"]["meter"]["server_lag_s"] * 1000)
    ref = _reference_meter(snap, params).sort("t")
    rd = read_table(snap, "meter_readings").filter(
        (pl.col("state") == "active") & (pl.col("backwards_pp") == 0)
        & pl.col("window_kind").is_in(["five_hour", "seven_day", "weekly_scoped"])
    ).with_columns((pl.col("t_event").dt.epoch("ms") - lag).alias("q"),
                   pl.col("resets_at").dt.epoch("ms").alias("rs")).sort("q")
    j = rd.join_asof(ref.rename({"t": "q"}), on="q", by=["account", "window_kind"], strategy="backward",
                     check_sortedness=False)
    same_cycle = (j["reset_ms"] - j["rs"]).abs() <= 5_000
    actual = np.where(same_cycle.fill_null(False).to_numpy(), j["actual"].fill_null(0.0).to_numpy(), 0.0)
    exp = np.minimum(100.0, np.floor(actual + 1e-9))
    match = (j["util_pct"].to_numpy() == exp)
    assert match.mean() == 1.0, j.filter(~pl.Series(match)).head()


def test_unobserved_usage_is_invisible_in_turns(snap, params):
    uo = pl.read_parquet(snap / "truth" / "unobserved.parquet")
    assert uo.height > 0
    users = {a["account"]: a["user"] for a in params["resolved"]["accounts"]}
    heavy = [u["name"] for u in params["resolved"]["users"]
             if any(p["unobserved_usd_per_day"] > 0 for p in params["config"]["personas"] if p["name"] == u["name"])]
    assert {users[a] for a in uo["account"].unique()} <= set(heavy)
