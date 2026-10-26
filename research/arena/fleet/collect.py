"""`arena fleet collect --gen N`: bring a generation's work home.

For each agent in fleet.json: fetch its commits into a bare repo the
coordinator owns (never running git with the agent's repo as the working
tree, whose config the agent could have touched), classify what changed
(new models; REPORT.md and UPSTREAM.md; anything that modified the harness
or an earlier model, which breaks copy-don't-modify), export each new model,
validate and hash it, register it with the launcher's attribution in the
results database, copy the hand-back notes to the coordinator's inbox,
review each new model, and scan the run for attempts to reach denied places.
"""
from __future__ import annotations

import difflib
import io
import json
import shutil
import subprocess
import tarfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from fleet import evalgate, review, transcripts
from fleet import template as tmpl
from fleet.paths import FleetPaths, transcript_path
from fleet.sandbox import AgentSandbox, sensitive_paths

SCHEMA_SQL = Path(__file__).resolve().parents[1] / "arena" / "results_schema.sql"
HANDBACK = ("REPORT.md", "UPSTREAM.md")


@dataclass
class AgentResult:
    name: str
    model: str
    effort: str
    niche: str
    exit_code: int | None
    commits: int = 0
    new_models: list[dict] = field(default_factory=list)
    violations: list[str] = field(default_factory=list)
    other_files: list[str] = field(default_factory=list)
    transcript: dict = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)


def _git_bare(repo: Path, *args: str, check: bool = True, binary: bool = False):
    import os
    base = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    return subprocess.run(["git", "--git-dir", str(repo), "-c", "core.hooksPath=/dev/null",
                           "-c", "protocol.file.allow=always", *args],
                          capture_output=True, check=check, text=not binary,
                          env={**base, **tmpl.GIT_ENV})


def ensure_collect_repo(paths: FleetPaths, gen: int) -> Path:
    repo = paths.collect_repo(gen)
    if not repo.exists():
        tmpl.git("clone", "-q", "--bare", str(paths.template(gen)), str(repo), cwd=paths.gen_dir(gen))
    return repo


def tamper_checks(agent_dir: Path, rec: dict) -> list[str]:
    """The sandbox refuses writes to .git/config and .git/hooks; check anyway
    before letting git near the repo."""
    problems = []
    cfg = agent_dir / ".git" / "config"
    if rec.get("git_config_sha256") and cfg.is_file() and tmpl.sha256_file(cfg) != rec["git_config_sha256"]:
        problems.append(".git/config changed since launch")
    hooks = agent_dir / ".git" / "hooks"
    if hooks.is_dir():
        live = [h.name for h in hooks.iterdir() if not h.name.endswith(".sample")]
        if live:
            problems.append(f".git/hooks holds {live}")
    return problems


def classify(paths_changed: list[tuple[str, str]], template_models: set[str]) -> dict:
    out = {"new_models": set(), "handback": set(), "violations": [], "other": []}
    for status, path in paths_changed:
        parts = path.split("/")
        if parts[0] == "models" and len(parts) >= 3:
            if parts[1] in template_models:
                out["violations"].append(f"{status} {path} (an earlier model: copy, don't modify)")
            elif status != "D":
                out["new_models"].add(parts[1])
        elif path in HANDBACK:
            out["handback"].add(path)
        elif parts[0] in ("arena", "kit", "synth") or path in ("pyproject.toml", "uv.lock", "AGENTS.md",
                                                               "MODELS.md", "SCORES.md", "TEMPLATE.json"):
            out["violations"].append(f"{status} {path} (the harness: read-only)")
        else:
            out["other"].append(f"{status} {path}")
    return out


def export_model(repo: Path, ref: str, model: str, dest: Path) -> None:
    """`git archive` of models/<model>, extracted with tarfile's data filter
    (no absolute paths, no links out, no special files) into `dest`."""
    blob = _git_bare(repo, "archive", "--format=tar", ref, f"models/{model}", binary=True).stdout
    tmp = dest.parent / f".{model}.export"
    for d in (tmp, dest):
        if d.exists():
            shutil.rmtree(d)
    tmp.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(blob)) as tf:
        tf.extractall(tmp, filter="data")
    (tmp / "models" / model).rename(dest)
    shutil.rmtree(tmp)


def similar_models(model_dir: Path, candidates: dict[str, Path], threshold: float = 0.6) -> list[str]:
    """Names of earlier models this one looks copied from (model.py similarity)."""
    try:
        mine = (model_dir / "model.py").read_text(errors="replace").splitlines()
    except FileNotFoundError:
        return []
    out = []
    for name, d in candidates.items():
        try:
            theirs = (d / "model.py").read_text(errors="replace").splitlines()
        except FileNotFoundError:
            continue
        if difflib.SequenceMatcher(None, mine, theirs, autojunk=False).ratio() >= threshold:
            out.append(name)
    return out


def register_model(db: Path, row: dict) -> bool:
    import duckdb

    db.parent.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(str(db))
    try:
        con.execute(SCHEMA_SQL.read_text())
        exists = con.execute("SELECT 1 FROM models WHERE model_hash = ?", [row["model_hash"]]).fetchone()
        if exists:
            return False
        con.execute(
            """INSERT INTO models (model_hash, name, path, children, generation, niche, author_kind,
                   agent_session, claude_model, claude_effort, copied_from, registered_at)
               VALUES (?, ?, ?, ?, ?, ?, 'agent', ?, ?, ?, ?, ?)""",
            [row["model_hash"], row["name"], row["path"], row["children"], row["generation"], row["niche"],
             row["agent_session"], row["claude_model"], row["claude_effort"], row["copied_from"],
             datetime.now(timezone.utc)])
        return True
    finally:
        con.close()


def collect(paths: FleetPaths, gen: int, *, run_review: bool = True, claude: str | None = None,
            reviewer_model: str = review.REVIEWER_MODEL, register: bool = True, log=print) -> list[AgentResult]:
    fleet = json.loads(paths.fleet_json(gen).read_text())
    template = paths.template(gen)
    info = tmpl.template_info(template)
    base = fleet.get("template_commit") or info["commit"]
    template_models = {n: template / "models" / n for n in info["models"]}
    repo = ensure_collect_repo(paths, gen)
    claude = claude or shutil.which("claude")
    db = paths.home / "results" / "arena.duckdb"
    results: list[AgentResult] = []
    agents = fleet.get("agents", {})
    for name, rec in agents.items():
        res = AgentResult(name, rec.get("model", "?"), rec.get("effort", "?"), rec.get("niche", "?"),
                          rec.get("exit_code"))
        results.append(res)
        agent_dir = Path(rec.get("cwd") or paths.agent_dir(gen, name))
        # 1. transcript scan, whatever else happens
        sb = AgentSandbox(paths=paths, gen=gen, name=name, snapshot_id=fleet["snapshot"],
                          other_agents=tuple(agents))
        allowed = sb.allow_read() + [paths.eval_wrapper(gen, name)]
        sources = [Path(rec["run_log"])] if rec.get("run_log") else []
        if rec.get("session_id"):
            sources.append(transcript_path(agent_dir, rec["session_id"]))
        found = transcripts.scan(sources, wrapper=paths.eval_wrapper(gen, name), allowed_roots=allowed,
                                 sensitive=[s.path for s in sensitive_paths(paths)],
                                 other_agents=[paths.agent_dir(gen, o) for o in agents if o != name])
        res.transcript = transcripts.summarize(found)
        out_dir = paths.agent_reviews(gen, name)
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / "transcript.json").write_text(json.dumps(res.transcript, indent=2) + "\n")
        calls = paths.agent_state(gen, name) / "calls.jsonl"
        if calls.is_file():
            res.notes.append(f"{sum(1 for l in calls.read_text().splitlines() if '\"event\": \"result\"' in l)} arena-eval results")

        # 2. fetch, unless the repo was tampered with
        if not (agent_dir / ".git").is_dir():
            res.notes.append("no repo")
            continue
        problems = tamper_checks(agent_dir, rec)
        if problems:
            res.violations += problems
            res.notes.append("not fetched: repo tampered")
            continue
        ref = f"refs/agents/{name}"
        r = _git_bare(repo, "fetch", "--no-tags", "-q", str(agent_dir), f"+HEAD:{ref}", check=False)
        if r.returncode != 0:
            res.notes.append(f"fetch failed: {r.stderr.strip()[:200]}")
            continue
        res.commits = int(_git_bare(repo, "rev-list", "--count", f"{base}..{ref}").stdout.strip() or 0)
        diff = _git_bare(repo, "diff", "--name-status", "--no-renames", base, ref).stdout
        changed = [tuple(l.split("\t", 1)) for l in diff.splitlines() if "\t" in l]
        cls = classify(changed, set(template_models))
        res.violations += cls["violations"]
        res.other_files = cls["other"]

        # 3. hand-back notes to the inbox
        inbox = paths.agent_inbox(gen, name)
        inbox.mkdir(parents=True, exist_ok=True)
        for f in HANDBACK:
            show = _git_bare(repo, "show", f"{ref}:{f}", check=False)
            if show.returncode == 0:
                (inbox / f).write_text(show.stdout)

        # 4. new models
        collected = paths.collected(gen, name) / "models"
        collected.mkdir(parents=True, exist_ok=True)
        exported = []
        for model in sorted(cls["new_models"]):
            if evalgate.MODEL_NAME_RE.match(model):
                export_model(repo, ref, model, collected / model)
                exported.append(model)
        for model in sorted(cls["new_models"]):
            entry: dict = {"name": model}
            res.new_models.append(entry)
            if model not in exported:
                entry["error"] = "bad folder name"
                continue
            dest = collected / model
            try:
                files = evalgate.model_files(dest)
                spec = evalgate.model_spec(dest)
            except evalgate.Refused as e:
                entry["error"] = str(e)
                continue
            entry["hash"] = tmpl.model_hash(dest)
            pool = {**template_models, **{m: collected / m for m in exported if m != model}}
            entry["copied_from"] = similar_models(dest, template_models)
            entry["children"] = spec["children"]
            child_hashes = []
            for c in spec["children"]:
                if c in pool and (pool[c] / "model.py").is_file():
                    child_hashes.append(tmpl.model_hash(pool[c]))
                else:
                    entry.setdefault("warnings", []).append(f"child {c} not found")
            model_diff = _git_bare(repo, "diff", base, ref, "--", f"models/{model}").stdout
            static = review.static_scan(dest)
            entry["static"] = {"high": sum(f.severity == "high" for f in static),
                               "medium": sum(f.severity == "medium" for f in static)}
            verdict = None
            if run_review and claude:
                verdict = review.llm_review(dest, model_diff, static, out_dir / f"review-{model}",
                                            claude=claude, model=reviewer_model)
                entry["review"] = verdict.get("verdict")
            (out_dir / f"{model}.json").write_text(json.dumps({
                "model": model, "hash": entry["hash"], "files": [str(f) for f in files],
                "static": [vars(f) for f in static], "review": verdict}, indent=2) + "\n")
            if register:
                entry["registered"] = register_model(db, {
                    "model_hash": entry["hash"], "name": model,
                    "path": f"arena-fleet/{dest.relative_to(paths.root)}",
                    "children": child_hashes, "generation": gen, "niche": rec.get("niche"),
                    "agent_session": rec.get("session_id"), "claude_model": rec.get("model"),
                    "claude_effort": rec.get("effort"),
                    "copied_from": [tmpl.model_hash(template_models[m]) for m in entry["copied_from"]],
                })
    summary_path = paths.gen_dir(gen) / "collect.json"
    summary_path.write_text(json.dumps([vars(r) for r in results], indent=2, default=str) + "\n")
    return results


def format_table(results: list[AgentResult]) -> str:
    head = ("agent", "claude model", "effort", "niche", "exit", "commits", "new models", "review",
            "violations", "transcript")
    rows = [head]
    for r in results:
        reviews = ",".join(f"{m['name']}:{m.get('review') or m.get('error') or '-'}" for m in r.new_models) or "-"
        counts = r.transcript.get("counts", {})
        rows.append((r.name, r.model, r.effort, r.niche[:18], str(r.exit_code), str(r.commits),
                     str(len(r.new_models)), reviews[:40], str(len(r.violations)),
                     f"high {counts.get('high', 0)} / med {counts.get('medium', 0)}"))
    widths = [max(len(row[i]) for row in rows) for i in range(len(head))]
    lines = ["  ".join(c.ljust(w) for c, w in zip(row, widths)) for row in rows]
    lines.insert(1, "  ".join("-" * w for w in widths))
    return "\n".join(lines)
