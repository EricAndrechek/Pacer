"""`arena …` — the command line.

The core owns `test`, `eval` and `run`. The other builders' subcommands come
from `arena/cli_<area>.py` modules exposing `register(subparsers)`, imported
when present; each sets its handler with `set_defaults(func=...)`.

`eval` is the hidden-tier scorer the fleet runs inside Docker: paths come only
from its arguments and `ARENA_HOME`, it always uses subprocess workers, and
`--json` prints nothing but rounded per-target aggregates and failure counts —
never a per-episode number, a message, or anything from the data.
"""
from __future__ import annotations

import argparse
import importlib
import json
import os
import sys
from pathlib import Path

from arena.episodes import ALL_TARGETS
from arena.registry import Registry, RegistryError
from arena.runner import RunConfig, Runner, Timeouts, parse_command, summarize
from arena.snapshot.views import SnapshotData

EXTENSIONS = ("cli_export", "cli_synth", "cli_board", "cli_report", "cli_fleet", "cli_selftest",
              "cli_leakcheck", "cli_provenance", "cli_weights", "cli_runs")
DEFAULT_MODELS = Path(__file__).resolve().parent.parent / "models"


def _targets(s: str | None):
    if not s:
        return None
    out = tuple(t.strip() for t in s.split(",") if t.strip())
    known = {str(t) for t in ALL_TARGETS}
    bad = [t for t in out if t not in known]
    if bad:
        raise SystemExit(f"unknown targets {bad}; known: {sorted(known)}")
    return out


def _registry(model_dirs: list[Path], extra: list[str] | None) -> Registry:
    roots = [Path(p).resolve() for p in (extra or [])]
    roots += [d.resolve().parent for d in model_dirs]
    roots.append(DEFAULT_MODELS)
    seen, uniq = set(), []
    for r in roots:
        if r not in seen:
            seen.add(r)
            uniq.append(r)
    return Registry(uniq)


def _common(p: argparse.ArgumentParser) -> None:
    p.add_argument("--episodes", type=int, default=8)
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--targets", help="comma-separated; default: what the model declares")
    p.add_argument("--snapshot", help="snapshot id (default $ARENA_SNAPSHOT or the newest)")
    p.add_argument("--mode", choices=("current_code", "as_recorded"), default="current_code")
    p.add_argument("--checkpoints", type=int, default=24, help="checkpoint cap per episode")
    p.add_argument("--paths", type=int, default=200, help="paths requested per target")
    p.add_argument("--timeout-scale", type=float, default=1.0, help="multiply every call timeout")
    p.add_argument("--threads", type=int, default=None, help="BLAS/OMP/Polars threads per worker")
    p.add_argument("--models-root", action="append", help="extra folder of models (children)")
    p.add_argument("--no-cache", action="store_true", help="don't read or write the child cache")
    p.add_argument("--worker-cmd", default=None,
                   help="start every worker with this command (JSON list or shell string; placeholders "
                        "{id} {model_dir} {scratch}); default $ARENA_WORKER_CMD, else python -m arena.worker")
    p.add_argument("--worker-kill-cmd", default=None,
                   help="run when a worker is killed, e.g. 'docker kill {id}'; default $ARENA_WORKER_KILL_CMD")


def _config(a, *, tier: str, kind: str, in_process: bool, longrun: bool = False) -> RunConfig:
    t = Timeouts()
    k = a.timeout_scale
    worker_cmd = parse_command(a.worker_cmd)
    if worker_cmd or parse_command(os.environ.get("ARENA_WORKER_CMD")):
        in_process = False                     # a worker command means real worker processes
    return RunConfig(tier=tier, episodes=a.episodes, seed=a.seed, targets=_targets(a.targets), mode=a.mode,
                     in_process=in_process, checkpoint_cap=a.checkpoints, n_paths=a.paths, longrun=longrun,
                     timeouts=Timeouts(t.start * k, t.fit * k, t.update * k, t.forecast * k),
                     keep_logs=tier in ("visible", "synthetic"), cache=not a.no_cache, kind=kind,
                     threads=a.threads, archive=getattr(a, "archive", "none"),
                     requested_by=getattr(a, "requested_by", None), worker_cmd=worker_cmd,
                     worker_kill_cmd=parse_command(a.worker_kill_cmd))


def _results(a):
    if not getattr(a, "record", False):
        return None
    from arena.results import ResultsDB
    return ResultsDB(Path(a.results_db) if getattr(a, "results_db", None) else None)


# ---------------------------------------------------------------------------
# arena test
# ---------------------------------------------------------------------------

def cmd_test(a) -> int:
    model_dir = Path(a.model_dir)
    try:
        info = _registry([model_dir], a.models_root).load(model_dir)
    except RegistryError as e:
        print(f"arena test: {e}", file=sys.stderr)
        return 2
    data = SnapshotData.load(a.snapshot, a.tier)
    cfg = _config(a, tier=a.tier, kind="test", in_process=not a.subprocess, longrun=a.longrun)
    results = _results(a)
    runner = Runner(data, cfg, results=results)
    out = runner.run([info])
    if results is not None:
        results.close()
    if a.json:
        print(json.dumps({"run_id": out.run_id, "model": info.short, **summarize(out, sig=6)}, indent=1))
        return 0
    _print_test(out, info, data, runner)
    return 0


def _iso(ms: int) -> str:
    import datetime as dt
    return dt.datetime.fromtimestamp(ms / 1000, dt.timezone.utc).strftime("%Y-%m-%d %H:%M")


def _print_test(out, info, data, runner) -> None:
    import numpy as np
    print(f"model {info.short}  snapshot {data.snapshot_id}  tier {data.tier.name} "
          f"[{_iso(data.tier.start)} .. {_iso(data.tier.end)}]  run {out.run_id}")
    if out.fallback_scoring:
        print("note: arena.scoring is not installed; scores come from the core's fallback "
              "(ensemble CRPS, middle-path abs error)")
    by_ep: dict[int, list[dict]] = {}
    for s in out.scores:
        by_ep.setdefault(s["episode_id"], []).append(s)
    fails: dict[int, list[dict]] = {}
    for f in out.failures:
        fails.setdefault(f["episode_id"], []).append(f)
    logs: dict[int, list[str]] = {}
    for lg in out.logs:
        logs.setdefault(lg["episode_id"], []).append(lg["message"])
    for ep in out.episodes:
        print(f"\nepisode {ep.episode_id} [{ep.primary}] {'+'.join(ep.scope.accounts)} view={ep.scope.view} "
              f"history {_iso(ep.history_start)}  cutoff {_iso(ep.cutoff)}  horizon {_iso(ep.horizon_end)}  "
              f"checkpoints {len(ep.checkpoints)}")
        rows = by_ep.get(ep.episode_id, [])
        agg: dict[tuple[str, str], list[float]] = {}
        for s in rows:
            agg.setdefault((s["target_key"], s["metric"]), []).append(s["value"])
        for (key, metric), v in sorted(agg.items()):
            print(f"  {key:38s} {metric:16s} mean {np.mean(v):10.4g}  n={len(v)}")
        for f in fails.get(ep.episode_id, []):
            t = _iso(f["checkpoint_t"]) if f["checkpoint_t"] else "-"
            print(f"  FAILURE {f['kind']} at {t}: {f['message']}")
        for m in logs.get(ep.episode_id, [])[:50]:
            print(f"  log: {m}")
    s = summarize(out, sig=4)
    print("\nsummary (mean over every scored checkpoint)")
    for target, metrics in s["targets"].items():
        print(f"  {target:20s} " + "  ".join(f"{m}={v}" for m, v in metrics.items()))
    if s["failures"]:
        print("  failures: " + ", ".join(f"{k}={v}" for k, v in s["failures"].items()))
    if runner.cache.hits or runner.cache.misses:
        print(f"  child cache: {runner.cache.hits} hits, {runner.cache.misses} misses")


# ---------------------------------------------------------------------------
# arena eval
# ---------------------------------------------------------------------------

def cmd_eval(a) -> int:
    model_dir = Path(a.model_dir)
    try:
        info = _registry([model_dir], a.models_root).load(model_dir)
    except RegistryError:
        print(json.dumps({"error": "model failed to load"}))
        return 2
    data = SnapshotData.load(a.snapshot, a.tier, after=_after(a))
    cfg = _config(a, tier=a.tier, kind="eval", in_process=False)
    results = _results(a)
    out = Runner(data, cfg, results=results).run([info])
    if results is not None:
        results.close()
    s = summarize(out, sig=a.sig)
    report = {"model": info.hash[:12], "tier": a.tier, "seed": a.seed, **s}
    if a.json:
        print(json.dumps(report, sort_keys=True))
    else:
        for target, metrics in s["targets"].items():
            print(f"{target:20s} " + "  ".join(f"{m}={v}" for m, v in metrics.items()))
        print(f"episodes={s['episodes']} failures={s['failures']}")
    return 0


# ---------------------------------------------------------------------------
# arena run
# ---------------------------------------------------------------------------

def _all_models() -> list[str]:
    """Every model under the arena's models/ folder, minus the self-test
    controls (they probe the harness; they are not forecasters)."""
    return sorted(d.name for d in DEFAULT_MODELS.iterdir()
                  if (d / "model.toml").is_file() and (d / "model.py").is_file() and not d.name.startswith("selftest-"))


HIDDEN_TIERS = ("leaderboard", "lockbox", "prospective")


def _has_agent_model(info) -> bool:
    """Is this model, or any child, an agent's (models/PROVENANCE.toml)?"""
    from arena.results import _provenance_for
    rec = _provenance_for(Path(info.path), info.name)
    if rec is not None and rec["kind"] == "agent":
        return True
    return any(_has_agent_model(c) for c in info.children.values())


def _after(a):
    """`--after` as epoch ms (an ISO time, or a snapshot id: its T_end); the
    prospective tier needs it."""
    if a.tier != "prospective":
        if getattr(a, "after", None):
            raise SystemExit("--after applies to --tier prospective only")
        return None
    if not getattr(a, "after", None):
        raise SystemExit("--tier prospective needs --after <ISO time | snapshot id>: cutoffs fall only after it")
    from arena.snapshot.views import resolve_after
    try:
        return resolve_after(a.after)
    except (ValueError, FileNotFoundError) as e:
        raise SystemExit(f"--after: {e}")


def cmd_run(a) -> int:
    names = _all_models() if a.models == "all" else [m.strip() for m in a.models.split(",") if m.strip()]
    dirs = [Path(n) for n in names if (Path(n) / "model.toml").is_file()]
    reg = _registry(dirs, a.models_root)
    try:
        infos = [reg.load(n) for n in names]
    except RegistryError as e:
        print(f"arena run: {e}", file=sys.stderr)
        return 2
    workers = None
    if a.docker:
        if a.in_process or a.worker_cmd:
            print("arena run: --docker starts its own workers (no --in-process, no --worker-cmd)", file=sys.stderr)
            return 2
        from fleet.local import docker_workers
        workers = docker_workers(infos, cpus=a.docker_cpus, memory=a.docker_memory,
                                 log=lambda m: print(m, file=sys.stderr))
        infos = workers.models
    elif not a.worker_cmd and not os.environ.get("ARENA_WORKER_CMD"):
        # Host workers can read anything this user can: trusted models only.
        try:
            from fleet.local import under_fleet_root
        except ImportError:
            under_fleet_root = None
        agents = [i.name for i in infos if under_fleet_root and under_fleet_root(i)]
        if agents:
            print(f"arena run: {', '.join(agents)} come from the agent fleet; untrusted models run only "
                  f"with --docker", file=sys.stderr)
            return 2
        # Agent models imported into models/ are reviewed, but a host worker
        # could still open the snapshot's holdout from disk: on a hidden tier
        # they need Docker workers, exactly as under arena-eval.
        hidden = [i.name for i in infos if a.tier in HIDDEN_TIERS and _has_agent_model(i)]
        if hidden and not a.trust_agent_models:
            print(f"arena run: {', '.join(hidden)} are (or call) agent models; on the {a.tier} tier they run "
                  f"only with --docker (or --trust-agent-models)", file=sys.stderr)
            return 2
    try:
        data = SnapshotData.load(a.snapshot, a.tier, after=_after(a))
        if data.after is not None:
            print(f"prospective tier: cutoffs in ({_iso(data.tier.start)}, {_iso(data.tier.end)}] of "
                  f"{data.snapshot_id}", file=sys.stderr)
        a.record = True
        cfg = _config(a, tier=a.tier, kind="longrun" if a.longrun else "tournament",
                      in_process=a.in_process, longrun=a.longrun)
        cfg.jobs = max(1, int(a.jobs))
        if workers is not None:
            cfg.worker_cmds = workers.commands
            cfg.in_process = False
        results = _results(a)
        say = (lambda m: print(m, file=sys.stderr, flush=True)) if a.progress else None
        out = Runner(data, cfg, results=results, say=say).run(infos)
        results.close()
    finally:
        if workers is not None:
            workers.cleanup()
    print(f"run {out.run_id}: {len(out.episodes)} episodes, {len(infos)} models, "
          f"{len(out.scores)} scores, {len(out.failures)} failures, jobs {cfg.jobs}"
          f"{', docker workers' if workers else ''} -> {results.path}")
    for info in infos:
        sub = type(out)(out.run_id, out.episodes, [s for s in out.scores if s["model_hash"] == info.hash],
                        [f for f in out.failures if f["model_hash"] == info.hash],
                        fallback_scoring=out.fallback_scoring)
        s = summarize(sub, sig=4)
        secs = [t["seconds"] for t in out.timings if t["model_hash"] == info.hash]
        timing = f"  {sum(secs) / len(secs):.1f} s/episode over {len(secs)}" if secs else "  (no episode for it)"
        print(f"\n{info.short}{timing}")
        for target, metrics in s["targets"].items():
            print(f"  {target:20s} " + "  ".join(f"{m}={v}" for m, v in metrics.items()))
        if s["failures"]:
            print("  failures: " + ", ".join(f"{k}={v}" for k, v in s["failures"].items()))
    return 0


# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="arena", description="Pacer forecast arena")
    sub = p.add_subparsers(dest="cmd", required=True)

    t = sub.add_parser("test", help="run a model on the visible tier with full diagnostics")
    t.add_argument("model_dir")
    _common(t)
    t.add_argument("--tier", default="visible", choices=("visible", "synthetic"))
    t.add_argument("--subprocess", action="store_true", help="real worker processes (default: in-process)")
    t.add_argument("--longrun", action="store_true", help="one long episode per account over the tier")
    t.add_argument("--json", action="store_true")
    t.add_argument("--record", action="store_true", help="also write to the results database")
    t.add_argument("--results-db")
    t.set_defaults(func=cmd_test)

    e = sub.add_parser("eval", help="score a model on a hidden tier; rounded aggregates only")
    e.add_argument("model_dir")
    _common(e)
    e.add_argument("--tier", required=True, choices=("leaderboard", "lockbox", "synthetic", "prospective"))
    e.add_argument("--after", help="prospective tier: only cutoffs after this ISO time, or after a snapshot's T_end "
                                    "(give its id)")
    e.add_argument("--json", action="store_true")
    e.add_argument("--sig", type=int, default=3, help="significant digits reported")
    e.add_argument("--record", action="store_true", help="also write to the results database")
    e.add_argument("--results-db")
    e.set_defaults(func=cmd_eval)

    r = sub.add_parser("run", help="a tournament (or long run) into the results database")
    r.add_argument("--models", required=True, help="comma-separated model names or folders, or 'all' "
                                                   "(every model in models/ but the self-test controls)")
    _common(r)
    r.add_argument("--tier", required=True, choices=("visible", "leaderboard", "lockbox", "synthetic", "prospective"))
    r.add_argument("--after", help="prospective tier: only cutoffs after this ISO time, or after a snapshot's T_end "
                                    "(give its id): frozen models scored on data that did not exist when they were written")
    r.add_argument("--trust-agent-models", action="store_true",
                   help="allow agent models (models/PROVENANCE.toml) on a hidden tier with host workers")
    r.add_argument("--longrun", action="store_true", help="one long episode per account over the tier")
    r.add_argument("--in-process", action="store_true", help="debug: models in threads, not processes")
    r.add_argument("--archive", choices=("none", "quantiles", "paths"), default="quantiles")
    r.add_argument("--requested-by", default="coordinator")
    r.add_argument("--results-db")
    r.add_argument("--jobs", type=int, default=1,
                   help="(model, episode) units at once, each in its own job process; same results for any N")
    r.add_argument("--docker", action="store_true",
                   help="every worker in its own container (no network, no data mounted): required for "
                        "untrusted (agent) models; host workers are for trusted models only")
    r.add_argument("--docker-cpus", type=int, default=2, help="CPUs per worker container")
    r.add_argument("--docker-memory", default="4g", help="memory per worker container")
    r.add_argument("--progress", action="store_true", help="a line per finished unit on stderr")
    r.set_defaults(func=cmd_run)

    for mod in EXTENSIONS:
        try:
            m = importlib.import_module(f"arena.{mod}")
        except ModuleNotFoundError as err:
            if err.name == f"arena.{mod}":
                continue
            raise
        m.register(sub)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    func = getattr(args, "func", None)
    if func is None:
        print(f"arena {args.cmd}: no handler registered", file=sys.stderr)
        return 2
    return int(func(args) or 0)


if __name__ == "__main__":
    sys.exit(main())
