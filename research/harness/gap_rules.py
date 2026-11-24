"""What the reading-gap grading rule (#424) does to the rate-limit forecasts, on the real store.

A gap is two consecutive polls more than 30 minutes apart (ReadingCoverage.maxGap).
Each configuration is replayed walk-forward (pacer_replay.GapRules):

- #424 as asked: no grade at a cut inside a gap, and no truth on a cycle whose
  readings stopped more than 30 minutes before its reset (censored);
- #424 shipped: the cut rule only (censoring was measured worse).

Every configuration is scored on the same cases: the cycles whose end was seen, at the
cuts the readings show (pacer_replay.EVAL_CLEAN), on the app's current grid (v3, twelve
cuts from 0.1).

Usage:
    uv run gap_rules.py [--store PATH] [--window five_hour|seven_day] [--json]
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from collections import defaultdict

import pacer_replay as pr

CONFIGS = [
    ("before", pr.GapRules(grading=False)),
    ("#424 as asked", pr.GapRules(grading=True, censor=True)),
    ("#424 shipped", pr.GapRules()),
]


def stage(cut: float) -> str:
    """EngineSelfEval.Accuracy.Stage."""
    return "early" if cut < 0.45 else "middle" if cut < 0.75 else "late"


def median(xs):
    xs = sorted(xs)
    n = len(xs)
    if not n:
        return None
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2


def stats(scores) -> dict:
    banded = [s for s in scores if s.covered80 is not None]
    errs = [s.abs_error for s in scores]
    return {
        "cases": len(scores),
        "median": round(median(errs), 2) if errs else None,
        "mean": round(sum(errs) / len(errs), 2) if errs else None,
        "coverage80": round(sum(1 for s in banded if s.covered80) / len(banded), 3) if banded else None,
        "banded": len(banded),
    }


def gaps_before(cycle: pr.Cycle, now: float) -> bool:
    """Whether the readings up to `now` cross a gap, or start more than MAX_GAP into the
    window: the cases a fit reads across a gap at."""
    seen = [s for s in cycle.samples if s[0] <= now]
    if not seen:
        return False
    if seen[0][0] - cycle.cycle_start > pr.MAX_GAP:
        return True
    return any(b[0] - a[0] > pr.MAX_GAP for a, b in zip(seen, seen[1:]))


def coverage(by_account: dict, duration: float) -> dict:
    """How much of the record the grading rule takes out (rule-independent).
    Cuts are placed on each cycle's own span (`Cycle.duration`), as scoring
    places them: a cycle cut short by an off-schedule reset is shorter than
    the window."""
    out = defaultdict(int)
    for samples in by_account.values():
        cycles = pr.segment(samples, duration)[:-1]
        for c in cycles:
            if c.final <= 0:
                continue
            out["cycles"] += 1
            in_cycle_gap = any(b[0] - a[0] > pr.MAX_GAP for a, b in zip(c.samples, c.samples[1:]))
            late = c.samples[0][0] - c.cycle_start > pr.MAX_GAP
            out["cycles with a gap inside"] += in_cycle_gap
            out["cycles first read >30 min in"] += late
            if not c.end_seen:
                out["cycles with an unread end"] += 1
            for cf in pr.RL_CUT_FRACTIONS_V3:
                now = c.cycle_start + c.duration * cf
                before = c.graded_readings(now, rule=False) is not None
                after = c.graded_final(rule=True) is not None and c.graded_readings(now, rule=True) is not None
                out["cuts graded before"] += before
                out["cuts the cut rule drops"] += before and c.graded_readings(now, rule=True) is None
                out["cuts scored (seen end, outside a gap)"] += after
                out["cuts censoring would drop"] += before and not c.end_seen
    return dict(out)


def replay(conn, window: str, grid_for, by_account: dict, rules: pr.GapRules):
    pr.GAPS = rules
    scores = []
    for acct, samples in sorted(by_account.items()):
        for sc in pr.replay_window(window, samples, grid_for(acct), pr.Params()):
            scores.append((acct, sc))
    return scores


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--store", help="path to pacer.sqlite (default: app group); copied, read-only")
    ap.add_argument("--window", choices=["five_hour", "seven_day"], help="one window only")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    started = time.time()

    def progress(msg: str) -> None:
        print(f"[{time.time() - started:7.1f}s] {msg}", file=sys.stderr, flush=True)

    conn = pr.open_copy(pr.locate_store(args.store))
    grid_for = pr.grid_loader(conn)
    pr.RL_CUT_FRACTIONS = pr.RL_CUT_FRACTIONS_V3
    pr.EVAL_CLEAN = True
    report: dict = {}
    for window in ([args.window] if args.window else ["five_hour", "seven_day"]):
        duration = pr.WINDOW_SECONDS[window]
        by_account = pr.rate_samples_by_account(conn, window)
        w: dict = {"coverage": coverage(by_account, duration), "configs": {}}
        cycles_by_acct = {a: pr.segment(s, duration)[:-1] for a, s in by_account.items()}
        progress(f"{window}: coverage done")
        for name, rules in CONFIGS:
            tagged = replay(conn, window, grid_for, by_account, rules)
            progress(f"{window}: {name} replayed")
            scores = [sc for _, sc in tagged]
            by_stage = {st: stats([s for s in scores if stage(s.cut) == st]) for st in ("early", "middle", "late")}
            affected = []
            for acct, sc in tagged:
                cyc = cycles_by_acct[acct][sc.cycle_index]
                if gaps_before(cyc, cyc.cycle_start + cyc.duration * sc.cut):
                    affected.append(sc)
            w["configs"][name] = {"all": stats(scores), **by_stage, "after a gap or a late start": stats(affected)}
        report[window] = w
    pr.GAPS = pr.GapRules()

    if args.json:
        print(json.dumps(report, indent=1))
        return
    for window, w in report.items():
        print(f"\n=== {window}")
        print("  coverage:", ", ".join(f"{k} {v}" for k, v in w["coverage"].items()))
        print(f"  {'config':<18} {'slice':<28} {'cases':>6} {'median':>7} {'mean':>7} {'cov80':>6}")
        for name, slices in w["configs"].items():
            for sl, s in slices.items():
                print(f"  {name:<18} {sl:<28} {s['cases']:>6} {s['median']!s:>7} {s['mean']!s:>7} {s['coverage80']!s:>6}")


if __name__ == "__main__":
    main()
