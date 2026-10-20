"""The prediction lab's shared contract: one frozen snapshot, one case table,
one prediction format, one scorer. Every candidate (engine models, foundation
time-series models, ML, combinations, routers) is judged on exactly the same
cases, the way the app's record judges them.

A CASE is one completed rate-limit cycle seen at one cut (20%, 30% … 90% of
the way through it), exactly the harness's grid (`pacer_replay`):
  case_id      "<window>|<account>|<resets_at int>|<cut>"
  window       five_hour | seven_day
  account      account id ("" for unattributed rows)
  cycle_start, resets_at, t_cut   unix seconds
  cut          0.2 … 0.9
  used_now     the meter at the cut (last reading at or before t_cut)
  truth        the cycle's final (max) reading — what the forecast is for
  fold         0–3: contiguous quarters of all cases by cycle_start
A case exists when the cycle's truth > 0 and it has ≥ 3 readings by the cut
(the harness's rule).

A PREDICTION FILE is preds/<name>.parquet with columns
  case_id, pred            (the final usage the candidate forecasts, any value)
  q10, q90                 optional: an 80% band
The scorer clamps pred (and the band) to [used_now, 100]: the value shown.

NO PEEKING. A candidate predicting a case may use only readings with
timestamp ≤ t_cut — its own account's, or (pooled models) any account's —
and only cycles that had RESET by t_cut as training targets. `history()`
below enforces it for the common case.

Run `uv run build_cases.py` once to freeze data/ from the live store (read
only, through an APFS clone), then candidates write preds/, then
`uv run score.py`.
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
DATA = HERE / "data"
PREDS = HERE / "preds"
HARNESS = HERE.parent / "harness"
sys.path.insert(0, str(HARNESS))

WINDOWS = {"five_hour": 5 * 3600.0, "seven_day": 7 * 86400.0}
CUTS = [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]


def weekly(window: str) -> bool:
    return WINDOWS[window] >= 86400


def headline(errors: np.ndarray, window: str) -> float:
    """The app's typical error: the median on session windows, the mean on
    weekly ones (whose median is ~0 for every model: most end at the cap)."""
    if len(errors) == 0:
        return math.nan
    return float(np.mean(errors) if weekly(window) else np.median(errors))


# ---------------------------------------------------------------------------
# Snapshot
# ---------------------------------------------------------------------------

def samples() -> pd.DataFrame:
    """Every rate-limit reading, live cache and archive: window, account, t, pct, resets_at."""
    return pd.read_parquet(DATA / "samples.parquet")


def cases() -> pd.DataFrame:
    return pd.read_parquet(DATA / "cases.parquet")


def grids() -> dict[str, list[list[float]]]:
    """Each account's 7×24 activity prior (and "" for the all-accounts one)."""
    return json.loads((DATA / "grids.json").read_text())


class History:
    """Leak-proof access to readings: everything at or before a cut."""

    def __init__(self, s: pd.DataFrame | None = None):
        s = samples() if s is None else s
        self._by = {k: g.sort_values("t").reset_index(drop=True) for k, g in s.groupby(["window", "account"])}

    def series(self, window: str, account: str, until: float, since: float = -math.inf) -> pd.DataFrame:
        g = self._by.get((window, account))
        if g is None:
            return pd.DataFrame(columns=["t", "pct", "resets_at"])
        lo = np.searchsorted(g["t"].to_numpy(), since, side="left")
        hi = np.searchsorted(g["t"].to_numpy(), until, side="right")
        return g.iloc[lo:hi][["t", "pct", "resets_at"]]

    def accounts(self, window: str) -> list[str]:
        return sorted(a for (w, a) in self._by if w == window)


def cycle_partial(h: History, case: pd.Series) -> pd.DataFrame:
    """The case's own cycle up to the cut (readings of this cycle only)."""
    s = h.series(case["window"], case["account"], until=case["t_cut"], since=case["cycle_start"])
    return s[(s["resets_at"] - case["resets_at"]).abs() < WINDOWS[case["window"]] / 2]


# ---------------------------------------------------------------------------
# Predictions + scoring
# ---------------------------------------------------------------------------

def write_preds(name: str, df: pd.DataFrame) -> Path:
    PREDS.mkdir(exist_ok=True)
    cols = [c for c in ("case_id", "pred", "q10", "q90") if c in df.columns]
    out = PREDS / f"{name}.parquet"
    df[cols].to_parquet(out, index=False)
    return out


def read_preds(name: str) -> pd.DataFrame:
    return pd.read_parquet(PREDS / f"{name}.parquet")


def shown(pred: np.ndarray, used_now: np.ndarray) -> np.ndarray:
    return np.clip(pred, used_now, 100.0)


def score(name: str, c: pd.DataFrame | None = None, preds: pd.DataFrame | None = None) -> dict:
    """Per window: headline error, coverage (with a band), per-fold headline,
    per-account headline, case count, and the share of cases predicted."""
    c = cases() if c is None else c
    p = read_preds(name) if preds is None else preds
    m = c.merge(p, on="case_id", how="left")
    out = {}
    for window, g in m.groupby("window"):
        have = g["pred"].notna()
        gg = g[have]
        if gg.empty:
            continue
        err = np.abs(shown(gg["pred"].to_numpy(), gg["used_now"].to_numpy()) - gg["truth"].to_numpy())
        row = {"cases": int(len(gg)), "share": float(have.mean()), "headline": headline(err, window),
               "mean": float(np.mean(err)), "median": float(np.median(err))}
        if "q10" in gg and gg["q10"].notna().any():
            b = gg[gg["q10"].notna()]
            lo = np.clip(b["q10"].to_numpy(), b["used_now"].to_numpy(), 100)
            hi = np.maximum(lo, np.clip(b["q90"].to_numpy(), b["used_now"].to_numpy(), 100))
            row["coverage80"] = float(np.mean((b["truth"].to_numpy() >= lo) & (b["truth"].to_numpy() <= hi)))
            row["band_share"] = float(len(b) / len(gg))
        row["folds"] = [headline(np.abs(shown(f["pred"].to_numpy(), f["used_now"].to_numpy()) - f["truth"].to_numpy()), window)
                        for _, f in gg.groupby("fold")]
        row["by_account"] = {a[-4:] or "none": headline(np.abs(shown(f["pred"].to_numpy(), f["used_now"].to_numpy()) - f["truth"].to_numpy()), window)
                             for a, f in gg.groupby("account")}
        out[window] = row
    return out
