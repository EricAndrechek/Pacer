"""Post-processing, still walk-forward.

-cal : conformalised bands (CQR). For each case, the calibration set is the
       model's own EARLIER predictions on cycles that RESET <= t_cut (their
       truth is known); the band is widened by the 80% quantile of
       max(q10-y, y-q90). Needs >= 30 such cases, else the band is left raw.
ens-*: simple averages of existing ml- prediction files (point = mean,
       band = mean of bands). Membership is chosen by name pattern, NOT by
       peeking at the score table (see README).

  uv run python ml/post.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import lab  # noqa: E402


def calibrate(name: str, c: pd.DataFrame) -> None:
    o = pd.read_parquet(HERE / "out" / f"{name}.parquet").drop(columns=["window", "fallback"])
    m = c.merge(o, on="case_id").sort_values("t_cut").reset_index(drop=True)
    u = m["used_now"].to_numpy()
    lo = np.clip(m["q10"].to_numpy(), u, 100)
    hi = np.maximum(lo, np.clip(m["q90"].to_numpy(), u, 100))
    y = m["truth"].to_numpy()
    sc = np.maximum(lo - y, y - hi)
    ok = ~np.isnan(sc)
    qa = np.full(len(m), np.nan)
    for w in lab.WINDOWS:
        idx = np.where((m["window"] == w).to_numpy())[0]
        res_at = m["resets_at"].to_numpy()[idx]
        tcut = m["t_cut"].to_numpy()[idx]
        for i, j in enumerate(idx):
            if not ok[j]:
                continue
            sel = idx[(res_at <= tcut[i]) & ok[idx]]
            n = len(sel)
            if n >= 30:
                qa[j] = np.quantile(sc[sel], min(1.0, np.ceil((n + 1) * 0.8) / n))
    out = m[["case_id", "pred"]].copy()
    out["q10"] = np.where(np.isnan(qa), m["q10"], m["q10"] - qa)
    out["q90"] = np.where(np.isnan(qa), m["q90"], m["q90"] + qa)
    rule = lab.read_preds("rule-current").set_index("case_id")["pred"]
    out["pred"] = out["pred"].fillna(out["case_id"].map(rule))
    lab.write_preds(name + "-cal", out)


def ensemble(name: str, members: list[str]) -> None:
    ds = []
    for n in members:
        p = lab.read_preds(n).set_index("case_id")
        ds.append(p)
    pred = pd.concat([d["pred"] for d in ds], axis=1).mean(axis=1)
    out = pd.DataFrame({"pred": pred})
    if all("q10" in d for d in ds):
        out["q10"] = pd.concat([d["q10"] for d in ds], axis=1).mean(axis=1)
        out["q90"] = pd.concat([d["q90"] for d in ds], axis=1).mean(axis=1)
    lab.write_preds(name, out.reset_index())


def main() -> None:
    c = lab.cases()
    names = sorted(p.stem for p in (HERE / "out").glob("ml-*.parquet"))
    for n in names:
        calibrate(n, c)
    have = lambda pat: [n for n in names if pat(n)]
    for tok in (False, True):
        t = "-tok" if tok else ""
        sel = have(lambda n: n.startswith("ml-lgbm-") and "-stacked" not in n and n.endswith("-pooled-acct" + t)
                   and ("mono" not in n))
        if len(sel) > 1:
            ensemble(f"ml-ens-lgbm-targets{t}", sel)
        sel = have(lambda n: n.startswith("ml-lgbm-") and "-stacked" in n and n.endswith("-pooled-acct-stacked" + t))
        if len(sel) > 1:
            ensemble(f"ml-ens-lgbm-stacked-targets{t}", sel)
        sel = have(lambda n: n.startswith(("ml-lgbm-delta", "ml-lgbm-frac", "ml-knn-frac", "ml-linqr-delta"))
                   and n.endswith("-pooled-acct-stacked" + t) or (n.startswith("ml-knn-") and n.endswith("-pooled-acct" + t)))
        if len(sel) > 2:
            ensemble(f"ml-ens-mixed{t}", sel)
    print("done", len(names))


if __name__ == "__main__":
    main()
