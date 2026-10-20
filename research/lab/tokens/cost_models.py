"""Token forecasters on API-equivalent cost with ONE recalibrated factor.

Same shapes as token_models.py, but spend is converted to meter points by a
single points-per-dollar factor per account, refit daily on the last 14 days
of the account's reading intervals that ended before the case (the pooled
factor while an account has fewer than 100 such intervals). One parameter
follows the ~30% drift factor_over_time.py found, and holds up on thin
accounts where 25 token weights overfit.

  tokc-rate-<H>-cal   now + recent converted burn × in-cycle calibration × remaining
  tokc-decay-<H>      the same burn fading with a time constant learned
                      walk-forward per account and half of the window
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

TAUS_H = (0.5, 1, 2, 4, 8, 16, 48)
REFIT = 86400
WINDOW_DAYS = 14


def main() -> None:
    tok = pd.read_parquet(lab.DATA / "tokens.parquet").reset_index(drop=True)
    tok["cost"] = turn_costs(tok)
    led = {a: (g["t"].to_numpy(), np.concatenate([[0.0], np.cumsum(g["cost"].to_numpy())]))
           for a, g in tok.sort_values("t").groupby("account")}

    def spent(a, t0, t1):
        if a not in led:
            return np.zeros_like(np.asarray(t0, float))
        tt, cc = led[a]
        return cc[np.searchsorted(tt, t1, "right")] - cc[np.searchsorted(tt, t0, "right")]

    c = lab.cases()
    s = lab.samples()
    out: dict[str, list] = {}
    for window in lab.WINDOWS:
        iv = intervals(window)
        iv["spent"] = np.concatenate([spent(a, g["t0"].to_numpy(), g["t1"].to_numpy()) for a, g in iv.groupby("account", sort=False)]) \
            if False else 0.0
        parts = []
        for a, g in iv.groupby("account", sort=False):
            g = g.copy()
            g["spent"] = spent(a, g["t0"].to_numpy(), g["t1"].to_numpy())
            parts.append(g)
        iv = pd.concat(parts, ignore_index=True)
        t1, rise, sp, ac = iv["t1"].to_numpy(), iv["rise"].to_numpy(), iv["spent"].to_numpy(), iv["account"].to_numpy()
        cache: dict = {}

        def factor(a: str, t: float) -> float:
            key = (a, int(t // REFIT))
            if key not in cache:
                hi = key[1] * REFIT
                win = (t1 <= hi) & (t1 > hi - WINDOW_DAYS * 86400)
                own = win & (ac == a)
                use = own if own.sum() >= 100 else win
                cache[key] = float(rise[use].sum() / sp[use].sum()) if sp[use].sum() > 1 else np.nan
            return cache[key]

        lookbacks = {"30m": 1800, "1h": 3600} if not lab.weekly(window) else {"6h": 6 * 3600, "1d": 86400}
        sw = s[s["window"] == window]
        reads = {a: gg["t"].to_numpy() for a, gg in sw.groupby("account")}
        g = c[c["window"] == window].sort_values("t_cut").reset_index(drop=True)
        rows = []
        for r in g.itertuples(index=False):
            k = factor(r.account, r.t_cut)
            if not np.isfinite(k):
                continue
            tt = reads[r.account]
            j = np.searchsorted(tt, r.t_cut, "right") - 1
            t_last = tt[j] if j >= 0 else r.cycle_start
            now = min(100.0, r.used_now + k * float(spent(r.account, t_last, r.t_cut)))
            conv = k * float(spent(r.account, r.cycle_start, t_last))
            ratio = float(np.clip(r.used_now / conv, 0.25, 4.0)) if conv > 1 else 1.0
            remaining = r.resets_at - r.t_cut
            rec = {"case_id": r.case_id, "_acct": r.account, "_half": r.cut >= 0.5, "_reset": r.resets_at,
                   "_tcut": r.t_cut, "_truth": r.truth, "_used": r.used_now}
            for name, h in lookbacks.items():
                span = min(h, r.t_cut - r.cycle_start)
                burn = k * float(spent(r.account, r.t_cut - span, r.t_cut)) / span if span > 0 else 0.0
                rec[f"tokc-rate-{name}-cal"] = now + burn * ratio * remaining
                for tau_h in TAUS_H:
                    tau = tau_h * 3600
                    rec[f"_tau{tau_h}-{name}"] = now + burn * ratio * tau * (1 - np.exp(-remaining / tau))
            rows.append(rec)
        df = pd.DataFrame(rows)
        for name in lookbacks:
            cand = [f"_tau{t}-{name}" for t in TAUS_H]
            V = np.clip(df[cand].to_numpy(), df["_used"].to_numpy()[:, None], 100)
            E = np.abs(V - df["_truth"].to_numpy()[:, None])
            reset, tcut, acct, half = df["_reset"].to_numpy(), df["_tcut"].to_numpy(), df["_acct"].to_numpy(), df["_half"].to_numpy()
            pick = np.full(len(df), np.nan)
            for i in range(len(df)):
                m = (reset <= tcut[i]) & (acct == acct[i]) & (half == half[i])
                if m.sum() < 16:
                    m = (reset <= tcut[i]) & (half == half[i])
                if m.sum() < 16:
                    continue
                e = np.nanmean(E[m], axis=0) if lab.weekly(window) else np.nanmedian(E[m], axis=0)
                pick[i] = V[i, int(np.nanargmin(e))]
            df[f"tokc-decay-{name}"] = pick
        for col in [x for x in df.columns if x.startswith("tokc-")]:
            out.setdefault(col, []).append(df[["case_id", col]].rename(columns={col: "pred"}).dropna())
    for name, parts in out.items():
        lab.write_preds(name, pd.concat(parts, ignore_index=True))
    print("wrote", sorted(out))


if __name__ == "__main__":
    main()
