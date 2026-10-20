"""The engine's own candidates, as predictions over the case table.

preds/engine-<model>.parquet   each shipping model's displayed value at reset
preds/rule-current.parquet     the shipping selection (by half, 5% tie), walk-forward
preds/rule-old.parquet         the rule before #305 (all cuts, 1.5 pp tie)

Walk-forward per account, as the app's record grows: a cycle's selection reads
only cycles that reset before it. Uses the harness's model ports, so the
numbers match `pacer_replay` (the current rule: 5h median ≈ 3.57 pp).
"""
from __future__ import annotations

from dataclasses import replace

import pandas as pd

import lab
from pacer_replay import (
    MODEL_COMPLEXITY, Params, Partial, best_method, diurnal_rate_table, displayed_at_reset,
    method_errors, model_roster, segment, typical,
)

BASE = Params()
RULES = {"rule-current": BASE,
         "rule-old": replace(BASE, rl_select_by_phase=False, rl_tie_relative=0.0)}


def shown_for(record, params, is_weekly, ph, chosen, row):
    if chosen in row:
        return chosen
    ranked = sorted(row, key=lambda m: (typical(method_errors(record.get(m, {}), params, ph), is_weekly),
                                        MODEL_COMPLEXITY.get(m, 3)))
    return ranked[0] if ranked else None


def main() -> None:
    c = lab.cases()
    s = lab.samples()
    g = lab.grids()
    by_case = c.set_index("case_id")
    model_rows: dict[str, list] = {}
    rule_rows: dict[str, list] = {r: [] for r in RULES}
    for window, duration in lab.WINDOWS.items():
        is_weekly = lab.weekly(window)
        default = "diurnal-rate" if is_weekly else "recency-weighted"
        for account, ss in s[s["window"] == window].groupby("account"):
            rows = list(ss.sort_values("t")[["t", "pct", "resets_at"]].itertuples(index=False, name=None))
            completed = segment(rows, duration)[:-1]
            record: dict = {}
            for i, cyc in enumerate(completed):
                truth = cyc.final
                if truth <= 0:
                    continue
                roster = model_roster(diurnal_rate_table(completed[:i], g.get(account, g[""])))
                chosen = {name: {ph: best_method(record, p, is_weekly, ph) or default for ph in ("early", "late")}
                          for name, p in RULES.items()}
                period_key = str(round(cyc.resets_at / 60) * 60)
                for cut in lab.CUTS:
                    case_id = f"{window}|{account}|{int(round(cyc.resets_at))}|{cut:.1f}"
                    if case_id not in by_case.index:
                        continue
                    t_cut = cyc.cycle_start + cyc.duration * cut
                    seen = [x for x in cyc.samples if x[0] <= t_cut]
                    partial = Partial(seen, t_cut, cyc.cycle_start, cyc.resets_at)
                    row = {}
                    for mid, fit in roster.items():
                        proj = fit(partial, BASE)
                        if proj is not None:
                            row[mid] = displayed_at_reset(proj, partial)
                    for mid, v in row.items():
                        model_rows.setdefault(mid, []).append((case_id, v))
                    ph = "early" if cut < 0.5 else "late"
                    for name, p in RULES.items():
                        m = shown_for(record, p, is_weekly, ph, chosen[name][ph], row)
                        if m is not None:
                            rule_rows[name].append((case_id, row[m], m))
                    for mid, v in row.items():
                        record.setdefault(mid, {}).setdefault(period_key, []).append((cut, abs(v - truth)))
    for mid, rows in model_rows.items():
        lab.write_preds(f"engine-{mid}", pd.DataFrame(rows, columns=["case_id", "pred"]))
    for name, rows in rule_rows.items():
        df = pd.DataFrame(rows, columns=["case_id", "pred", "model"])
        lab.write_preds(name, df)
        df.to_parquet(lab.PREDS / f"{name}.choices.parquet", index=False)
    print("wrote", sorted(f"engine-{m}" for m in model_rows), list(RULES))


if __name__ == "__main__":
    main()
