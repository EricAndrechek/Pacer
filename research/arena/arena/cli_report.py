"""`arena report`: one self-contained HTML page (or a RESULTS.md) from the results database."""
from __future__ import annotations

import argparse
from pathlib import Path


def run(args: argparse.Namespace) -> int:
    from arena.snapshot import arena_home
    from report import data, render
    from fleet.paths import fleet_root

    home = arena_home()
    db = Path(args.db) if args.db else home / "results" / "arena.duckdb"
    runs = [r.strip() for r in args.runs.split(",") if r.strip()]
    gens = [int(g) for g in args.gens.split(",") if g.strip()] if args.gens else None
    out = Path(args.out).expanduser()
    fmt = args.format or ("md" if out.suffix.lower() == ".md" else "html")
    rep = data.build(db, runs, baseline=args.baseline, gens=gens,
                     fleet_root=Path(args.fleet_root) if args.fleet_root else fleet_root(), home=home)
    narrative = Path(args.narrative).read_text() if args.narrative else None
    selftest = render.load_selftest(Path(args.selftest)) if args.selftest else None
    if fmt == "md":
        from report import public
        page = public.render(rep, narrative=narrative, selftest=selftest, public=args.public)
    elif args.public:
        raise SystemExit("arena report --public: use --format md (the HTML report carries absolute values)")
    else:
        page = render.render(rep, narrative=narrative, selftest=selftest)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(page)
    print(f"wrote {out} ({len(page) // 1024} KiB)")
    return 0


def register(subparsers) -> None:
    p = subparsers.add_parser("report", help="one self-contained HTML report from the results database")
    p.add_argument("--runs", required=True, help="comma-separated run ids; each target is shown from the one "
                                                 "run that scored the most models on it")
    p.add_argument("--baseline", default="port-engine-rule", help="model the skill column is relative to")
    p.add_argument("--narrative", help="Markdown written by the coordinator: the summary (and a 'Caveats' section)")
    p.add_argument("--selftest", help="JSON list of {name, status: pass|fail|skip, detail}")
    p.add_argument("--gens", help="comma-separated fleet generations to include (default: all found)")
    p.add_argument("--fleet-root", help="default: $ARENA_FLEET_ROOT or ~/arena-fleet")
    p.add_argument("--db", help="results database (default: ARENA_HOME/results/arena.duckdb)")
    p.add_argument("--out", required=True, help="output path, e.g. ~/.local/share/pacer-arena/reports/x.html "
                                                "(or RESULTS.md with --format md)")
    p.add_argument("--format", choices=("html", "md"), help="default: md for a .md --out, else html")
    p.add_argument("--public", action="store_true",
                   help="relative-only markdown for the public repo: skill vs baseline in percent, coverage and "
                        "PIT flatness; no absolute CRPS/AE, token or dollar figures, no agent cost")
    p.set_defaults(func=run)
