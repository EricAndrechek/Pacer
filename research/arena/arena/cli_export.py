"""`arena export`: build a snapshot from copies of Pacer's store and the raw
Claude Code transcripts (docs/snapshot-spec.md). Registered by `arena/cli.py`
through `register(subparsers)`; also runnable on its own as
`python -m arena.cli_export …`."""
from __future__ import annotations

import argparse
import json
import sys


def register(subparsers) -> argparse.ArgumentParser:
    p = subparsers.add_parser("export", help="build a snapshot from copies of Pacer's store and the transcripts",
                              description=__doc__)
    p.add_argument("--id", dest="snapshot_id", default=None,
                   help="snapshot id (default: working-<UTC date>)")
    p.add_argument("--freeze", action="store_true", help="mark the snapshot frozen (never overwritten)")
    p.add_argument("--t-train", default=None, help="ISO time of T_train (default: start of the leaderboard tier)")
    p.add_argument("--tiers", default="3w,3w", help="leaderboard,lockbox lengths before T_end (default 3w,3w)")
    p.add_argument("--t-end", default=None, help="ISO time of T_end (default: the latest t_known in the sources)")
    p.add_argument("--store", default=None, help="path to pacer.sqlite (default: the app's group container)")
    p.set_defaults(func=run, handler=run)
    return p


def run(args) -> int:
    from datetime import datetime, timezone
    from pathlib import Path

    from export import pipeline, sources

    paths = sources.SourcePaths.default(Path(args.store) if args.store else None)
    sid = args.snapshot_id or f"working-{datetime.now(timezone.utc).strftime('%Y-%m-%d')}"
    res = pipeline.run_export(sid, freeze=args.freeze, t_train=args.t_train, tiers=args.tiers,
                              t_end=args.t_end, paths=paths)
    summary = {"ok": res.ok, "snapshot": str(res.snapshot) if res.snapshot else None,
               "gates": {g["gate"]: g["passed"] for g in res.report["gates"]}}
    if res.manifest:
        summary["rows"] = {n: v["rows_total"] for n, v in res.manifest["tables"].items()}
        summary["T_train"] = res.manifest.get("T_train_iso")
        summary["T_end"] = res.manifest.get("T_end_iso")
        summary["wall_time_s"] = res.manifest.get("wall_time_s")
    print(json.dumps(summary, indent=1))
    return 0 if res.ok else 1


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="arena")
    sub = parser.add_subparsers(dest="command", required=True)
    register(sub)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
