"""Does token spend explain the meter? For consecutive readings of one cycle,
regress the meter's rise on the tokens spent in between, per model family and
token kind, with non-negative weights. Fit on the first 70% of time, test on
the rest. If it holds, tokens are a leading indicator: Pacer sees every turn
as it happens, the meter only at its next poll.

  uv run tokens/meter_from_tokens.py [--window five_hour]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.optimize import nnls

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lab  # noqa: E402

KINDS = ["input", "output", "cache_read", "cache_create_5m", "cache_create_1h"]


def family(model: str) -> str:
    for f in ("fable", "opus", "sonnet", "haiku"):
        if f in model:
            return f
    return "other"


def intervals(window: str) -> pd.DataFrame:
    """One row per pair of consecutive readings inside one cycle: account, t0, t1, rise."""
    s = lab.samples()
    s = s[s["window"] == window].sort_values(["account", "t"])
    rows = []
    for acct, g in s.groupby("account"):
        t, p, r = g["t"].to_numpy(), g["pct"].to_numpy(), g["resets_at"].to_numpy()
        same = np.abs(np.diff(r)) < lab.WINDOWS[window] / 2
        rise = np.diff(p)
        ok = same & (rise >= 0) & (np.diff(t) > 0) & (np.diff(t) < 3600)
        rows.append(pd.DataFrame({"account": acct, "t0": t[:-1][ok], "t1": t[1:][ok], "rise": rise[ok]}))
    return pd.concat(rows, ignore_index=True)


def token_features(iv: pd.DataFrame) -> tuple[np.ndarray, list[str]]:
    tok = pd.read_parquet(lab.DATA / "tokens.parquet")
    tok["family"] = tok["model"].map(family)
    cols = [f"{f}:{k}" for f in ("fable", "opus", "sonnet", "haiku", "other") for k in KINDS]
    X = np.zeros((len(iv), len(cols)))
    for acct, g in iv.groupby("account"):
        tk = tok[tok["account"] == acct]
        if tk.empty:
            continue
        tt = tk["t"].to_numpy()
        cum = {}
        for f in ("fable", "opus", "sonnet", "haiku", "other"):
            mask = (tk["family"] == f).to_numpy()
            for k in KINDS:
                cum[f"{f}:{k}"] = np.concatenate([[0.0], np.cumsum(np.where(mask, tk[k].fillna(0).to_numpy(), 0.0))])
        lo = np.searchsorted(tt, g["t0"].to_numpy(), side="right")
        hi = np.searchsorted(tt, g["t1"].to_numpy(), side="right")
        for j, col in enumerate(cols):
            X[g.index, j] = (cum[col][hi] - cum[col][lo]) / 1e6      # millions of tokens
    return X, cols


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--window", default="five_hour")
    a = ap.parse_args()
    iv = intervals(a.window)
    X, cols = token_features(iv)
    y = iv["rise"].to_numpy()
    for scope, groups in (("pooled", [None]), ("per-account", sorted(iv["account"].unique()))):
        print(f"\n== {a.window} {scope}")
        for acct in groups:
            m = np.ones(len(iv), bool) if acct is None else (iv["account"] == acct).to_numpy()
            idx = np.where(m)[0]
            if len(idx) < 200:
                continue
            split = idx[int(len(idx) * 0.7)]
            tr, te = idx[idx < split], idx[idx >= split]
            w, _ = nnls(X[tr], y[tr])
            pred = X[te] @ w
            ss = np.sum((y[te] - y[te].mean()) ** 2)
            r2 = 1 - np.sum((y[te] - pred) ** 2) / ss if ss > 0 else float("nan")
            # Over longer spans the rounding of the meter matters less: sum per hour.
            hours = (iv["t1"].to_numpy()[te] // 3600)
            hy = pd.Series(y[te]).groupby(hours).sum()
            hp = pd.Series(pred).groupby(hours).sum()
            r2h = 1 - np.sum((hy - hp) ** 2) / np.sum((hy - hy.mean()) ** 2)
            top = sorted(((w[j], cols[j]) for j in range(len(cols)) if w[j] > 0), reverse=True)[:6]
            name = "all" if acct is None else acct[-4:]
            print(f"  {name}: intervals {len(tr)}/{len(te)}  R² per interval {r2:.3f}  per hour {r2h:.3f}  "
                  f"rise share explained {np.sum(pred) / max(np.sum(y[te]), 1e-9):.2f}")
            print("     weights (pp per M tokens): " + ", ".join(f"{c} {v:.3g}" for v, c in top))


if __name__ == "__main__":
    main()
