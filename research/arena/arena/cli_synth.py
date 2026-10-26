"""`arena synth`: write a synthetic snapshot (synth/).

The core builder's `arena/cli.py` calls `register(subparsers)`; the parser
sets `func`, which takes the parsed args and returns an exit code. Also
runnable on its own: `python -m arena.cli_synth --out synth-default --seed 1`.
"""
from __future__ import annotations

import argparse
import json
import sys
import time


def register(subparsers) -> argparse.ArgumentParser:
    p = subparsers.add_parser(
        "synth", help="write a synthetic snapshot with known generating truth",
        description="Simulate users, accounts, meters and polling, and write a snapshot in the real "
                    "layout to <ARENA_HOME>/snapshots/<ID>, with truth/ (params.json, meter_true.parquet).")
    _arguments(p)
    p.set_defaults(func=run)
    return p


def _arguments(p: argparse.ArgumentParser) -> None:
    p.add_argument("--out", required=True, metavar="ID", help="snapshot id (directory under ARENA_HOME/snapshots)")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--users", type=int, default=None, help="number of users (default 6)")
    p.add_argument("--days", type=int, default=None, help="simulated days (default 120)")
    p.add_argument("--tiers", default=None, help="leaderboard,lockbox spans, e.g. 3w,3w (default)")
    p.add_argument("--start", default=None, help="ISO start, e.g. 2026-05-04T00:00:00Z")
    p.add_argument("--scale", type=float, default=None, help="multiply every user's activity")
    p.add_argument("--config", default=None, help="JSON file deep-merged over the defaults")
    p.add_argument("--out-dir", default=None, help="write here instead of ARENA_HOME/snapshots/ID")
    p.add_argument("--force", action="store_true", help="replace an existing snapshot")


def run(args: argparse.Namespace) -> int:
    from pathlib import Path

    from synth import generate, load_config

    cfg = load_config(args.config, seed=args.seed, users=args.users, days=args.days, tiers=args.tiers,
                      start=args.start, scale=args.scale)
    t0 = time.time()
    path = generate(cfg, args.out, out_dir=Path(args.out_dir) if args.out_dir else None, force=args.force)
    with open(path / "manifest.json") as fh:
        man = json.load(fh)
    rows = {n: sum(v["rows"].values()) for n, v in man["tables"].items()}
    print(f"wrote {path} in {time.time() - t0:.1f}s")
    for n, k in rows.items():
        print(f"  {n:22s} {k:>10,d}")
    print(f"  T_train {man['T_train_iso']}  T_leaderboard_end {man['T_leaderboard_end_iso']}  T_end {man['T_end_iso']}")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="arena synth")
    _arguments(p)
    return run(p.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
