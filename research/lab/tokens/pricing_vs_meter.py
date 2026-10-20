"""What moves the meter: raw tokens, or API-equivalent cost? And does the same
dollar move it differently by model, by time of day, or on weekends?

For consecutive readings of one cycle, the meter's rise is regressed (non-
negative least squares) on what was spent in between. Fit on the first 70% of
time, scored on the rest, summed per hour (the meter's 1% rounding makes single
intervals noisy). Variants:
  tokens        25 weights: model family × token kind (meter_from_tokens.py)
  cost          one cost→% factor (API-equivalent $, Pacer's live price list)
  cost×model    one factor per model id (does a model drain faster than its price?)
  cost×hour     one factor per 3-hour block of local time (peak vs off-peak?)
  cost×weekend  weekday vs weekend factor
  cost×model×hour  both
The fitted factors are printed relative to their (spend-weighted) mean, so 1.20
means that model or hour moves the meter 20% more per dollar than average.

  uv run tokens/pricing_vs_meter.py [--window five_hour]
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.optimize import nnls

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lab  # noqa: E402
from meter_from_tokens import KINDS, family, intervals  # noqa: E402

PRICE_FILE = Path.home() / "Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer/litellm-pricing.cache.json"
PRICE_KEYS = {"input": "input_cost_per_token", "output": "output_cost_per_token",
              "cache_read": "cache_read_input_token_cost", "cache_create_5m": "cache_creation_input_token_cost",
              "cache_create_1h": "cache_creation_input_token_cost_above_1hr"}


def prices() -> dict[str, dict[str, float]]:
    d = json.loads(PRICE_FILE.read_text())
    d = d.get("entries", d)
    out = {}
    for m, e in d.items():
        if isinstance(e, dict) and m.startswith("claude-") and e.get("input_cost_per_token"):
            out[m] = {k: float(e.get(v) or 0.0) for k, v in PRICE_KEYS.items()}
    return out


def turn_costs(tok: pd.DataFrame) -> np.ndarray:
    pr = prices()
    cost = np.zeros(len(tok))
    missing = set()
    for m, g in tok.groupby("model"):
        p = pr.get(m) or next((pr[k] for k in sorted(pr, key=len, reverse=True) if k in m), None)
        if p is None:
            missing.add(m)
            continue
        cost[g.index] = sum(g[k].fillna(0).to_numpy() * p[k] for k in KINDS)
    if missing:
        print("  no price for:", ", ".join(sorted(missing)))
    return cost


def design(iv: pd.DataFrame, tok: pd.DataFrame, cost: np.ndarray, cols_fn, ncols: int) -> np.ndarray:
    """X[i, j] = Σ cost of turns in interval i whose column is j."""
    X = np.zeros((len(iv), ncols))
    col = cols_fn(tok)
    for acct, g in iv.groupby("account"):
        sel = (tok["account"] == acct).to_numpy()
        tt = tok["t"].to_numpy()[sel]
        cc, jj = cost[sel], col[sel]
        cum = np.zeros((len(tt) + 1, ncols))
        np.add.at(cum[1:], (np.arange(len(tt)), jj), cc)
        cum = np.cumsum(cum, axis=0)
        lo = np.searchsorted(tt, g["t0"].to_numpy(), "right")
        hi = np.searchsorted(tt, g["t1"].to_numpy(), "right")
        X[g.index] = cum[hi] - cum[lo]
    return X


def evaluate(X, y, iv, label, names=None, weights_of=None) -> None:
    t = iv["t1"].to_numpy()
    split = np.quantile(t, 0.7)
    tr, te = t < split, t >= split
    w, _ = nnls(X[tr], y[tr])
    pred = X[te] @ w
    hours = t[te] // 3600
    hy = pd.Series(y[te]).groupby(hours).sum()
    hp = pd.Series(pred).groupby(hours).sum()
    r2 = 1 - np.sum((hy - hp) ** 2) / np.sum((hy - hy.mean()) ** 2)
    mae = float(np.mean(np.abs(hy - hp)))
    print(f"  {label:18s} hourly R² {r2:.3f}  hourly MAE {mae:.2f} pp  ({X.shape[1]} factors)")
    if names is not None:
        spend = X[tr].sum(axis=0)
        mean = np.sum(w * spend) / max(spend.sum(), 1e-12)
        rel = [(names[j], w[j] / mean, spend[j]) for j in range(len(names)) if spend[j] > 0]
        print("     per $ vs average: " + ", ".join(f"{n} {r:.2f}" for n, r, s in sorted(rel, key=lambda x: -x[2])[:12]))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--window", default="five_hour")
    a = ap.parse_args()
    tok = pd.read_parquet(lab.DATA / "tokens.parquet").reset_index(drop=True)
    cost = turn_costs(tok)
    local = pd.to_datetime(tok["t"], unit="s", utc=True).dt.tz_convert(datetime.now().astimezone().tzinfo)
    hour_block = (local.dt.hour // 3).to_numpy()
    weekend = (local.dt.weekday >= 5).to_numpy().astype(int)
    models = sorted(tok["model"].unique())
    mid = tok["model"].map({m: i for i, m in enumerate(models)}).to_numpy()
    fam_kind = [f"{f}:{k}" for f in ("fable", "opus", "sonnet", "haiku", "other") for k in KINDS]

    iv_all = intervals(a.window)
    for scope in ["pooled"] + sorted(iv_all["account"].unique()):
        iv = iv_all if scope == "pooled" else iv_all[iv_all["account"] == scope].reset_index(drop=True)
        if len(iv) < 500:
            continue
        y = iv["rise"].to_numpy()
        print(f"\n== {a.window} · {'all accounts' if scope == 'pooled' else scope[-4:]} · {len(iv):,} reading intervals")
        # Raw tokens: one column per family × kind, the "cost" being the token count.
        fam = tok["model"].map(family).to_numpy()
        tok_cols = np.zeros(len(tok), int)
        Xt = np.zeros((len(iv), len(fam_kind)))
        for j, fk in enumerate(fam_kind):
            f, k = fk.split(":")
            amount = np.where(fam == f, tok[k].fillna(0).to_numpy(), 0.0) / 1e6
            Xt[:, j] = design(iv, tok, amount, lambda _: tok_cols, 1)[:, 0]
        evaluate(Xt, y, iv, "tokens")
        evaluate(design(iv, tok, cost, lambda _: np.zeros(len(tok), int), 1), y, iv, "cost")
        evaluate(design(iv, tok, cost, lambda _: mid, len(models)), y, iv, "cost×model", names=models)
        evaluate(design(iv, tok, cost, lambda _: hour_block, 8), y, iv, "cost×hour",
                 names=[f"{3 * b:02d}-{3 * b + 3:02d}h" for b in range(8)])
        evaluate(design(iv, tok, cost, lambda _: weekend, 2), y, iv, "cost×weekend", names=["weekday", "weekend"])
        evaluate(design(iv, tok, cost, lambda _: mid * 8 + hour_block, len(models) * 8), y, iv, "cost×model×hour")


if __name__ == "__main__":
    main()
