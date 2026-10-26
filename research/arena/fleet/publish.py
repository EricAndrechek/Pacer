"""Fold a collected generation into the tracked repo: its models into
`models/`, their attribution into `models/PROVENANCE.toml`, and the
generation's record into `fleet/generations/gen<N>/agents.toml`
(`arena provenance import gen<N>`).

Everything is read from the launcher's own records under the fleet root
(`fleet.json`, `collect.json`, each agent's stream log and arena-eval call
log), never from an agent's files. What gets copied is the collected export
(`gen<N>/collected/<agent>/models/<model>/`) minus scratch an agent left
behind: `dev/` and `tools/` folders, `tools_bench.sh`, `.git-add-marker`,
caches. No model imports any of those; `scratch_imports` checks.

The run's cost is Claude Code's own API-equivalent figure for the agent's
session (fine to publish: it is what the agent cost, not anyone's usage).
"""
from __future__ import annotations

import json
import re
import shutil
from pathlib import Path

from arena import provenance
from fleet.launch import read_stream
from fleet.paths import FleetPaths

SKIP_DIRS = {"dev", "tools", "__pycache__", ".ipynb_checkpoints", ".pytest_cache", ".venv", ".git"}
SKIP_NAMES = {".git-add-marker", "tools_bench.sh", ".DS_Store"}
SKIP_SUFFIXES = {".pyc", ".pyo"}
_SCRATCH_IMPORT = re.compile(r"^\s*(?:from|import)\s+(?:dev|tools)\b|['\"](?:dev|tools)/", re.M)


def kept_files(model_dir: Path) -> list[Path]:
    out = []
    for p in sorted(Path(model_dir).rglob("*")):
        rel = p.relative_to(model_dir)
        if any(part in SKIP_DIRS for part in rel.parts[:-1]) or (p.is_dir() and p.name in SKIP_DIRS):
            continue
        if p.is_file() and p.name not in SKIP_NAMES and p.suffix not in SKIP_SUFFIXES \
                and not any(part in SKIP_DIRS for part in rel.parts):
            out.append(p)
    return out


def scratch_imports(model_dir: Path) -> list[str]:
    """Kept .py files that import from (or name a path in) a dropped scratch
    folder: those would break once copied."""
    hits = []
    for p in kept_files(model_dir):
        if p.suffix == ".py" and _SCRATCH_IMPORT.search(p.read_text(errors="replace")):
            hits.append(str(p.relative_to(model_dir)))
    return hits


def copy_model(src: Path, dest: Path) -> list[str]:
    """Copy one collected model folder; returns the relative paths left out."""
    src, dest = Path(src), Path(dest)
    if dest.exists():
        raise FileExistsError(f"{dest} exists: models are never overwritten")
    kept = set(kept_files(src))
    dropped = []
    for p in sorted(src.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(src)
        if p not in kept:
            dropped.append(rel.as_posix())
            continue
        o = dest / rel
        o.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(p, o)
        o.chmod(0o644)
    return dropped


def default_kind(name: str) -> str:
    """The kind of a model the coordinator wrote (not an agent's)."""
    if name == "example-linear":
        return "example"
    if name.startswith("selftest-"):
        return "selftest"
    return "port"


def _calls(paths: FleetPaths, gen: int, name: str) -> tuple[int, int]:
    f = paths.agent_state(gen, name) / "calls.jsonl"
    calls = scored = 0
    if f.is_file():
        for line in f.read_text().splitlines():
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            calls += ev.get("event") == "call"
            scored += ev.get("event") == "result"
    return calls, scored


def _exit(stream: dict, rec: dict) -> str:
    res = stream.get("result") or rec.get("result") or {}
    cap = res.get("capped_by")
    if cap:
        return f"{cap} cap"
    if res.get("subtype") == "success":
        return "finished"
    return f"failed ({res.get('subtype') or rec.get('exit_code')})"


def generation_records(paths: FleetPaths, gen: int, summaries: dict[str, str] | None = None,
                       ) -> tuple[list[dict], dict[str, dict]]:
    """(agents, model records) for one collected generation: what
    agents.toml and PROVENANCE.toml hold."""
    fleet = json.loads(paths.fleet_json(gen).read_text())
    collect = {r["name"]: r for r in json.loads((paths.gen_dir(gen) / "collect.json").read_text())}
    agents, models = [], {}
    for name, rec in fleet["agents"].items():
        stream = read_stream(Path(rec["run_log"])) if rec.get("run_log") else {}
        res = stream.get("result") or {}
        calls, scored = _calls(paths, gen, name)
        col = collect.get(name, {})
        produced = [m["name"] for m in col.get("new_models", [])]
        agents.append({
            "name": name, "claude_model": rec.get("model"), "effort": rec.get("effort"),
            "niche": rec.get("niche"), "turns": res.get("num_turns"),
            "cost_usd": round(float(res["total_cost_usd"]), 2) if res.get("total_cost_usd") is not None else None,
            "eval_calls": calls, "eval_scored": scored, "exit": _exit(stream, rec),
            "max_turns": rec.get("max_turns"), "budget_usd": rec.get("budget_usd"),
            "eval_budget": rec.get("eval_budget"), "models": produced,
            "summary": (summaries or {}).get(name, ""),
        })
        for m in col.get("new_models", []):
            models[m["name"]] = {"kind": "agent", "generation": gen, "agent": name,
                                 "claude_model": rec.get("model"), "effort": rec.get("effort"),
                                 "niche": rec.get("niche"), "copied_from": list(m.get("copied_from") or [])}
    return agents, models


def _tv(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, list):
        return "[" + ", ".join(_tv(x) for x in v) + "]"
    return json.dumps(str(v), ensure_ascii=False)        # a TOML basic string


AGENTS_HEADER = """\
# Generation {gen}: one [[agent]] per agent, from the launcher's records.
# turns: assistant turns counted from the run's stream. cost_usd: Claude Code's
# API-equivalent cost of the agent's own session. eval_calls: arena-eval calls
# made (eval_scored: those that returned scores). exit: finished, or the cap
# (turns / budget) that stopped it. models: what it handed back (models/<name>).
"""


def agents_toml(gen: int, agents: list[dict]) -> str:
    lines = [AGENTS_HEADER.format(gen=gen)]
    for a in agents:
        lines.append("[[agent]]")
        for k, v in a.items():
            if v is None:
                continue
            lines.append(f"{k} = {_tv(v)}")
        lines.append("")
    return "\n".join(lines)


PROVENANCE_HEADER = """\
# Who wrote each model in this folder (read by arena/provenance.py; the results
# database takes its attribution columns from here). kind: port (written by the
# coordinator's builders: ports of the app's engine, baselines, learned and
# pretrained models, combiners), example, selftest (harness self-test
# controls), or agent (a fleet agent's hand-back, with its generation, agent,
# Claude model, effort, niche and the earlier models it copied or adapted).
# `arena provenance check` verifies every folder is listed.
"""


def write_provenance(models_dir: Path, records: dict[str, dict]) -> Path:
    f = Path(models_dir) / provenance.FILE
    f.write_text(provenance.dumps(records, header=PROVENANCE_HEADER))
    return f


def import_generation(paths: FleetPaths, gen: int, arena_root: Path, *, summaries: dict[str, str] | None = None,
                      copy: bool = True, log=print) -> dict:
    """Copy a collected generation's models into `<arena_root>/models`,
    add them to PROVENANCE.toml and write `fleet/generations/gen<N>/agents.toml`.
    Models already present are left alone (a model folder is immutable)."""
    arena_root = Path(arena_root)
    models_dir = arena_root / "models"
    agents, recs = generation_records(paths, gen, summaries)
    copied, kept, dropped = [], [], {}
    if copy:
        for a in agents:
            for m in a["models"]:
                src = paths.gen_dir(gen) / "collected" / a["name"] / "models" / m
                if (models_dir / m).exists():
                    kept.append(m)
                    continue
                bad = scratch_imports(src)
                if bad:
                    raise RuntimeError(f"{m}: imports dropped scratch files: {bad}")
                d = copy_model(src, models_dir / m)
                if d:
                    dropped[m] = d
                copied.append(m)
    merged = provenance.load(models_dir)
    for d in sorted(models_dir.iterdir()):
        if (d / "model.toml").is_file() and d.name not in merged and d.name not in recs:
            merged[d.name] = {"kind": default_kind(d.name)}
    merged.update(recs)
    write_provenance(models_dir, merged)
    gdir = arena_root / "fleet" / "generations" / f"gen{gen}"
    gdir.mkdir(parents=True, exist_ok=True)
    (gdir / "agents.toml").write_text(agents_toml(gen, agents))
    log(f"gen{gen}: {len(agents)} agents, {len(recs)} models ({len(copied)} copied, {len(kept)} already present)")
    return {"agents": agents, "copied": copied, "present": kept, "dropped": dropped}


def check(arena_root: Path) -> list[str]:
    """Problems with the tracked provenance: model folders not listed,
    listed models with no folder, agent records missing their attribution."""
    models_dir = Path(arena_root) / "models"
    recs = provenance.load(models_dir)
    folders = {d.name for d in models_dir.iterdir() if (d / "model.toml").is_file()}
    out = [f"{n}: not in {provenance.FILE}" for n in sorted(folders - set(recs))]
    out += [f"{n}: listed but there is no models/{n}" for n in sorted(set(recs) - folders)]
    for n, r in sorted(recs.items()):
        if r["kind"] == "agent":
            miss = [k for k in ("generation", "agent", "claude_model", "effort", "niche") if r.get(k) is None]
            if miss:
                out.append(f"{n}: agent model without {', '.join(miss)}")
            out += [f"{n}: copied_from {c} is not a model here" for c in r["copied_from"] if c not in folders]
    gens = provenance.generations(arena_root)
    listed = {m for g in gens for a in provenance.agents(g, arena_root) for m in a["models"]}
    agent_models = {n for n, r in recs.items() if r["kind"] == "agent"}
    out += [f"{n}: an agent model no generation's agents.toml lists" for n in sorted(agent_models - listed)]
    return out
