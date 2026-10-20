"""Week by week, how many meter points one API-equivalent dollar bought, and
which model did most of the spending that week — to tell a per-model effect
from a change of limits over time. One account, both windows.

  uv run tokens/factor_over_time.py [account-suffix]
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lab  # noqa: E402
from meter_from_tokens import intervals  # noqa: E402
from pricing_vs_meter import turn_costs  # noqa: E402


def main() -> None:
    suffix = sys.argv[1] if len(sys.argv) > 1 else "8c95"
    tok = pd.read_parquet(lab.DATA / "tokens.parquet").reset_index(drop=True)
    tok["cost"] = turn_costs(tok)
    acct = next(a for a in tok["account"].unique() if a.endswith(suffix))
    tk = tok[tok["account"] == acct].sort_values("t")
    tt, cc = tk["t"].to_numpy(), np.concatenate([[0], np.cumsum(tk["cost"].to_numpy())])
    tk["week"] = pd.to_datetime(tk["t"], unit="s").dt.to_period("W").astype(str)
    lead = tk.groupby("week").apply(lambda g: g.groupby("model")["cost"].sum().idxmax())
    share = tk.groupby("week").apply(lambda g: g.groupby("model")["cost"].sum().max() / g["cost"].sum())
    rows = {}
    for window in lab.WINDOWS:
        iv = intervals(window)
        iv = iv[iv["account"] == acct]
        spent = cc[np.searchsorted(tt, iv["t1"].to_numpy(), "right")] - cc[np.searchsorted(tt, iv["t0"].to_numpy(), "right")]
        wk = pd.to_datetime(iv["t1"], unit="s").dt.to_period("W").astype(str).to_numpy()
        df = pd.DataFrame({"week": wk, "rise": iv["rise"].to_numpy(), "spent": spent})
        agg = df.groupby("week").sum()
        rows[window] = (agg["rise"] / agg["spent"]).where(agg["spent"] > 20)
    out = pd.DataFrame({"pp per $ (5h)": rows["five_hour"], "pp per $ (7d)": rows["seven_day"],
                        "lead model": lead, "lead share": share}).dropna(subset=["lead model"])
    print(out.round(3).to_string())


if __name__ == "__main__":
    main()
