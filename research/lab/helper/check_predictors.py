"""Run the helper's predictors on the lab's cases through the helper's own
Store/History, and compare with the lab's predictions and the truth.

  cd research/lab && uv run helper/check_predictors.py [--n 400]
"""
from __future__ import annotations

import argparse
import importlib.util
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
import lab  # noqa: E402
from lab_history import History  # noqa: E402
from lab_store import Store  # noqa: E402

PAIRS = {"lab-cost-decay-30m": "tokc-decay-30m", "lab-cost-rate-30m": "tokc-rate-30m-cal",
         "lab-cost-rate-1d": "tokc-rate-1d-cal",
         "lab-timestral-5m": "fm-timestral-5m-6h_3d", "lab-timestral-28m": "fm-timestral-28m-6h_3d",
         "lab-timestral-123m": "fm-timestral-123m-6h_3d", "lab-timestral-209m": "fm-timestral-209m-1d_1w",
         "lab-ensemble-7d": "l3-median12-7d"}


def load(name):
    path = HERE / "predictors" / f"{name}.py"
    if not path.exists():
        path = HERE / "staging" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=400)
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    store = Store()
    c = lab.cases()
    mods = {pid: load(pid.replace("-", "_")) for pid in PAIRS if a.only in pid}
    for pid, m in mods.items():
        window = m.WINDOWS[0]
        g = c[c["window"] == window].sort_values("t_cut")
        g = g.iloc[np.linspace(0, len(g) - 1, min(a.n, len(g))).astype(int)]
        dur = lab.WINDOWS[window]
        rows, t0 = [], time.time()
        for r in g.itertuples(index=False):
            s = store.series(window, r.account)
            h = History(window=window, account=r.account, t_cut=r.t_cut, cycle_start=r.cycle_start,
                        resets_at=r.resets_at, duration=dur, readings=s.until(r.t_cut))
            out = m.predict(window, r.account, r.t_cut, r.cycle_start, r.resets_at, h)
            rows.append((r.case_id, out[0] if out else np.nan))
        took = time.time() - t0
        df = pd.DataFrame(rows, columns=["case_id", "pred"]).merge(
            lab.read_preds(PAIRS[pid])[["case_id", "pred"]].rename(columns={"pred": "labpred"}), on="case_id", how="left")
        df = df.merge(g[["case_id", "used_now", "truth"]], on="case_id")
        sh = lab.shown(df["pred"].to_numpy(), df["used_now"].to_numpy())
        lp = lab.shown(df["labpred"].to_numpy(), df["used_now"].to_numpy())
        ok = ~np.isnan(sh) & ~np.isnan(lp)
        err_h = np.abs(sh[ok] - df["truth"].to_numpy()[ok])
        err_l = np.abs(lp[ok] - df["truth"].to_numpy()[ok])
        print(f"{pid:20s} {window:9s} n={ok.sum()}/{len(df)}  {took / len(df) * 1000:6.1f} ms/case  "
              f"|helper−lab| median {np.median(np.abs(sh[ok] - lp[ok])):.2f} p90 {np.quantile(np.abs(sh[ok] - lp[ok]), .9):.2f}  "
              f"error helper {lab.headline(err_h, window):.2f} vs lab {lab.headline(err_l, window):.2f}")


if __name__ == "__main__":
    main()
