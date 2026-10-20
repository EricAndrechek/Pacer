"""Forecasters driven by token usage instead of meter readings.

Each case converts the account's tokens to meter points with NNLS weights
(per model family × token kind, see meter_from_tokens.py) fit walk-forward on
reading intervals that ENDED before the case's last weekly refit; pooled
weights stand in while an account has fewer than 300 intervals.

  tok-nowcast       the meter now: last reading + converted tokens since it,
                    held to the reset (what the meter alone can't know yet)
  tok-rate-<H>      the nowcast plus the last H's converted burn, continued to
                    the reset at the same rate (H = 30m, 1h, 2h on 5h windows;
                    6h, 1d, 2d on 7d)
  tok-rate-<H>-cal  the same, the burn scaled by how much of the converted
                    burn the meter actually showed this cycle so far

  uv run tokens/token_models.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.optimize import nnls

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lab  # noqa: E402
from meter_from_tokens import KINDS, family, intervals  # noqa: E402

FAMS = ("fable", "opus", "sonnet", "haiku", "other")
COLS = [f"{f}:{k}" for f in FAMS for k in KINDS]
REFIT = 7 * 86400
TAUS_H = (0.5, 1, 2, 4, 8, 16, 48)


class TokenLedger:
    """Cumulative converted-token sums per account, by feature column."""

    def __init__(self):
        tok = pd.read_parquet(lab.DATA / "tokens.parquet")
        tok["family"] = tok["model"].map(family)
        self.by = {}
        for acct, g in tok.groupby("account"):
            tt = g["t"].to_numpy()
            M = np.zeros((len(g), len(COLS)))
            fam = g["family"].to_numpy()
            for j, col in enumerate(COLS):
                f, k = col.split(":")
                M[:, j] = np.where(fam == f, g[k].fillna(0).to_numpy(), 0.0) / 1e6
            self.by[acct] = (tt, np.vstack([np.zeros(len(COLS)), np.cumsum(M, axis=0)]))

    def between(self, acct: str, t0: np.ndarray, t1: np.ndarray) -> np.ndarray:
        if acct not in self.by:
            return np.zeros((len(t0), len(COLS)))
        tt, cum = self.by[acct]
        return cum[np.searchsorted(tt, t1, "right")] - cum[np.searchsorted(tt, t0, "right")]


def main() -> None:
    led = TokenLedger()
    c = lab.cases()
    s = lab.samples()
    out = {}
    for window in lab.WINDOWS:
        iv = intervals(window)
        Xiv = np.vstack([led.between(a, g["t0"].to_numpy(), g["t1"].to_numpy()) for a, g in iv.groupby("account", sort=False)])
        iv = pd.concat([g for _, g in iv.groupby("account", sort=False)], ignore_index=True)
        y = iv["rise"].to_numpy()
        lookbacks = {"30m": 1800, "1h": 3600, "2h": 7200} if not lab.weekly(window) else \
            {"6h": 6 * 3600, "1d": 86400, "2d": 2 * 86400}
        g = c[c["window"] == window].sort_values("t_cut")
        weights_cache: dict[tuple[str, int], np.ndarray] = {}

        def weights(acct: str, t: float) -> np.ndarray:
            epoch = int(t // REFIT)
            key = (acct, epoch)
            if key not in weights_cache:
                cutoff = epoch * REFIT
                own = (iv["account"] == acct).to_numpy() & (iv["t1"].to_numpy() <= cutoff)
                use = own if own.sum() >= 300 else (iv["t1"].to_numpy() <= cutoff)
                weights_cache[key] = nnls(Xiv[use], y[use])[0] if use.sum() >= 50 else np.zeros(len(COLS))
            return weights_cache[key]

        sw = s[s["window"] == window]
        last_read = {a: (gg["t"].to_numpy(), gg["pct"].to_numpy()) for a, gg in sw.groupby("account")}
        rows = []
        for r in g.itertuples(index=False):
            w = weights(r.account, r.t_cut)
            tt, pp = last_read[r.account]
            k = np.searchsorted(tt, r.t_cut, "right") - 1
            t_last = tt[k] if k >= 0 else r.cycle_start
            since = float(led.between(r.account, np.array([t_last]), np.array([r.t_cut]))[0] @ w)
            now = min(100.0, r.used_now + since)
            remaining = r.resets_at - r.t_cut
            rec = {"case_id": r.case_id, "tok-nowcast": now}
            # How much of the converted burn the meter showed this cycle (drift guard).
            conv_cycle = float(led.between(r.account, np.array([r.cycle_start]), np.array([t_last]))[0] @ w)
            ratio = np.clip(r.used_now / conv_cycle, 0.25, 4.0) if conv_cycle > 1 else 1.0
            for name, h in lookbacks.items():
                span = min(h, r.t_cut - r.cycle_start)
                if span <= 0:
                    continue
                burn = float(led.between(r.account, np.array([r.t_cut - span]), np.array([r.t_cut]))[0] @ w) / span
                rec[f"tok-rate-{name}"] = now + burn * remaining
                rec[f"tok-rate-{name}-cal"] = now + burn * ratio * remaining
                # The burn fading with time constant tau (bursts end): the
                # expected remaining rise is burn·tau·(1 − e^(−remaining/tau)).
                for tau_h in TAUS_H:
                    tau = tau_h * 3600
                    rec[f"_tau{tau_h}-{name}"] = now + burn * ratio * tau * (1 - np.exp(-remaining / tau))
            rows.append(rec)
        df = pd.DataFrame(rows)
        # tok-decay-<H>: tau chosen walk-forward per account and half of the
        # window, from cases of cycles that reset before this case.
        meta = g.set_index("case_id").loc[df["case_id"]]
        reset, tcut = meta["resets_at"].to_numpy(), meta["t_cut"].to_numpy()
        acct, half = meta["account"].to_numpy(), (meta["cut"].to_numpy() >= 0.5)
        truth = meta["truth"].to_numpy()
        used = meta["used_now"].to_numpy()
        for name in lookbacks:
            cand = [f"_tau{t}-{name}" for t in TAUS_H if f"_tau{t}-{name}" in df]
            if not cand:
                continue
            V = np.clip(df[cand].to_numpy(), used[:, None], 100)
            E = np.abs(V - truth[:, None])
            pick = np.full(len(df), np.nan)
            for i in range(len(df)):
                m = (reset <= tcut[i]) & (acct == acct[i]) & (half == half[i])
                if m.sum() < 16:
                    m = (reset <= tcut[i]) & (half == half[i])
                if m.sum() < 16:
                    continue
                e = np.nanmean(E[m], axis=0) if lab.weekly(window) else np.nanmedian(E[m], axis=0)
                j = int(np.nanargmin(e))
                pick[i] = V[i, j]
            df[f"tok-decay-{name}"] = pick
        df = df[[c for c in df.columns if not c.startswith("_")]]
        for col in df.columns:
            if col != "case_id":
                out.setdefault(col, []).append(df[["case_id", col]].rename(columns={col: "pred"}).dropna())
    for name, parts in out.items():
        lab.write_preds(name, pd.concat(parts, ignore_index=True))
    print("wrote", sorted(out))


if __name__ == "__main__":
    main()
