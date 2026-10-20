"""Should the selection rule itself be chosen, or models combined instead of picked?

Replays, walk-forward over the real store, competing selection rules (all-time
vs by half of the window, absolute vs relative tie, recent cycles only), a
meta-selector that picks among those rules by their own record, and a
combination (the median of the top three models' shown values for that half
of the window), alone and as one more candidate in the current race.

Every past cut's shown value for every model is computed once per cycle (the
same fits the record update makes), so a rule's call, a combination's value
and the meta-selector's choice are lookups, not new fits: ~25 s for full
history. Point accuracy only (the headline error and the 4 time folds the
adoption rule reads); no bands.

First run, 2026-10-20 (v1-c13c3f81, full history): nothing beat the current
rule. 5h: meta with a 5% switching margin 3.55 vs 3.57 pp (2/4 folds), without
a margin 3.65 (it chases noise), top-3 median 3.77. 7d: top-3 median 7.97 vs
8.18 (2/4 folds, one large win and one loss), meta never switched. The 7d
combination is the result to re-test as weekly cycles accumulate:
    uv run selection_strategies.py
"""
from __future__ import annotations

import statistics
import sys
from dataclasses import replace

from pacer_replay import (
    MODEL_COMPLEXITY, RL_CUT_FRACTIONS, WINDOW_SECONDS, Params, Partial, best_method,
    diurnal_rate_table, displayed_at_reset, grid_loader, is_weekly_scale, locate_store,
    method_errors, model_roster, open_copy, phase_of, rate_samples_by_account, segment, typical,
)

BASE = Params()
SELECTORS = {
    "all-time, 1.5pp tie (old)": replace(BASE, rl_select_by_phase=False, rl_tie_relative=0.0),
    "all-time, 5% tie": replace(BASE, rl_select_by_phase=False),
    "half, 5% tie (current)": BASE,
    "half, 5% tie, last 30": replace(BASE, rl_selection_recency=30),
    "half, 5% tie, last 15": replace(BASE, rl_selection_recency=15),
}
CURRENT = "half, 5% tie (current)"
ENS = "ens-top3"   # median of the top 3 models' shown values, ranked by this half's record


def rank_available(record, params, weekly, ph, available):
    return sorted(available, key=lambda m: (typical(method_errors(record.get(m, {}), params, ph), weekly),
                                            MODEL_COMPLEXITY.get(m, 3)))


def shown_for(record, params, weekly, ph, chosen, available):
    """The selector's chosen model if it can fit this cut, else the best-recorded one that can (resolve_model)."""
    if chosen in available:
        return chosen
    ranked = rank_available(record, params, weekly, ph, available)
    return ranked[0] if ranked else None


def replay(window, samples, grid, meta_min_cycles=10, meta_margin=0.05):
    duration = WINDOW_SECONDS[window]
    weekly = is_weekly_scale(duration)
    cycles = segment(samples, duration)
    completed = cycles[:-1] if cycles else []
    record: dict[str, dict[str, list]] = {}            # models + the combination
    sel_record: dict[str, list] = {s: [] for s in SELECTORS}   # (phase, err) per selector
    cases = []                                          # (cycle_start, {strategy: err})
    default = "diurnal-rate" if weekly else "recency-weighted"
    incumbent = {"early": CURRENT, "late": CURRENT}
    for i, cyc in enumerate(completed):
        truth = cyc.final
        if truth <= 0:
            continue
        roster = model_roster(diurnal_rate_table(completed[:i], grid))
        disp: dict[float, dict[str, float]] = {}
        for cf in RL_CUT_FRACTIONS:
            cut_now = cyc.cycle_start + cyc.duration * cf
            seen = [s for s in cyc.samples if s[0] <= cut_now]
            if len(seen) < 3:
                continue
            partial = Partial(seen, cut_now, cyc.cycle_start, cyc.resets_at)
            row = {}
            for mid, fit in roster.items():
                proj = fit(partial, BASE)
                if proj is not None:
                    row[mid] = displayed_at_reset(proj, partial)
            if row:
                disp[cf] = row

        # Decisions, from the record before this cycle. Ordinary rules choose
        # among the models only; the combination competes in its own strategy.
        models_only = {m: v for m, v in record.items() if m != ENS}
        chosen = {s: {ph: best_method(models_only, p, weekly, ph) or default for ph in ("early", "late")}
                  for s, p in SELECTORS.items()}
        # The meta-selector: per half, the selector with the lowest typical
        # error over past cycles, switching away from the incumbent only when
        # better by meta_margin and after meta_min_cycles cycles of record.
        meta_pick = {}
        for ph in ("early", "late"):
            errs = {s: [e for (p, e) in sel_record[s] if p == ph] for s in SELECTORS}
            if i >= meta_min_cycles and all(errs.values()):
                score = {s: typical(v, weekly) for s, v in errs.items()}
                best = min(score, key=score.get)
                if score[best] < score[incumbent[ph]] * (1 - meta_margin):
                    incumbent[ph] = best
            meta_pick[ph] = incumbent[ph]
        meta_free = {}
        for ph in ("early", "late"):
            errs = {s: [e for (p, e) in sel_record[s] if p == ph] for s in SELECTORS}
            meta_free[ph] = (min(errs, key=lambda s: typical(errs[s], weekly))
                             if i >= meta_min_cycles and all(errs.values()) else CURRENT)

        for cf, row in disp.items():
            ph = phase_of(cf)
            available = list(row)
            out = {}
            for s, p in SELECTORS.items():
                m = shown_for(models_only, p, weekly, ph, chosen[s][ph], available)
                if m is not None:
                    out[s] = abs(row[m] - truth)
            top = rank_available(models_only, BASE, weekly, ph, available)[:3]
            ens_value = statistics.median(row[m] for m in top) if top else None
            if ens_value is not None:
                out["combination: median of top 3"] = abs(ens_value - truth)
                # The combination entered as one more candidate in the current race.
                pick = best_method(record, BASE, weekly, ph) or default
                if pick == ENS:
                    out["current + combination as a candidate"] = abs(ens_value - truth)
                else:
                    m = shown_for(record, BASE, weekly, ph, pick, available + [])
                    m = m if m in row else shown_for(models_only, BASE, weekly, ph, pick, available)
                    out["current + combination as a candidate"] = abs(row[m] - truth)
            if meta_pick[ph] in out:
                out["meta: pick the best rule (5% margin)"] = out[meta_pick[ph]]
            if meta_free[ph] in out:
                out["meta: pick the best rule (no margin)"] = out[meta_free[ph]]
            cases.append((cyc.cycle_start, cf, out))

        # Extend the records walk-forward.
        period_key = str(round(cyc.resets_at / 60) * 60)
        for cf, row in disp.items():
            for mid, v in row.items():
                record.setdefault(mid, {}).setdefault(period_key, []).append((cf, abs(v - truth)))
            ph = phase_of(cf)
            top = rank_available(models_only, BASE, weekly, ph, list(row))[:3]
            if top:
                record.setdefault(ENS, {}).setdefault(period_key, []).append(
                    (cf, abs(statistics.median(row[m] for m in top) - truth)))
        for (cs, cf, out) in cases[-len(disp):] if disp else []:
            for s in SELECTORS:
                if s in out:
                    sel_record[s].append((phase_of(cf), out[s]))
    return cases


def main():
    conn = open_copy(locate_store(None))
    grids = grid_loader(conn)
    for window in ("five_hour", "seven_day"):
        weekly = is_weekly_scale(WINDOW_SECONDS[window])
        cases = []
        for acct, samples in sorted(rate_samples_by_account(conn, window).items()):
            cases += replay(window, samples, grids(acct))
        cases.sort(key=lambda c: c[0])
        strategies = sorted({k for _, _, o in cases for k in o})
        n = len(cases)
        folds = [cases[k * n // 4:(k + 1) * n // 4] for k in range(4)]
        print(f"\n== {window}: {n} cases, headline = {'mean' if weekly else 'median'} |error| (pp), and per fold")
        base = [typical([o[CURRENT] for _, _, o in f if CURRENT in o], weekly) for f in folds]
        for s in strategies:
            errs = [o[s] for _, _, o in cases if s in o]
            fold = [typical([o[s] for _, _, o in f if s in o], weekly) for f in folds]
            wins = sum(1 for a, b in zip(fold, base) if a < b)
            print(f"  {s:42s} {typical(errs, weekly):6.2f}  (n={len(errs)})  folds "
                  + " ".join(f"{x:5.2f}" for x in fold) + f"  beats current in {wins}/4")


if __name__ == "__main__":
    sys.exit(main())
