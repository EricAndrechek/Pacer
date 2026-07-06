"""Weekly self-improvement check — deterministic, no LLM required.

Runs the walk-forward replay against the live store, compares against the
committed baselines, checks shadow-candidate promotion progress from the
app's own eval record, and runs the default parameter sweep. Emits a macOS
notification ONLY when something is actionable:

- 80%-band coverage drifted outside [0.70, 0.92] (on ≥ 20 banded cases)
- median |end-at-reset error| worsened ≥ 25% vs baseline
- a shadow candidate reached its promotion floor (once per candidate)
- the sweep found a fold-robust parameter improvement

Every run appends one JSON line to reports/log.jsonl regardless, so the
history of checks is inspectable. Scheduled by a LaunchAgent (see
`uv run weekly_check.py --install-agent`); quiet weeks cost zero attention.
"""

from __future__ import annotations

import json
import plistlib
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from pacer_replay import (
    Params, load_activity_grid, load_rate_samples, locate_store, open_copy,
    replay_window, summarize,
)
from sweep import DEFAULT_GRID, fold_medians, robust_improvement

HERE = Path(__file__).resolve().parent
REPORTS = HERE / "reports"
BASELINES = HERE / "baselines.json"

SHADOWS = {"rl-five_hour": ["kalman-trend", "diurnal-rate"], "rl-seven_day": ["kalman-trend"]}
COVERAGE_OK = (0.70, 0.92)
MIN_BANDED_FOR_ALARM = 20
MEDIAN_WORSEN_FACTOR = 1.25


def notify(title: str, body: str) -> None:
    subprocess.run(["osascript", "-e",
                    f'display notification "{body}" with title "{title}"'], check=False)


def banded_cases(scores) -> int:
    return sum(1 for s in scores if s.covered80 is not None)


def shadow_progress(conn) -> dict[str, dict[str, int]]:
    """Distinct scored periods per shadow method per surface, from the app's
    own persisted record (the same numbers the promotion gate reads)."""
    out: dict[str, dict[str, int]] = {}
    for surface, methods in SHADOWS.items():
        for m in methods:
            n = conn.execute(
                "SELECT COUNT(DISTINCT ZPERIODKEY) FROM ZENGINEEVALOUTCOME "
                "WHERE ZSURFACE = ? AND ZMETHOD = ?", (surface, m)).fetchone()[0]
            out.setdefault(surface, {})[m] = int(n)
    return out


def run_check() -> int:
    conn = open_copy(locate_store(None))
    grid = load_activity_grid(conn)
    params = Params()
    baselines = json.loads(BASELINES.read_text()) if BASELINES.exists() else {}
    actionable: list[str] = []
    result = {"at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
              "paramsVersion": params.version_tag(), "windows": {}, "shadows": {}}

    all_scores = {}
    for window in ("five_hour", "seven_day"):
        samples = load_rate_samples(conn, window)
        scores = replay_window(window, samples, grid, params)
        all_scores[window] = scores
        s = summarize(scores)
        result["windows"][window] = {k: s.get(k) for k in
                                     ("cases", "medianAbsErrorPP", "coverage80", "bandStatedShare", "brier")}
        base = baselines.get(window, {})
        cov = s.get("coverage80")
        if cov is not None and banded_cases(scores) >= MIN_BANDED_FOR_ALARM \
                and not (COVERAGE_OK[0] <= cov <= COVERAGE_OK[1]):
            actionable.append(f"{window}: coverage drifted to {cov}")
        med, base_med = s.get("medianAbsErrorPP"), base.get("medianAbsErrorPP")
        if med and base_med and med > base_med * MEDIAN_WORSEN_FACTOR:
            actionable.append(f"{window}: median error {med}pp vs baseline {base_med}pp")

    # Shadow promotion progress (notify once per candidate crossing the floor).
    REPORTS.mkdir(exist_ok=True)
    seen_file = REPORTS / "promotions-seen.json"
    seen = set(json.loads(seen_file.read_text())) if seen_file.exists() else set()
    progress = shadow_progress(conn)
    result["shadows"] = progress
    for surface, methods in progress.items():
        for m, n in methods.items():
            key = f"{surface}|{m}"
            if n >= params.shadow_promotion_min_periods and key not in seen:
                actionable.append(f"{m} reached its promotion floor on {surface} ({n} cycles)")
                seen.add(key)
    seen_file.write_text(json.dumps(sorted(seen)))

    # Parameter sweep (default grid) with the fold-robust adoption rule.
    keys = sorted(DEFAULT_GRID)
    import itertools
    from dataclasses import replace
    base_folds = {w: fold_medians(all_scores[w]) for w in all_scores}
    base_meds = {w: result["windows"][w]["medianAbsErrorPP"] for w in all_scores}
    for values in itertools.product(*(DEFAULT_GRID[k] for k in keys)):
        cand = replace(Params(), **dict(zip(keys, values)))
        if cand.canonical() == Params().canonical():
            continue
        for window in all_scores:
            samples = load_rate_samples(conn, window)
            scores = replay_window(window, samples, grid, cand)
            s = summarize(scores)
            if robust_improvement(base_folds[window], fold_medians(scores),
                                  base_meds[window], s.get("medianAbsErrorPP"), s.get("coverage80")):
                actionable.append(
                    f"{window}: sweep found fold-robust improvement {cand.version_tag()} "
                    f"(median {s.get('medianAbsErrorPP')}pp) — {cand.canonical()}")

    result["actionable"] = actionable
    with (REPORTS / "log.jsonl").open("a") as f:
        f.write(json.dumps(result) + "\n")
    if actionable:
        notify("Pacer prediction check", "; ".join(actionable)[:200])
        print("ACTIONABLE:\n  " + "\n  ".join(actionable))
    else:
        print("quiet week — nothing actionable")
    for w, s in result["windows"].items():
        print(f"  {w}: {s}")
    print(f"  shadows: {progress}")
    return 0


def install_agent() -> int:
    """Install the LaunchAgent that runs this check weekly (Mon 09:23)."""
    uv = subprocess.run(["/bin/zsh", "-lc", "command -v uv"],
                        capture_output=True, text=True).stdout.strip()
    if not uv:
        print("uv not found on PATH", file=sys.stderr)
        return 1
    label = "com.ericandrechek.pacer.harness-weekly"
    logs = Path.home() / "Library/Logs/Pacer"
    logs.mkdir(parents=True, exist_ok=True)
    plist = {
        "Label": label,
        "ProgramArguments": [uv, "run", "--project", str(HERE), str(HERE / "weekly_check.py")],
        "WorkingDirectory": str(HERE),
        "StartCalendarInterval": {"Weekday": 1, "Hour": 9, "Minute": 23},
        "StandardOutPath": str(logs / "harness-weekly.log"),
        "StandardErrorPath": str(logs / "harness-weekly.log"),
    }
    dest = Path.home() / "Library/LaunchAgents" / f"{label}.plist"
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(plistlib.dumps(plist))
    subprocess.run(["launchctl", "unload", str(dest)], capture_output=True)
    subprocess.run(["launchctl", "load", str(dest)], check=True)
    print(f"installed + loaded {dest} (runs Mondays 09:23; log: {logs / 'harness-weekly.log'})")
    return 0


if __name__ == "__main__":
    sys.exit(install_agent() if "--install-agent" in sys.argv else run_check())
