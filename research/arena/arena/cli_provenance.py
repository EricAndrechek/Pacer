"""`arena provenance …`: the tracked attribution of every model.

    arena provenance check                      every models/ folder listed, every agent model attributed
    arena provenance show [--gen N]             the agents of each generation (or one)
    arena provenance import gen<N> [--summaries F.json] [--no-copy]
                                                fold a collected generation (fleet root) into the repo:
                                                models/<name>/, models/PROVENANCE.toml and
                                                fleet/generations/gen<N>/agents.toml
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from arena import provenance


def register(subparsers) -> argparse.ArgumentParser:
    p = subparsers.add_parser("provenance", help="who wrote each model; fold a collected generation into the repo")
    sub = p.add_subparsers(dest="prov_cmd", required=True)
    c = sub.add_parser("check", help="every model folder listed in models/PROVENANCE.toml, every agent model attributed")
    c.set_defaults(func=cmd_check)
    s = sub.add_parser("show", help="the agents of each generation")
    s.add_argument("--gen", type=int)
    s.set_defaults(func=cmd_show)
    i = sub.add_parser("import", help="copy a collected generation's models in and record their attribution")
    i.add_argument("gen", help="gen<N> or N")
    i.add_argument("--summaries", help="JSON {agent: one-sentence summary} for agents.toml")
    i.add_argument("--no-copy", action="store_true", help="only (re)write PROVENANCE.toml and agents.toml")
    i.set_defaults(func=cmd_import)
    return p


def cmd_check(a) -> int:
    from fleet.publish import check
    problems = check(provenance.ARENA_ROOT)
    for line in problems:
        print(line)
    n = len(provenance.load())
    print(f"{n} models listed; {len(problems)} problems")
    return 1 if problems else 0


def cmd_show(a) -> int:
    gens = [a.gen] if a.gen is not None else provenance.generations()
    for g in gens:
        print(f"generation {g}")
        for ag in provenance.agents(g):
            cost = f"${ag['cost_usd']:.2f}" if ag.get("cost_usd") is not None else "-"
            print(f"  {ag['name']:16s} {ag['claude_model'] or '-':20s} {ag['effort'] or '-':7s} "
                  f"{ag['niche'] or '-':18s} turns {ag['turns'] or '-':>4}  {cost:>7s}  "
                  f"evals {ag['eval_calls'] or 0:>2}  {ag['exit'] or '-':12s} {len(ag['models'])} models")
    return 0


def cmd_import(a) -> int:
    from fleet.paths import FleetPaths, parse_gen
    from fleet.publish import import_generation
    gen = parse_gen(a.gen)
    summaries = json.loads(Path(a.summaries).read_text()) if a.summaries else None
    try:
        out = import_generation(FleetPaths.default(), gen, provenance.ARENA_ROOT, summaries=summaries,
                                copy=not a.no_copy)
    except (FileNotFoundError, RuntimeError) as e:
        print(f"arena provenance import: {e}", file=sys.stderr)
        return 2
    for m, files in sorted(out["dropped"].items()):
        print(f"  {m}: left out {', '.join(files)}")
    print("next: check every new model (arena test models/<name> --episodes 2), write SUMMARIES.md, "
          "then `arena provenance check`")
    return 0
