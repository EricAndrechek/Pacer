"""Freeze the live store into data/: every rate-limit reading (live cache and
archive), the case table, and each account's activity prior.

Reads through the harness (`pacer_replay.open_copy`: an APFS clone, opened
read-only, removed at exit), so the cases are exactly the cycles and cuts the
app's record scores. Run once; every candidate then reads the same snapshot.
"""
from __future__ import annotations

import json

import numpy as np
import pandas as pd

import lab
from pacer_replay import grid_loader, locate_store, open_copy, rate_samples_by_account, segment


def main() -> None:
    conn = open_copy(locate_store(None))
    grid_for = grid_loader(conn)
    sample_rows, case_rows, grids = [], [], {}
    for window, duration in lab.WINDOWS.items():
        for account, rows in sorted(rate_samples_by_account(conn, window).items()):
            grids.setdefault(account, grid_for(account))
            sample_rows += [(window, account, t, pct, resets) for t, pct, resets in rows]
            cycles = segment(rows, duration)
            for cyc in cycles[:-1]:                      # the last one is live
                truth = cyc.final
                if truth <= 0:
                    continue
                for cut in lab.CUTS:
                    t_cut = cyc.cycle_start + cyc.duration * cut
                    seen = [s for s in cyc.samples if s[0] <= t_cut]
                    if len(seen) < 3:
                        continue
                    case_rows.append({
                        "case_id": f"{window}|{account}|{int(round(cyc.resets_at))}|{cut:.1f}",
                        "window": window, "account": account,
                        "cycle_start": cyc.cycle_start, "resets_at": cyc.resets_at,
                        "t_cut": t_cut, "cut": cut, "used_now": seen[-1][1], "truth": truth,
                    })
    grids.setdefault("", grid_for(""))
    lab.DATA.mkdir(exist_ok=True)
    s = pd.DataFrame(sample_rows, columns=["window", "account", "t", "pct", "resets_at"])
    s.to_parquet(lab.DATA / "samples.parquet", index=False)
    c = pd.DataFrame(case_rows)
    c["fold"] = 0
    for window, g in c.groupby("window"):
        q = np.quantile(g["cycle_start"], [0.25, 0.5, 0.75])
        c.loc[g.index, "fold"] = np.searchsorted(q, g["cycle_start"].to_numpy(), side="right")
    c.to_parquet(lab.DATA / "cases.parquet", index=False)
    (lab.DATA / "grids.json").write_text(json.dumps(grids))
    print(f"samples {len(s):,}  cases {len(c):,}")
    print(c.groupby(["window", "account"]).size().rename("cases").to_string())


if __name__ == "__main__":
    main()
