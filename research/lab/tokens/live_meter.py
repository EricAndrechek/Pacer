"""The live meter, replayed: between two meter readings, show
  last reading + floor(points-per-dollar × API $ spent since it)
and score it against the readings that follow. The evidence for the live
meter issue (epic #316); the factor is the lab's one-per-account version of
#317 (meter rise ÷ spend over the last 14 days of reading pairs, refit daily).

  1. Lag: does the server's number trail spend? (hourly fit vs spend shifted)
  2. Display rule on every reading: hold the last reading vs rounded, floored
     and exact fills, and how often each would step DOWN at the next reading.
  3. One login: Pacer reads each login at most every 5 minutes
     (OAuthPollScheduler.perTokenMinInterval). Thin the busiest account's
     readings to one per 5 minutes and score what would be on screen against
     the real, denser readings, by how fast the meter is moving.
  4. Off this Mac: meter rise in hours with no local spend.

  uv run tokens/live_meter.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import lab  # noqa: E402
from pricing_vs_meter import turn_costs  # noqa: E402

SINCE = pd.Timestamp("2026-09-01").timestamp()   # dense readings (many logins) from here on
THIN = 300.0


def ledger():
    tok = pd.read_parquet(lab.DATA / "tokens.parquet").sort_values("t")
    tok["cost"] = turn_costs(tok)
    out = {}
    for a, g in tok.groupby("account"):
        tt, cum = g["t"].to_numpy(), np.r_[0.0, np.cumsum(g["cost"].to_numpy())]
        out[a] = (lambda tt, cum: lambda t0, t1: cum[np.searchsorted(tt, t1, "right")] - cum[np.searchsorted(tt, t0, "right")])(tt, cum)
    return out, tok["t"].max()


def pairs(t, p, r, window):
    """Consecutive readings of one cycle with a non-negative rise, < 1 h apart."""
    d, rise = np.diff(t), np.diff(p)
    ok = (np.abs(np.diff(r)) < lab.WINDOWS[window] / 2) & (d > 0) & (d < 3600) & (rise >= 0)
    return t[:-1][ok], t[1:][ok], p[:-1][ok], rise[ok]


def daily_factor(t1, rise, spent):
    """Points per API $ for each pair: refit daily on the previous 14 days."""
    cy, cx = np.r_[0, np.cumsum(rise)], np.r_[0, np.cumsum(spent)]
    day = (t1 // 86400).astype(int)
    k = np.full(len(t1), np.nan)
    for dd in np.unique(day):
        lo, hi = np.searchsorted(t1, (dd - 14) * 86400.0), np.searchsorted(t1, dd * 86400.0)
        if cx[hi] - cx[lo] > 1:
            k[day == dd] = (cy[hi] - cy[lo]) / (cx[hi] - cx[lo])
    return k


def main() -> None:
    s = lab.samples()
    spend, t_end = ledger()
    for window in lab.WINDOWS:
        ss = s[(s["window"] == window) & (s["t"] <= t_end)].sort_values(["account", "t"])
        print(f"\n===== {window}")

        # 1. Lag
        if window == "five_hour":
            print("1. hourly R² of meter rise vs spend shifted earlier by L (per account, since Sep 1)")
            for L in (0, 30, 60, 120, 300, 600):
                row = []
                for a, g in ss[ss["t"] >= SINCE].groupby("account"):
                    if a not in spend:
                        continue
                    t0, t1, _, y = pairs(g["t"].to_numpy(), g["pct"].to_numpy(), g["resets_at"].to_numpy(), window)
                    h = pd.DataFrame({"b": (t1 // 3600).astype(int), "y": y, "x": spend[a](t0 - L, t1 - L)}).groupby("b").sum()
                    h = h[(h.x > 0) | (h.y > 0)]
                    if h.x.sum() < 20 or len(h) < 30:
                        continue
                    k = h.y.sum() / h.x.sum()
                    row.append(1 - ((h.y - k * h.x) ** 2).sum() / ((h.y - h.y.mean()) ** 2).sum())
                print(f"   L={L:3d}s  " + "  ".join(f"{v:.3f}" for v in row))

        # 2. Display rule on every reading
        parts, off = [], []
        for a, g in ss.groupby("account"):
            if a not in spend:
                continue
            t0, t1, r0, y = pairs(g["t"].to_numpy(), g["pct"].to_numpy(), g["resets_at"].to_numpy(), window)
            x = spend[a](t0, t1)
            parts.append(pd.DataFrame({"dur": t1 - t0, "r0": r0, "y": y, "x": x, "k": daily_factor(t1, y, x)}))
            hb = pd.DataFrame({"b": (t1 // 3600).astype(int), "y": y, "x": x}).groupby("b").sum()
            off.append(hb.y[hb.x < 0.05].sum() / max(hb.y.sum(), 1))
        iv = pd.concat(parts, ignore_index=True)
        iv = iv[iv.k.notna() & (iv.x > 0)]
        fill, r1 = iv.r0 + iv.k * iv.x, iv.r0 + iv.y
        print(f"2. every busy reading pair (n={len(iv)}), factor median {iv.k.median():.3f} points per API $")
        for name, shown in (("hold last", iv.r0), ("fill, rounded", np.round(fill)), ("fill, floored", np.floor(fill)), ("fill, exact", fill)):
            print(f"   {name:14s} mean error {np.abs(r1 - shown).mean():.2f}   steps down at the next reading {100 * (shown > r1).mean():4.1f}%")
        far = iv.dur >= 120
        print(f"   readings 2+ min apart ({100 * far.mean():.0f}%): hold {np.abs(r1 - iv.r0)[far].mean():.2f}, floored fill {np.abs(r1 - np.floor(fill))[far].mean():.2f}")

        # 3. One login: thin the busiest account to one reading per 5 minutes
        dense = ss[ss["t"] >= SINCE]
        a = dense.groupby("account").size().idxmax()
        g = dense[dense["account"] == a]
        t, p, r = g["t"].to_numpy(), g["pct"].to_numpy(), g["resets_at"].to_numpy()
        keep, last = np.zeros(len(t), bool), -np.inf
        for i, ti in enumerate(t):
            if ti - last >= THIN:
                keep[i], last = True, ti
        kt, kp, kr = t[keep], p[keep], r[keep]
        t0, t1, _, y = pairs(kt, kp, kr, window)
        k_pairs = daily_factor(t1, y, spend[a](t0, t1))
        j = np.searchsorted(kt, t, "right") - 1
        m = (j >= 0) & ~keep
        m[m] &= np.abs(r[m] - kr[j[m]]) < lab.WINDOWS[window] / 2
        j, tq, truth = j[m], t[m], p[m]
        k = np.interp(tq, t1, np.nan_to_num(k_pairs, nan=np.nanmedian(k_pairs)))
        hold = kp[j]
        live = np.minimum(100, hold + np.floor(k * spend[a](kt[j], tq)))
        burn = k * spend[a](tq - 1800, tq) * 2
        print(f"3. one login, readings thinned to one per {THIN / 60:.0f} min ({len(tq)} moments scored against the real readings)")
        for name, sel in (("all moments", np.ones(len(tq), bool)), ("20+ points/h", burn >= 20), ("40+ points/h", burn >= 40)):
            if sel.sum() < 20:
                continue
            eh, el = np.abs(truth - hold)[sel], np.abs(truth - live)[sel]
            print(f"   {name:13s} n={sel.sum():6d}  today: 2+ behind {100 * (eh >= 2).mean():4.1f}%, mean {eh.mean():.2f}, p95 {np.quantile(eh, .95):.0f}"
                  f"  |  live: 2+ off {100 * (el >= 2).mean():4.1f}%, mean {el.mean():.2f}, p95 {np.quantile(el, .95):.0f}, high {100 * (live > truth)[sel].mean():.1f}%")
        print("4. meter rise in hours with no local spend, per account: " + ", ".join(f"{100 * v:.0f}%" for v in off))


if __name__ == "__main__":
    main()
