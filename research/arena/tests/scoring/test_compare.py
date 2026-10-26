import datetime as dt

import duckdb
import numpy as np
import pandas as pd
import polars as pl
import pytest

from arena.scoring import (aggregate, diebold_mariano, load_scores, model_confidence_set,
                           paired_differences, skill, week_block_bootstrap_ci)
from arena.scoring.compare import mcs_for_target

SCHEMA = open(__file__.replace("tests/scoring/test_compare.py", "arena/results_schema.sql")).read()


def make_db(models: dict[str, float], n_ep=60, seed=0):
    """Each model's CRPS = its base level + shared episode noise + small own noise."""
    rng = np.random.default_rng(seed)
    con = duckdb.connect()
    con.execute(SCHEMA)
    con.execute("INSERT INTO runs VALUES ('r1','test','synthetic','s',0,'v','current_code',NULL,now(),NULL)")
    t0 = dt.datetime(2026, 1, 5, tzinfo=dt.timezone.utc)
    for i, (name, base) in enumerate(models.items()):
        con.execute("INSERT INTO models VALUES (?,?,'p',NULL,NULL,NULL,'port',NULL,NULL,NULL,NULL,now())",
                    [f"h{i}", name])
    shared = np.random.default_rng(1).normal(0, 1, n_ep)
    rows = []
    for e in range(n_ep):
        t = t0 + dt.timedelta(days=e)
        for i, (name, base) in enumerate(models.items()):
            v = base + shared[e] + rng.normal(0, 0.05)
            rows.append(("r1", e, f"h{i}", t, "meter.five_hour:A1", "meter.five_hour", "crps", None, float(v)))
    con.executemany("INSERT INTO scores VALUES (?,?,?,?,?,?,?,?,?)", rows)
    return con


def test_aggregate_and_skill():
    con = make_db({"naive": 10.0, "good": 5.0})
    agg = aggregate(con)
    assert set(agg["model"]) == {"naive", "good"}
    assert (agg["n"] == 60).all()
    sk = skill(load_scores(con), "naive")
    good = sk.filter(pl.col("model") == "good")["skill"][0]
    naive = sk.filter(pl.col("model") == "naive")["skill"][0]
    assert good == pytest.approx(0.5, abs=0.02)
    assert naive == pytest.approx(0.0)


def test_paired_differences_and_bootstrap():
    con = make_db({"naive": 10.0, "good": 5.0})
    d = paired_differences(load_scores(con), "good", "naive")
    assert len(d) == 60
    assert d["diff"].mean() == pytest.approx(-5.0, abs=0.05)   # A - B: negative = A better
    ci = week_block_bootstrap_ci(d, reps=500)
    assert ci["lo"] < ci["mean"] < ci["hi"] < 0
    assert ci["n_weeks"] >= 8


def test_diebold_mariano_sign():
    rng = np.random.default_rng(0)
    better = rng.normal(-1.0, 1.0, 200)        # A - B < 0: A better
    r = diebold_mariano(better)
    assert r["stat"] < -5 and r["p"] < 1e-6
    assert diebold_mariano(-better)["stat"] > 5
    assert diebold_mariano(rng.normal(0, 1, 200))["p"] > 0.01


def test_dm_hac_inflates_variance_under_autocorrelation():
    rng = np.random.default_rng(3)
    e = rng.normal(size=500)
    x = np.zeros(500)
    for i in range(1, 500):
        x[i] = 0.8 * x[i - 1] + e[i]
    x += 0.2
    assert abs(diebold_mariano(x, lag=10)["stat"]) < abs(diebold_mariano(x, lag=0)["stat"])


def test_mcs_keeps_only_the_clear_winner():
    con = make_db({"a": 5.0, "b": 8.0, "c": 9.0})
    assert mcs_for_target(load_scores(con), "meter.five_hour", reps=300) == ["a"]


def test_mcs_keeps_ties():
    rng = np.random.default_rng(0)
    base = rng.normal(0, 1, 150)
    df = pd.DataFrame({"x": base + rng.normal(0, 1, 150), "y": base + rng.normal(0, 1, 150),
                       "z": base + 3 + rng.normal(0, 1, 150)})
    df["y"] += df["x"].mean() - df["y"].mean()      # equal means: a genuine tie
    assert set(model_confidence_set(df, reps=300)) == {"x", "y"}


def test_mcs_with_identical_models_finishes():
    """Two models with identical losses (zero-variance difference) used to hang
    arch's MCS; both now share one verdict."""
    import numpy as np
    import pandas as pd
    from arena.scoring.compare import model_confidence_set
    rng = np.random.default_rng(1)
    base = rng.uniform(0, 1, 60)
    df = pd.DataFrame({"flat": base, "live": base.copy(), "bad": base + 5})
    tied = model_confidence_set(df, reps=200)
    assert set(tied) == {"flat", "live"}
