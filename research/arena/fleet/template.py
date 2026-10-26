"""`arena template gen<N>`: the repo every agent of a generation clones.

A fresh `git init` with one commit and no Pacer history (a worktree would let
an agent browse every Pacer branch). It holds the harness, the kit, the
synthetic generator, the example and the chosen earlier models, aggregate
scores for those models, AGENTS.md, and the project files. It never holds
data: the visible tier is read in place, through the agent's own arena home.

Left out on purpose: `fleet/` and `docs/` (the sandbox recipe and its known
weak spots), `export/` (it knows where Pacer's store lives), the design notes,
and the two CLI modules that wrap those.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from arena.snapshot.schema import TABLES, Where
from arena.types import Target
from fleet import evalgate
from fleet.paths import FleetPaths

ARENA_SRC = Path(__file__).resolve().parents[1]
TEMPLATE_TEXT = Path(__file__).parent / "templates"
HARNESS_EXCLUDE = {"cli_fleet.py", "cli_export.py"}
COPY_DIRS = ("arena", "kit", "synth")
COPY_FILES = ("pyproject.toml", "uv.lock")
READ_ONLY_PARTS = ("arena", "kit", "synth", "pyproject.toml", "uv.lock", "AGENTS.md",
                   "MODELS.md", "SCORES.md", "TEMPLATE.json")
DATA_SUFFIXES = {".parquet", ".duckdb", ".arrow", ".feather", ".ipc", ".db", ".sqlite",
                 ".sqlite3", ".npy", ".npz", ".pkl", ".pickle", ".jsonl", ".csv", ".wal"}
FORBIDDEN_NAMES = {"holdout", "labels", "salt", "hidden", "manifest.json", "validation"}
MAX_TEMPLATE_FILE = 2 * 1024 * 1024
UUID_RE = re.compile(rb"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
SAFE_TIERS = ("visible", "leaderboard", "synthetic")
GITIGNORE = """\
.venv/
.uv-cache/
.cache/
.hf-cache/
.arena-home/
.tmp/
__pycache__/
*.pyc
*.parquet
*.duckdb
*.duckdb.wal
data/
results/
scratch/
"""
GIT_ENV = {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
           "GIT_AUTHOR_NAME": "arena coordinator", "GIT_AUTHOR_EMAIL": "coordinator@arena.invalid",
           "GIT_COMMITTER_NAME": "arena coordinator", "GIT_COMMITTER_EMAIL": "coordinator@arena.invalid"}


def git(*args: str, cwd: Path, check: bool = True, env: dict | None = None) -> subprocess.CompletedProcess:
    """git with no global or system config: the owner's config signs with
    his key and names him; neither belongs on fleet repos."""
    base = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    return subprocess.run(["git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                           "-c", "core.fsmonitor=false", *args], cwd=cwd, check=check,
                          capture_output=True, text=True, env={**base, **GIT_ENV, **(env or {})})


def model_hash(model_dir: Path) -> str:
    """The registry's content hash when core provides one, else the gate's."""
    try:
        from arena.registry import content_hash  # core's; the gate restates it
        return str(content_hash(model_dir))
    except ImportError:
        return evalgate.model_hash(model_dir)


def _harness_ignore(src_root: Path):
    def ignore(dirpath: str, names: list[str]) -> set[str]:
        out = {n for n in names if n == "__pycache__" or n.endswith(".pyc") or n == ".DS_Store"}
        if Path(dirpath) == src_root / "arena":
            out |= HARNESS_EXCLUDE & set(names)
        return out
    return ignore


def schema_summary() -> str:
    lines = []
    for t in TABLES.values():
        if t.where is not Where.DATA:
            continue
        cols = ", ".join(c for c, _ in t.columns[3:])
        lines.append(f"- **`{t.name}`** ({t.scope.value}), one row per {t.grain}: {cols}")
    return "\n".join(lines)


def read_t_train(paths: FleetPaths, snapshot_id: str) -> str:
    for p in (paths.visible_view(snapshot_id) / "manifest.json",
              paths.home / "snapshots" / snapshot_id / "manifest.json"):
        if p.is_file():
            t = json.loads(p.read_text()).get("T_train")
            if t is not None:
                from fleet.visible import to_millis
                return datetime.fromtimestamp(to_millis(t) / 1000, timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    return "T_train (see the manifest)"


def scores_summary(db: Path, run_id: str, hashes: dict[str, str], *,
                   allow_tiers: tuple[str, ...] = SAFE_TIERS) -> tuple[str, dict]:
    """Aggregate scores (whole-path metrics, mean over episodes) of the chosen
    models in one run. Never episodes, forecasts, data or truth. Lockbox and
    prospective runs are refused unless asked for: showing them to the next
    generation would turn the final arbiter into one more leaderboard."""
    import duckdb

    con = duckdb.connect(str(db), read_only=True)
    try:
        run = con.execute("SELECT tier, snapshot_id, seed FROM runs WHERE run_id = ?", [run_id]).fetchone()
        if run is None:
            raise ValueError(f"no run {run_id!r} in {db}")
        tier = run[0]
        if tier not in allow_tiers:
            raise ValueError(f"run {run_id} is on the {tier} tier; refusing to show it to agents")
        by_hash = {h: n for n, h in hashes.items()}
        rows = con.execute(
            """SELECT model_hash, target, metric, avg(value) AS mean, count(DISTINCT episode_id) AS episodes
               FROM scores WHERE run_id = ? AND lead_s IS NULL AND model_hash IN (SELECT unnest(?))
               GROUP BY ALL ORDER BY target, metric, model_hash""",
            [run_id, list(by_hash)]).fetchall()
    finally:
        con.close()
    data: dict = {"run_id": run_id, "tier": tier, "models": {}}
    for h, target, metric, mean, n in rows:
        m = data["models"].setdefault(by_hash[h], {"hash": h, "scores": {}})
        m["scores"].setdefault(target, {})[metric] = {"mean": round(float(mean), 4), "episodes": int(n)}
    lines = [f"# Scores of earlier models\n\nRun `{run_id}`, {tier} tier. Whole-path metrics, "
             "mean over episodes (lower is better for errors and CRPS).\n"]
    for name, m in sorted(data["models"].items()):
        lines.append(f"\n## {name} (`{m['hash'][:12]}`)\n\n| target | metric | mean | episodes |\n|---|---|---|---|")
        for target, metrics in sorted(m["scores"].items()):
            for metric, v in sorted(metrics.items()):
                lines.append(f"| {target} | {metric} | {v['mean']} | {v['episodes']} |")
    missing = sorted(set(hashes) - set(data["models"]))
    if missing:
        lines.append(f"\nNo scores in this run for: {', '.join(missing)}.")
    return "\n".join(lines) + "\n", data


def _fill(text: str, values: dict[str, str]) -> str:
    for k, v in values.items():
        text = text.replace("{{" + k + "}}", v)
    return text


def agents_md(gen: int, snapshot_id: str, t_train: str) -> str:
    targets = ", ".join(f"`{t.value}`" for t in Target)
    return _fill((TEMPLATE_TEXT / "AGENTS.md").read_text(), {
        "GEN": str(gen), "SNAPSHOT": snapshot_id, "T_TRAIN": t_train,
        "SCHEMA": schema_summary(), "TARGETS": targets,
    })


def scan_template(root: Path, *, salt: bytes | None = None) -> list[str]:
    """Problems that must stop a template from being used: data files,
    hidden-tier names, large files, anything shaped like an account id, the
    salt. Run on the finished tree, .git excluded."""
    problems = []
    salt_hex = salt.hex().encode() if salt else None
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for name in dirnames + filenames:
            if name in FORBIDDEN_NAMES:
                problems.append(f"forbidden name: {Path(dirpath, name).relative_to(root)}")
        for f in filenames:
            p = Path(dirpath, f)
            rel = p.relative_to(root)
            if p.is_symlink():
                problems.append(f"symlink: {rel}")
                continue
            if p.suffix.lower() in DATA_SUFFIXES:
                problems.append(f"data file: {rel}")
            size = p.stat().st_size
            if size > MAX_TEMPLATE_FILE:
                problems.append(f"large file ({size} bytes): {rel}")
                continue
            blob = p.read_bytes()
            if UUID_RE.search(blob):
                problems.append(f"looks like it holds an id (UUID): {rel}")
            if salt and (salt in blob or (salt_hex and salt_hex in blob)):
                problems.append(f"holds the salt: {rel}")
    return problems


def build_template(paths: FleetPaths, gen: int, snapshot_id: str, *, models: tuple[str, ...] = (),
                   from_results: str | None = None, allow_tiers: tuple[str, ...] = SAFE_TIERS,
                   src: Path = ARENA_SRC, force: bool = False, t_train: str | None = None) -> Path:
    dest = paths.template(gen)
    if dest.exists():
        if not force:
            raise FileExistsError(f"{dest} exists (use --force to rebuild)")
        shutil.rmtree(dest)
    dest.mkdir(parents=True)

    for d in COPY_DIRS:
        if (src / d).is_dir():
            shutil.copytree(src / d, dest / d, ignore=_harness_ignore(src))
    for f in COPY_FILES:
        shutil.copy2(src / f, dest / f)

    chosen = ("example-linear",) + tuple(m for m in models if m != "example-linear")
    hashes: dict[str, str] = {}
    # Earlier generations' models live outside the repo, collected per
    # generation (`arena fleet collect`); look there after the arena's own.
    roots = [src / "models"] + sorted(paths.root.glob("gen*/allmodels"))
    for name in chosen:
        found = next((r / name for r in roots if (r / name / "model.py").is_file()), None)
        if not evalgate.MODEL_NAME_RE.match(name) or found is None:
            raise ValueError(f"no model {name!r} under {', '.join(map(str, roots))}")
        shutil.copytree(found, dest / "models" / name, ignore=_harness_ignore(src))
        hashes[name] = model_hash(dest / "models" / name)

    t_train = t_train or read_t_train(paths, snapshot_id)
    (dest / "AGENTS.md").write_text(agents_md(gen, snapshot_id, t_train))
    lines = ["# Models in this template\n", "| name | hash | role |", "|---|---|---|"]
    for name, h in hashes.items():
        lines.append(f"| {name} | `{h[:16]}` | {'reference example' if name == 'example-linear' else 'earlier model'} |")
    (dest / "MODELS.md").write_text("\n".join(lines) + "\n")
    if from_results:
        # Several runs (comma-separated): one section each, so models scored on
        # identical episodes in different runs (same tier, seed and count) can
        # still be shown together.
        mds = [scores_summary(paths.home / "results" / "arena.duckdb", r.strip(), hashes,
                              allow_tiers=allow_tiers)[0]
               for r in from_results.split(",") if r.strip()]
        (dest / "SCORES.md").write_text("\n---\n\n".join(mds))
    (dest / ".gitignore").write_text(GITIGNORE)
    source_commit = git("rev-parse", "HEAD", cwd=src, check=False).stdout.strip() or None
    from fleet.image import harness_hash
    (dest / "TEMPLATE.json").write_text(json.dumps({
        "generation": gen,
        "snapshot": snapshot_id,
        "T_train": t_train,
        "models": hashes,
        "harness_hash": harness_hash(dest),
        "source_commit": source_commit,
        "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }, indent=2) + "\n")

    salt_file = paths.home / "salt"
    problems = scan_template(dest, salt=salt_file.read_bytes() if salt_file.is_file() else None)
    if problems:
        shutil.rmtree(dest)
        raise RuntimeError("template refused:\n  " + "\n  ".join(problems))

    git("init", "-q", "-b", "main", cwd=dest)
    git("add", "-A", cwd=dest)
    git("commit", "-q", "-m", f"arena template, generation {gen}", cwd=dest)
    return dest


def template_info(template: Path) -> dict:
    info = json.loads((template / "TEMPLATE.json").read_text())
    info["commit"] = git("rev-parse", "HEAD", cwd=template).stdout.strip()
    return info


def protect_clone(clone: Path, earlier_models: list[str]) -> None:
    """Read-only file modes for everything an agent must copy rather than
    modify. A signal and a guard against accidents, not a lock: the agent owns
    the files. `fleet collect` flags any change to them."""
    targets = [clone / p for p in READ_ONLY_PARTS] + [clone / "models" / m for m in earlier_models]
    for t in targets:
        if not t.exists():
            continue
        if t.is_file():
            t.chmod(0o444)
            continue
        for dirpath, _, filenames in os.walk(t):
            for f in filenames:
                Path(dirpath, f).chmod(0o444)
        for dirpath, _, _ in os.walk(t, topdown=False):
            Path(dirpath).chmod(0o555)


def sha256_file(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()
