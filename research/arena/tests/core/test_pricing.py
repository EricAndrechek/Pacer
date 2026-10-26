"""Pricing: rates as known at T vs final, tiers, multipliers, null never 0."""
import numpy as np
import polars as pl

import fixtures as fx
from arena.pricing import canonical_model, price_turns


def _turn(model, t, **kw):
    base = dict(t_event=t, model=model, input=1_000_000, output=0, cache_read=0, cache_write_5m=0,
                cache_write_1h=0, inference_geo="global", speed="standard", output_reliable=True,
                output_imputed=None)
    base.update(kw)
    return base


def _frame(rows):
    return pl.DataFrame(rows).with_columns(pl.col("t_event").cast(pl.Datetime("ms", "UTC")),
                                           pl.col("output_imputed").cast(pl.Float64))


def test_as_of_vs_final(lockbox):
    prices = lockbox.tables["prices"]
    t = fx.OPUS_CHANGE + fx.HOUR          # after the change took effect, before it was known
    turns = _frame([_turn("claude-opus-4-5", t)])
    as_known = price_turns(turns, prices, as_of=fx.OPUS_CHANGE + 2 * fx.HOUR)["cost_usd"][0]
    final = price_turns(turns, prices)["cost_usd"][0]
    assert as_known == 5.0 and final == 4.0     # 1M input tokens at $5 then, $4 in hindsight
    later = price_turns(turns, prices, as_of=fx.OPUS_CHANGE_KNOWN)["cost_usd"][0]
    assert later == 4.0


def test_unknown_rate_is_null_never_zero(lockbox):
    prices = lockbox.tables["prices"]
    turns = _frame([_turn("claude-haiku-4-5", fx.T0 + fx.HOUR), _turn("claude-mystery-1", fx.T0 + fx.HOUR),
                    _turn("<synthetic>", fx.T0 + fx.HOUR)])
    early = price_turns(turns, prices, as_of=fx.T0 + fx.HOUR)
    assert early["cost_usd"].null_count() == 3
    assert set(early["price_flag"].to_list()) == {"unpriced"}
    final = price_turns(turns, prices)
    assert final["cost_usd"][0] == 1.0 and final["cost_usd"][1] is None and final["cost_usd"][2] is None


def test_long_context_tier_prices_whole_request(lockbox):
    prices = lockbox.tables["prices"]
    small = _turn("claude-sonnet-4-5", fx.T0, input=100_000, cache_read=50_000)
    big = _turn("claude-sonnet-4-5", fx.T0, input=100_000, cache_read=150_000)
    c = price_turns(_frame([small, big]), prices)["cost_usd"].to_list()
    assert np.isclose(c[0], (100_000 * 3.0 + 50_000 * 0.3) / 1e6)
    assert np.isclose(c[1], (100_000 * 6.0 + 150_000 * 0.6) / 1e6)   # whole request at the tier rate


def test_geo_and_speed_multipliers(lockbox):
    prices = lockbox.tables["prices"]
    t = fx.T0
    rows = [_turn("claude-opus-4-5", t), _turn("claude-opus-4-5", t, inference_geo="us"),
            _turn("claude-opus-4-5", t, speed="fast"), _turn("claude-sonnet-4-5", t, speed="fast"),
            _turn("claude-opus-4-5", t, inference_geo=None)]
    out = price_turns(_frame(rows), prices)
    c = out["cost_usd"].to_list()
    assert np.isclose(c[0], 5.0) and np.isclose(c[1], 5.5) and np.isclose(c[2], 30.0)
    assert c[3] is None and out["price_flag"][3] == "unpriced_fast"     # no fast rate: never guessed
    assert np.isclose(c[4], 5.0)                                         # unknown geo: no multiplier


def test_best_output_uses_imputation(lockbox):
    prices = lockbox.tables["prices"]
    rows = [_turn("claude-opus-4-5", fx.T0, input=0, output=1_000_000, output_reliable=False,
                  output_imputed=2_000_000.0)]
    assert price_turns(_frame(rows), prices, output="raw")["cost_usd"][0] == 25.0
    assert price_turns(_frame(rows), prices, output="best")["cost_usd"][0] == 50.0


def test_masked_output_prices_null(lockbox):
    prices = lockbox.tables["prices"]
    rows = [_turn("claude-opus-4-5", fx.T0, output=None)]
    df = _frame(rows).with_columns(pl.col("output").cast(pl.Int64))
    assert price_turns(df, prices)["cost_usd"][0] is None


def test_real_fixture_turns_all_priced_with_final_rates(lockbox):
    out = price_turns(lockbox.tables["turns"], lockbox.tables["prices"], output="best")
    unpriced = out.filter(pl.col("cost_usd").is_null())
    assert set(unpriced["model"].to_list()) == {"claude-mystery-1"}
    assert (out["cost_usd"].drop_nulls() > 0).all()
    assert out.height == lockbox.tables["turns"].height


def test_canonical_model():
    assert canonical_model("us.anthropic.claude-opus-4-5-20251101-v1:0") == "claude-opus-4-5"
    assert canonical_model("claude-sonnet-4-5@20250929") == "claude-sonnet-4-5"
    assert canonical_model("claude-opus-4-5[1m]") == "claude-opus-4-5"


def _prices(rows):
    base = dict(t_known_src="history", part="input", tier_threshold=None, geo_mult=None, speed_mult=None,
                source="litellm", commit_sha="x", t_effective_to=None, is_correction=False)
    df = pl.DataFrame([{**base, **r} for r in rows])
    ts = pl.Datetime("ms", "UTC")
    return df.with_columns(pl.col("t_effective_from").cast(ts), pl.col("t_known").cast(ts),
                           pl.col("t_effective_to").cast(ts), pl.col("t_event").cast(ts),
                           pl.col("tier_threshold").cast(pl.Int64), pl.col("geo_mult").cast(pl.Float64),
                           pl.col("speed_mult").cast(pl.Float64))


def test_latest_start_then_correction_then_later_known():
    m = "claude-x-1"
    p = _prices([
        dict(t_event=100, t_effective_from=100, t_known=100, model=m, rate_per_mtok=1.0),
        dict(t_event=100, t_effective_from=100, t_known=500, model=m, rate_per_mtok=2.0),                     # later known
        dict(t_event=100, t_effective_from=100, t_known=300, model=m, rate_per_mtok=3.0, is_correction=True),  # correction
        dict(t_event=1000, t_effective_from=1000, t_known=1000, model=m, rate_per_mtok=7.0),
    ])
    turns = _frame([_turn(m, 50), _turn(m, 200), _turn(m, 2000)])
    final = price_turns(turns, p)["cost_usd"].to_list()
    assert final[0] is None                          # before every start: no rate, never 0
    assert final[1] == 3.0 and final[2] == 7.0       # the correction beats the original and later rows
    assert price_turns(turns, p, as_of=250)["cost_usd"][1] == 1.0     # correction not yet known
    assert price_turns(turns, p, as_of=600)["cost_usd"][1] == 3.0
    assert price_turns(turns, p, as_of=600)["cost_usd"][2] == 3.0     # the change isn't known yet


def test_fast_turns_use_explicit_fast_rows(lockbox):
    """The exporter writes a source's explicit fast-mode rates as model
    `<model>:fast` (speed_mult 1). A fast request is priced there wherever such
    a row is in effect, else at the standard rate x speed_mult, else unpriced."""
    prices = lockbox.tables["prices"]
    t0 = fx.T0
    sonnet_fast = (prices.filter((pl.col("model") == "claude-sonnet-4-5") & pl.col("tier_threshold").is_null())
                   .with_columns(pl.lit("claude-sonnet-4-5-20250929:fast").alias("model"),
                                 pl.lit(1.0).alias("speed_mult"),
                                 (pl.col("rate_per_mtok") * 4).alias("rate_per_mtok"),
                                 pl.lit(t0 + 2 * fx.DAY).cast(pl.Datetime("ms", "UTC")).alias("t_effective_from")))
    opus_fast = (prices.filter((pl.col("model") == "claude-opus-4-5") & pl.col("tier_threshold").is_null())
                 .sort("t_effective_from").head(5)
                 .with_columns(pl.lit("claude-opus-4-5:fast").alias("model"), pl.lit(1.0).alias("speed_mult"),
                               (pl.col("rate_per_mtok") * 2).alias("rate_per_mtok"),
                               pl.lit(t0 + 2 * fx.DAY).cast(pl.Datetime("ms", "UTC")).alias("t_effective_from")))
    p = pl.concat([prices, sonnet_fast, opus_fast], how="vertical_relaxed")
    small = dict(input=100_000)                                         # under sonnet's long-context tier
    rows = [_turn("claude-sonnet-4-5", t0 + 3 * fx.DAY, speed="fast", **small),   # explicit fast row in effect
            _turn("claude-sonnet-4-5", t0 + fx.DAY, speed="fast", **small),       # before it: no multiplier either
            _turn("claude-sonnet-4-5", t0 + 3 * fx.DAY, **small),                 # standard request: standard rate
            _turn("claude-opus-4-5", t0 + fx.DAY, speed="fast"),           # before: standard x speed_mult
            _turn("claude-opus-4-5", t0 + 3 * fx.DAY, speed="fast", inference_geo="us")]
    out = price_turns(_frame(rows), p)
    c = out["cost_usd"].to_list()
    assert np.isclose(c[0], 1.2) and out["price_flag"][0] == "ok"
    assert c[1] is None and out["price_flag"][1] == "unpriced_fast"
    assert np.isclose(c[2], 0.3)
    assert np.isclose(c[3], 30.0)
    assert np.isclose(c[4], 10.0 * 1.1)          # the fast row's rate, its own geo multiplier, no speed mult
    assert canonical_model("us.anthropic.claude-opus-4-5-20251101:fast") == "claude-opus-4-5:fast"
