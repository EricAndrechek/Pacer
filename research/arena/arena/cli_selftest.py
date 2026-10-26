"""`arena selftest`: run the harness self-tests and print a pass/fail table.

Registered into `arena/cli.py` like the other builders' subcommands. Runnable
on its own too: `python -m arena.cli_selftest --snapshot synth-default`.

    arena selftest [--snapshot ID] [--tier T] [--docker] [--only a,b] [--seed N] [--episodes N]

Exit code is 0 when every check passed or was skipped, 1 when any failed.
"""
from __future__ import annotations

import argparse
import sys

from arena.selftest import CHECKS, run_selftest


def register(subparsers) -> argparse.ArgumentParser:
    p = subparsers.add_parser("selftest", help="prove the harness: oracle, leaks, determinism, recovery",
                              description="Run the harness self-tests and print a pass/fail table.")
    _arguments(p)
    p.set_defaults(func=run)
    return p


def _arguments(p: argparse.ArgumentParser) -> None:
    p.add_argument("--snapshot", help="snapshot id (default $ARENA_SNAPSHOT or the newest)")
    p.add_argument("--tier", default="visible",
                   choices=("visible", "leaderboard", "lockbox", "synthetic", "prospective"),
                   help="which tier to draw episodes from (default visible)")
    p.add_argument("--docker", action="store_true",
                   help="also run the leak probe in a real Docker worker (needs Docker)")
    p.add_argument("--only", help=f"comma-separated subset of checks ({', '.join(CHECKS)})")
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--episodes", type=int, default=24)
    p.add_argument("--verbose", action="store_true", help="print progress and tracebacks to stderr")


def run(a: argparse.Namespace) -> int:
    only = tuple(x.strip() for x in a.only.split(",") if x.strip()) if a.only else None
    say = (lambda s: print(s, file=sys.stderr)) if a.verbose else (lambda s: None)
    rows = run_selftest(a.snapshot, tier=a.tier, seed=a.seed, episodes=a.episodes,
                        docker=a.docker, only=only, say=say)
    print(render(rows, snapshot=a.snapshot or "(default)", tier=a.tier, docker=a.docker))
    return 0 if all(r.passed for r in rows) else 1


def render(rows, *, snapshot: str, tier: str, docker: bool) -> str:
    head = f"arena selftest  snapshot {snapshot}  tier {tier}" + ("  +docker" if docker else "")
    w = max((len(r.name) for r in rows), default=4)
    lines = [head, "-" * len(head)]
    for r in rows:
        lines.append(f"  {r.mark:4s}  {r.name.ljust(w)}  {r.detail}")
    n_fail = sum(1 for r in rows if not r.passed)
    n_skip = sum(1 for r in rows if r.skipped)
    n_pass = len(rows) - n_fail - n_skip
    lines.append("-" * len(head))
    lines.append(f"  {n_pass} passed, {n_fail} failed, {n_skip} skipped")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="arena selftest")
    _arguments(p)
    return run(p.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
