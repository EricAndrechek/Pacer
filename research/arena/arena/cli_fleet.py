"""`arena template`, `arena fleet …` and `arena build`: the agent fleet.

Registered by core's `arena/cli.py` through `register(subparsers)`; also
runnable alone as `python -m arena.cli_fleet …`. Every handler is set as
`func` and returns an exit code. The `fleet` package is imported lazily so the
harness imports cleanly where it is absent (the scoring image, the template).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _paths():
    from fleet.paths import FleetPaths
    return FleetPaths.default()


def _gen(value: str) -> int:
    from fleet.paths import parse_gen
    return parse_gen(value)


def cmd_template(args) -> int:
    from fleet.template import SAFE_TIERS, build_template
    paths = _paths()
    models = tuple(m for m in (args.models or "").split(",") if m)
    tiers = SAFE_TIERS + tuple(args.allow_tier or ())
    dest = build_template(paths, _gen(args.gen), args.snapshot, models=models, from_results=args.from_results,
                          allow_tiers=tiers, force=args.force)
    print(f"template ready: {dest}")
    return 0


def cmd_install(args) -> int:
    from fleet.install import install_gate
    print(f"installed {install_gate(_paths(), backend=args.backend)}")
    return 0


def cmd_image(args) -> int:
    from fleet.image import build_image
    tag = build_image(_paths().template(_gen(args.gen)), force=args.force)
    print(tag)
    return 0


def cmd_visible(args) -> int:
    from fleet.visible import publish_visible_view
    print(publish_visible_view(_paths(), args.snapshot, force=args.force))
    return 0


def cmd_launch(args) -> int:
    from fleet.launch import launch
    from fleet.plan import load_plan
    paths = _paths()
    gen = _gen(args.gen)
    plan = load_plan(Path(args.plan))
    gd = paths.gen_dir(gen)
    gd.mkdir(parents=True, exist_ok=True)
    (gd / f"plan-{plan.sha256[:12]}.toml").write_text(Path(args.plan).read_text())
    return launch(paths, gen, plan, presync=not args.no_presync, dry_run=args.dry_run,
                  build=not args.no_image_build, poll_s=args.poll)


def cmd_collect(args) -> int:
    from fleet.collect import collect, format_table
    kwargs = {"run_review": not args.no_review, "register": not args.no_register}
    if args.reviewer_model:
        kwargs["reviewer_model"] = args.reviewer_model
    results = collect(_paths(), _gen(args.gen), **kwargs)
    print(format_table(results))
    return 0


def cmd_status(args) -> int:
    from fleet import template as tmpl
    from fleet.collect import tamper_checks
    paths = _paths()
    gen = _gen(args.gen)
    fleet = json.loads(paths.fleet_json(gen).read_text())
    base = fleet.get("template_commit")
    for name, rec in fleet.get("agents", {}).items():
        b = paths.agent_state(gen, name) / "budget.json"
        budget = json.loads(b.read_text()) if b.exists() else {}
        res = rec.get("result") or {}
        d = paths.agent_dir(gen, name)
        commits = "?"
        if (d / ".git").is_dir() and base:
            if tamper_checks(d, rec):
                commits = "TAMPERED"
            else:
                r = tmpl.git("rev-list", "--count", f"{base}..HEAD", cwd=d, check=False)
                commits = r.stdout.strip() if r.returncode == 0 else "?"
        print(f"{name:12} {rec.get('status', '?'):14} {rec.get('model', '?'):18} {rec.get('effort', '?'):6} "
              f"exit={rec.get('exit_code')} turns={res.get('num_turns')} cost={res.get('total_cost_usd')} "
              f"evals={budget.get('used', 0)}/{budget.get('budget', '?')} commits={commits}")
    return 0


def cmd_selftest(args) -> int:
    from fleet import selftest
    if args.evaluate_only:
        return selftest.evaluate()
    if args.prepare_only:
        ctx = selftest.prepare()
        p = ctx["prepared"]
        print("prepared; would run:\n  " + " ".join(p.argv[p.argv.index(next(a for a in p.argv if a.endswith("claude"))):]))
        return 0
    return selftest.run()


def cmd_build(args) -> int:
    from fleet.build import build_model_env
    from fleet.image import image_tag
    paths = _paths()
    image = args.image or image_tag(paths.template(_gen(args.gen)))
    build_model_env(paths, Path(args.model_dir), image)
    return 0


def register(subparsers) -> None:
    t = subparsers.add_parser("template", help="build a generation's template repo")
    t.add_argument("gen", help="gen<N>")
    t.add_argument("--snapshot", required=True)
    t.add_argument("--models", help="earlier models to include, comma-separated (example-linear always is)")
    t.add_argument("--from-results", metavar="RUN", help="aggregate scores of those models from this run")
    t.add_argument("--allow-tier", action="append", help="also allow scores from this tier (e.g. lockbox)")
    t.add_argument("--force", action="store_true", help="rebuild an existing template")
    t.set_defaults(func=cmd_template)

    f = subparsers.add_parser("fleet", help="the agent fleet")
    fs = f.add_subparsers(dest="fleet_cmd", required=True)
    p = fs.add_parser("launch", help="prepare and run a generation from a plan")
    p.add_argument("--gen", required=True)
    p.add_argument("--plan", required=True)
    p.add_argument("--dry-run", action="store_true", help="prepare everything, launch nothing")
    p.add_argument("--no-presync", action="store_true", help="don't pre-build each clone's .venv")
    p.add_argument("--no-image-build", action="store_true", help="don't build the scoring image")
    p.add_argument("--poll", type=float, default=10.0)
    p.set_defaults(func=cmd_launch)
    p = fs.add_parser("collect", help="fetch, register, review and scan a generation's work")
    p.add_argument("--gen", required=True)
    p.add_argument("--no-review", action="store_true")
    p.add_argument("--no-register", action="store_true")
    p.add_argument("--reviewer-model")
    p.set_defaults(func=cmd_collect)
    p = fs.add_parser("status", help="where each agent of a generation stands")
    p.add_argument("--gen", required=True)
    p.set_defaults(func=cmd_status)
    p = fs.add_parser("install", help="install the eval gate into the fleet root")
    p.add_argument("--backend", default="docker", choices=["docker", "selftest"])
    p.set_defaults(func=cmd_install)
    p = fs.add_parser("image", help="build the scoring image from a generation's template")
    p.add_argument("--gen", required=True)
    p.add_argument("--force", action="store_true")
    p.set_defaults(func=cmd_image)
    p = fs.add_parser("visible", help="publish a snapshot's train-only view for agents")
    p.add_argument("--snapshot", required=True)
    p.add_argument("--force", action="store_true")
    p.set_defaults(func=cmd_visible)
    p = fs.add_parser("selftest", help="one tiny Haiku agent on dummy data: verify the sandbox recipe")
    p.add_argument("--evaluate-only", action="store_true", help="re-read the last run's evidence")
    p.add_argument("--prepare-only", action="store_true", help="set everything up, launch nothing")
    p.set_defaults(func=cmd_selftest)

    b = subparsers.add_parser("build", help="build a model's environment (deps, weights)")
    b.add_argument("model_dir")
    g = b.add_mutually_exclusive_group(required=True)
    g.add_argument("--gen", help="use this generation's scoring image")
    g.add_argument("--image", help="use this image tag")
    b.set_defaults(func=cmd_build)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="arena")
    register(parser.add_subparsers(dest="cmd", required=True))
    args = parser.parse_args(argv)
    return int(args.func(args) or 0)


if __name__ == "__main__":
    sys.exit(main())
