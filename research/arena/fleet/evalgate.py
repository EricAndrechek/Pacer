"""`arena-eval`: the one command an agent may run outside its sandbox.

Standard library only. `arena fleet install` copies this file, with a
shebang, to `<fleet root>/bin/arena-eval` (read-only), and writes one wrapper
per agent at `<fleet root>/bin/gen<N>/<agent>/arena-eval`:

    #!/bin/sh
    exec <fleet root>/bin/arena-eval --agent gen<N>/<agent> -- "$@"

Each agent's settings exempt only its own wrapper, by absolute path, so the
identity baked into the wrapper cannot be forged: calling another agent's
wrapper, or this script directly, runs inside the sandbox, which cannot read
the state or the snapshot, and fails.

What one call does:
1. **Validate the argument** (untrusted): one path to `models/<name>` inside
   the caller's own folder, a real directory holding model.py and model.toml,
   no symlinks or special files, within size limits. Children named in
   model.toml must sit beside it under the same rules. Nothing else is accepted
   (`--budget` prints the calls left and charges nothing).
2. **Charge the budget**, kept under `<root>/state/` where the agent cannot
   write. One call at a time per agent; a few at a time across the fleet.
3. **Stage** a copy of the model and its children outside the agent's reach,
   so nothing can change under the scorer and no link can lead out.
4. **Build or reuse the model's environment** (`arena build`): extra packages
   and pretrained weights, installed in a Linux container with the network
   on and no data mounted, keyed by the build spec under `<ARENA_HOME>/envs/`.
5. **Score**: `arena eval` runs on the HOST, from the generation's pinned
   harness (the template, which no agent can write) with the gate's own
   interpreter (`runner_python`), and is the only process that reads the
   snapshot. It starts every model worker, children included, through
   `ARENA_WORKER_CMD` (`worker_command`): one `docker run -i --rm` per worker,
   `--network none --cpus 2 --memory 4g --read-only --tmpfs /tmp`, the staged
   models and their env mounted read-only, and NO data mounted. The worker gets
   rows only as the runner's as-of batches over stdin, so a model cannot see
   the future even by opening files: inside its container there is nothing to
   open. Thread counts are pinned to the CPU cap; episodes are fresh and random.
6. **Return rounded per-target scores only.** Never the model's output, logs,
   errors or anything else from the runner or a container.

Docker is reached through an endpoint pinned at install (`docker_host`) with
an empty Docker config and a fixed PATH, never through the caller's
environment: the runner streams hidden-tier rows to `docker run -i`, and a
daemon the agent controlled would receive them.
"""
from __future__ import annotations

import contextlib
import errno
import fcntl
import hashlib
import json
import math
import os
import re
import secrets
import shutil
import stat
import subprocess
import sys
import time
import tomllib
from pathlib import Path

ARG_RE = re.compile(r"^[A-Za-z0-9._/-]{1,240}$")
AGENT_RE = re.compile(r"^gen(\d{1,3})/([a-z][a-z0-9-]{0,31})$")
MODEL_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
# PEP 508 names with optional extras and version specifiers. No URLs, paths,
# markers or pip options: an env build fetches from PyPI and nowhere else.
DEP_RE = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}(\[[A-Za-z0-9._,-]{1,100}\])?"
    r"(\s*(==|>=|<=|~=|!=|<|>)\s*[A-Za-z0-9.*+!-]{1,40}(\s*,\s*(==|>=|<=|~=|!=|<|>)\s*[A-Za-z0-9.*+!-]{1,40})*)?$"
)
WEIGHTS_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,95}(@[A-Za-z0-9._/-]{1,64})?$")
TARGET_KEY_RE = re.compile(r"^[a-z][a-z0-9_]*\.[a-z0-9_.:-]{1,62}$")   # e.g. meter.five_hour
METRIC_RE = re.compile(r"^[a-z][a-z0-9_]{0,31}$")
MAX_METRICS = 32          # per target: a dozen scores plus the ten PIT-histogram bins
# The same files core's registry hashes (arena/registry.py): caches, venvs and
# editor junk are not part of a model.
SKIP_DIRS = {"__pycache__", ".git", ".ipynb_checkpoints", ".pytest_cache", ".venv"}
SKIP_SUFFIXES = (".pyc", ".pyo")
SKIP_NAMES = {".DS_Store"}
CHILD_RE = re.compile(r"^([a-z0-9][a-z0-9._-]{0,63})(@[0-9a-f]{4,64})?$")   # name, or name@<hash prefix>
MAX_FILES = 400
MAX_FILE_BYTES = 20 * 1024 * 1024
MAX_MODEL_BYTES = 50 * 1024 * 1024
MAX_CHILD_DEPTH = 8
THREAD_VARS = ("OMP_NUM_THREADS", "MKL_NUM_THREADS", "OPENBLAS_NUM_THREADS",
               "NUMEXPR_NUM_THREADS", "NUMEXPR_MAX_THREADS", "POLARS_MAX_THREADS",
               "RAYON_NUM_THREADS", "VECLIB_MAXIMUM_THREADS", "TORCH_NUM_THREADS")

DEFAULTS = {
    "docker": "docker",
    "docker_host": None,       # pinned by `arena fleet install`
    "harness": None,           # per generation: the template the runner imports from
    "runner_python": None,     # per generation: install.build_runner_env
    "cpus": 2,
    "memory": "4g",
    "pids_limit": 512,
    "user": "65534:65534",
    "sig_digits": 3,
    "timeout_s": 3600,
    "build_timeout_s": 1800,
    "max_concurrent": 2,
    "backend": "docker",       # docker | selftest
    "tier": "leaderboard",
}


class Refused(Exception):
    """A bad request. Charged nothing; the message is safe to show."""


class Failed(Exception):
    """The call ran and failed. The message is safe to show. `refund` when
    the failure says nothing about the hidden data (a busy scorer, a package
    that would not install), so the call is given back."""

    def __init__(self, message: str, *, refund: bool = False):
        super().__init__(message)
        self.refund = refund


# --------------------------------------------------------------------------
# configuration


def load_config(script: Path) -> dict:
    cfg_path = script.parent / "arena-eval.json"
    cfg = dict(DEFAULTS)
    cfg.update(json.loads(cfg_path.read_text()))
    for key in ("fleet_root", "arena_home"):
        if not cfg.get(key):
            raise RuntimeError(f"{cfg_path}: missing {key}")
    return cfg


def gen_config(cfg: dict, gen: int) -> dict:
    p = Path(cfg["fleet_root"]) / "state" / f"gen{gen}" / "eval.json"
    try:
        g = json.loads(p.read_text())
    except FileNotFoundError:
        raise Refused(f"generation {gen} is not set up for arena-eval") from None
    out = {k: v for k, v in cfg.items()}
    out.update(g)
    return out


# --------------------------------------------------------------------------
# argument validation


def parse_args(argv: list[str]) -> tuple[int, str, list[str]]:
    """The wrapper calls `arena-eval --agent gen<N>/<name> -- <agent args>`."""
    if len(argv) < 3 or argv[0] != "--agent" or argv[2] != "--":
        raise Refused("arena-eval must be called through your own wrapper ($ARENA_EVAL)")
    m = AGENT_RE.match(argv[1])
    if not m:
        raise Refused("bad agent identity")
    return int(m.group(1)), m.group(2), argv[3:]


def _lstat_dir(p: Path) -> None:
    st = os.lstat(p)
    if not stat.S_ISDIR(st.st_mode):
        raise Refused(f"{p.name} is not a plain directory")


def resolve_model_dir(arg: str, agent_dir: Path, cwd: Path) -> Path:
    """The model directory the argument names, which must be
    `<agent_dir>/models/<name>` with no link anywhere on the way."""
    if not ARG_RE.match(arg) or arg.startswith("-"):
        raise Refused("give one path to models/<name>, using letters, digits, '.', '_', '-' and '/'")
    agent_real = Path(os.path.realpath(agent_dir))
    models = agent_real / "models"
    try:
        _lstat_dir(models)
    except FileNotFoundError:
        raise Refused("your folder has no models/ directory") from None
    candidate = Path(os.path.normpath(cwd / arg))
    real = Path(os.path.realpath(candidate))
    if real.parent != models or not MODEL_NAME_RE.match(real.name):
        raise Refused("the model must be a folder models/<name> inside your own folder")
    # realpath() followed any links; refuse if the spelled path differs from
    # the real one below the agent folder (a link was involved).
    try:
        spelled = Path(os.path.normpath(Path(os.path.realpath(cwd)) / arg))
    except OSError:
        raise Refused("cannot resolve that path") from None
    if spelled != real:
        raise Refused("links are not allowed in the model path")
    try:
        _lstat_dir(real)
    except FileNotFoundError:
        raise Refused(f"no such model: models/{real.name}") from None
    return real


def model_files(model_dir: Path) -> list[Path]:
    """Every file of a model, relative, sorted; refuses links, special files
    and anything over the size limits."""
    files: list[Path] = []
    total = 0
    for dirpath, dirnames, filenames in os.walk(model_dir, followlinks=False):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for d in dirnames:
            if not stat.S_ISDIR(os.lstat(Path(dirpath) / d).st_mode):
                raise Refused(f"links are not allowed inside a model: {d}")
        for f in sorted(filenames):
            if f in SKIP_NAMES or f.endswith(SKIP_SUFFIXES):
                continue
            p = Path(dirpath) / f
            st = os.lstat(p)
            if not stat.S_ISREG(st.st_mode):
                raise Refused(f"only regular files are allowed inside a model: {p.relative_to(model_dir)}")
            if st.st_size > MAX_FILE_BYTES:
                raise Refused(f"file too large ({st.st_size} bytes): {p.relative_to(model_dir)}")
            total += st.st_size
            files.append(p.relative_to(model_dir))
            if len(files) > MAX_FILES:
                raise Refused(f"a model may hold at most {MAX_FILES} files")
    if total > MAX_MODEL_BYTES:
        raise Refused(f"a model may hold at most {MAX_MODEL_BYTES // 2**20} MB")
    names = {str(f) for f in files}
    if "model.py" not in names or "model.toml" not in names:
        raise Refused("a model folder needs model.py and model.toml")
    return files


def _read_regular(path: Path, limit: int = MAX_FILE_BYTES) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise Refused(f"not a regular file: {path.name}")
        with os.fdopen(fd, "rb", closefd=False) as fh:
            data = fh.read(limit + 1)
    finally:
        os.close(fd)
    if len(data) > limit:
        raise Refused(f"file too large: {path.name}")
    return data


def folder_hash(model_dir: Path, files: list[Path] | None = None) -> str:
    """Core's `folder_hash` (arena/registry.py), restated in the standard
    library: sha256 over each file's relative posix path, a NUL, the length
    as 8 big-endian bytes and the bytes, in path order."""
    files = files if files is not None else model_files(model_dir)
    h = hashlib.sha256()
    for rel in sorted(files, key=lambda r: Path(r).as_posix()):
        data = _read_regular(model_dir / rel)
        h.update(Path(rel).as_posix().encode() + b"\0" + len(data).to_bytes(8, "big") + data)
    return h.hexdigest()


# Core's `_NOT_MODEL_CODE` (arena/registry.py): harness files that are not
# part of a model's identity.
NOT_MODEL_CODE = ("arena/scoring/", "arena/cli.py", "arena/cli_", "arena/results.py",
                  "arena/results_schema.sql", "arena/selftest.py", "arena/registry.py",
                  "arena/provenance.py", "arena/leakcheck.py")


def code_hash(harness: Path) -> str:
    """Core's `code_hash` over a harness root (the generation's template):
    kit/**, arena/** but NOT_MODEL_CODE, and uv.lock, hashed like a folder."""
    harness = Path(harness)
    rels: list[str] = []
    for part in ("arena", "kit"):
        base = harness / part
        if not base.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(base, followlinks=False):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for f in filenames:
                if f in SKIP_NAMES or f.endswith(SKIP_SUFFIXES):
                    continue
                rel = (Path(dirpath) / f).relative_to(harness).as_posix()
                if part == "arena" and rel.startswith(NOT_MODEL_CODE):
                    continue
                if (Path(dirpath) / f).is_file():
                    rels.append(rel)
    if (harness / "uv.lock").is_file():
        rels.append("uv.lock")
    h = hashlib.sha256()
    for rel in sorted(rels):
        data = (harness / rel).read_bytes()
        h.update(rel.encode() + b"\0" + len(data).to_bytes(8, "big") + data)
    return h.hexdigest()


def model_hash(model_dir: Path, files: list[Path] | None = None, harness: Path | None = None) -> str:
    """Core's content hash (arena/registry.py `content_hash`): the folder and
    the shared code the generation's harness runs it with. The gate, the
    collector and the results database must name a model the same way.
    Without a harness (the selftest backend) only the folder is hashed."""
    folder = folder_hash(model_dir, files)
    if harness is None:
        return folder
    h = hashlib.sha256(b"model\0")
    h.update(folder.encode() + b"\0code\0" + code_hash(harness).encode())
    return h.hexdigest()


def read_model_toml(model_dir: Path) -> dict:
    try:
        return tomllib.loads(_read_regular(model_dir / "model.toml", 64 * 1024).decode())
    except (tomllib.TOMLDecodeError, UnicodeDecodeError) as e:
        raise Refused(f"model.toml does not parse: {str(e)[:200]}") from None


def model_spec(model_dir: Path) -> dict:
    meta = read_model_toml(model_dir)
    children = meta.get("children", []) or []
    deps = meta.get("deps", []) or []
    weights = meta.get("weights", []) or []
    for name, val in (("children", children), ("deps", deps), ("weights", weights)):
        if not isinstance(val, list) or not all(isinstance(x, str) for x in val):
            raise Refused(f"model.toml: {name} must be a list of strings")
    for c in children:
        if not CHILD_RE.match(c):
            raise Refused(f"model.toml: bad child name {c!r}")
    children = [CHILD_RE.match(c).group(1) for c in children]
    for d in deps:
        if not DEP_RE.match(d.strip()):
            raise Refused(f"model.toml: deps entries must be plain PyPI requirements (name, extras, versions): {d!r}")
    for w in weights:
        if not WEIGHTS_RE.match(w):
            raise Refused(f"model.toml: weights entries must be Hugging Face repo ids, optionally @revision: {w!r}")
    return {"children": children, "deps": [d.strip() for d in deps], "weights": weights}


def resolve_tree(model_dir: Path) -> dict[str, dict]:
    """The model and every child it calls, transitively: name -> {dir, files,
    spec}. Children must sit beside the model under the same rules."""
    models_root = model_dir.parent
    out: dict[str, dict] = {}

    def visit(name: str, depth: int) -> None:
        if name in out:
            return
        if depth > MAX_CHILD_DEPTH:
            raise Refused(f"children nest deeper than {MAX_CHILD_DEPTH}")
        d = models_root / name
        try:
            _lstat_dir(d)
        except FileNotFoundError:
            raise Refused(f"child model not found beside it: models/{name}") from None
        files = model_files(d)
        spec = model_spec(d)
        out[name] = {"dir": d, "files": files, "spec": spec}
        for c in spec["children"]:
            visit(c, depth + 1)

    visit(model_dir.name, 0)
    return out


# --------------------------------------------------------------------------
# budget and concurrency


@contextlib.contextmanager
def locked(path: Path, *, blocking: bool = True):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        except OSError as e:
            if e.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
                yield False
                return
            raise
        yield True
    finally:
        os.close(fd)


def budget_path(state: Path) -> Path:
    return state / "budget.json"


def read_budget(state: Path) -> dict:
    try:
        b = json.loads(budget_path(state).read_text())
    except FileNotFoundError:
        raise Refused("no eval budget is set up for you") from None
    return {"budget": int(b["budget"]), "used": int(b.get("used", 0))}


def _write_json(path: Path, obj) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, indent=2) + "\n")
    os.replace(tmp, path)


def charge(state: Path) -> dict:
    with locked(state / "budget.lock"):
        b = read_budget(state)
        if b["used"] >= b["budget"]:
            raise Refused(f"your eval budget is spent ({b['used']} of {b['budget']} calls)")
        b["used"] += 1
        _write_json(budget_path(state), b)
        return b


def refund(state: Path) -> dict:
    with locked(state / "budget.lock"):
        b = read_budget(state)
        b["used"] = max(0, b["used"] - 1)
        _write_json(budget_path(state), b)
        return b


@contextlib.contextmanager
def fleet_slot(root: Path, n: int, timeout_s: float):
    """One of n fleet-wide scoring slots, so a burst of calls can't swamp the Mac."""
    deadline = time.monotonic() + timeout_s
    while True:
        for i in range(max(1, n)):
            with locked(root / "state" / "eval-slots" / f"{i}.lock", blocking=False) as ok:
                if ok:
                    yield i
                    return
        if time.monotonic() > deadline:
            raise Failed("the scorer is busy; try again later (not charged)", refund=True)
        time.sleep(2)


# --------------------------------------------------------------------------
# staging and environments


def stage(tree: dict[str, dict], dest: Path) -> Path:
    models = dest / "models"
    for name, info in tree.items():
        for rel in info["files"]:
            out = models / name / rel
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_bytes(_read_regular(info["dir"] / rel))
            out.chmod(0o444)
    for dirpath, _, _ in os.walk(models):
        Path(dirpath).chmod(0o555)
    return models


def env_spec(tree: dict[str, dict], image: str) -> dict:
    deps = sorted({d for info in tree.values() for d in info["spec"]["deps"]})
    weights = sorted({w for info in tree.values() for w in info["spec"]["weights"]})
    return {"image": image, "deps": deps, "weights": weights}


def env_key(spec: dict) -> str | None:
    """None when the model needs nothing beyond the image."""
    if not spec["deps"] and not spec["weights"]:
        return None
    return hashlib.sha256(json.dumps(spec, sort_keys=True).encode()).hexdigest()[:20]


def docker_env(cfg: dict) -> dict[str, str]:
    """The environment every docker CLI call gets: fixed, from the gate's own
    configuration, nothing from the caller's."""
    state = Path(cfg["fleet_root"]) / "state"
    conf = state / "docker-config"            # empty: no credential helpers, no plugins, no contexts
    conf.mkdir(parents=True, exist_ok=True)
    path = [str(Path(cfg["docker"]).parent)] if os.path.isabs(cfg["docker"]) else []
    env = {"PATH": os.pathsep.join(path + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]),
           "HOME": str(state), "LANG": "C.UTF-8", "DOCKER_CONFIG": str(conf)}
    if cfg.get("docker_host"):
        env["DOCKER_HOST"] = str(cfg["docker_host"])
    return env


BUILD_PY = r"""
import json, os, subprocess, sys
spec = json.loads(sys.argv[1])
subprocess.run(["uv", "venv", "--system-site-packages", "--python", "/usr/local/bin/python3", "/env"], check=True)
pkgs = list(spec["deps"]) + (["huggingface_hub"] if spec["weights"] else [])
if pkgs:
    subprocess.run(["uv", "pip", "install", "--python", "/env/bin/python", *pkgs], check=True)
if spec["weights"]:
    code = (
        "import sys\n"
        "from huggingface_hub import snapshot_download\n"
        "for w in sys.argv[1:]:\n"
        "    repo, _, rev = w.partition('@')\n"
        "    snapshot_download(repo_id=repo, revision=rev or None)\n"
    )
    subprocess.run(["/env/bin/python", "-c", code, *spec["weights"]], check=True, env={**os.environ, "HF_HOME": "/env/hf"})
"""


def build_command(cfg: dict, spec: dict, env_tmp: Path, name: str) -> list[str]:
    """`arena build`: network on, no data mounted, writes only the env."""
    cache = Path(cfg["fleet_root"]) / "cache" / "uv-linux"
    return [
        cfg["docker"], "run", "--rm", "--pull", "never", "--name", name,
        "--cpus", "4", "--memory", "8g", "--pids-limit", "1024",
        "--user", "0:0",
        "-v", f"{env_tmp}:/env",
        "-v", f"{cache}:/uv-cache",
        "-e", "UV_CACHE_DIR=/uv-cache", "-e", "UV_LINK_MODE=copy",
        "-e", "HF_HOME=/env/hf", "-e", "HOME=/tmp",
        spec["image"], "python3", "-c", BUILD_PY, json.dumps(spec),
    ]


def ensure_env(cfg: dict, spec: dict, log) -> Path | None:
    key = env_key(spec)
    if key is None:
        return None
    envs = Path(cfg["arena_home"]) / "envs"
    final = envs / key
    if (final / ".ready").is_file():
        return final
    (Path(cfg["fleet_root"]) / "cache" / "uv-linux").mkdir(parents=True, exist_ok=True)
    with locked(envs / f"{key}.lock"):
        if (final / ".ready").is_file():
            return final
        tmp = envs / f"{key}.building"
        if tmp.exists():
            _rmtree(tmp)
        tmp.mkdir(parents=True)
        name = f"arena-build-{key[:12]}-{secrets.token_hex(3)}"
        try:
            r = subprocess.run(build_command(cfg, spec, tmp, name), capture_output=True, text=True,
                               timeout=float(cfg["build_timeout_s"]), env=docker_env(cfg))
        except subprocess.TimeoutExpired:
            _docker_kill(cfg, name)
            _rmtree(tmp)
            raise Failed("building the model's environment timed out (not charged)", refund=True) from None
        log({"event": "build", "key": key, "spec": spec, "rc": r.returncode,
             "stderr_tail": r.stderr[-4000:]})
        if r.returncode != 0:
            _rmtree(tmp)
            # The build container holds no data, only the agent's own package
            # list, so pip's complaint is safe and useful to show.
            tail = "\n".join((r.stderr or r.stdout).strip().splitlines()[-15:])
            raise Failed(f"installing the model's packages failed (not charged):\n{tail}", refund=True)
        (tmp / ".ready").write_text(json.dumps(spec, sort_keys=True) + "\n")
        os.replace(tmp, final)
        _make_read_only(final)
    return final


# --------------------------------------------------------------------------
# scoring


RUNNER_PY = ("import sys; sys.path.insert(0, sys.argv.pop(1)); sys.argv[0] = 'arena'; "
             "from arena.cli import main; sys.exit(main())")


def worker_command(cfg: dict, *, models: Path, env: Path | None, prefix: str) -> list[str]:
    """One model worker (or child): its own container, started by the runner
    through ARENA_WORKER_CMD for every worker. No network, read-only root,
    capped, unprivileged; the staged models (at the same absolute path, so the
    runner's model_dir resolves inside) and the model's env, both read-only.
    No data is mounted: rows arrive only over stdin, as of `now`. `{id}` is
    the runner's per-worker id."""
    cpus = int(cfg["cpus"])
    # Source as given (Docker's file sharing may cover a path but not its
    # resolved form, e.g. OrbStack's /tmp vs /private/tmp); target the
    # resolved path, which is the model_dir the runner's registry sends.
    inside = Path(os.path.realpath(models))
    cmd = [
        cfg["docker"], "run", "-i", "--rm", "--pull", "never", "--name", f"{prefix}-{{id}}",
        "--network", "none",
        "--cpus", str(cpus), "--memory", cfg["memory"], "--memory-swap", cfg["memory"],
        "--pids-limit", str(cfg["pids_limit"]),
        "--read-only", "--tmpfs", "/tmp:rw,size=1g,mode=1777",
        "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
        "--user", cfg["user"], "--log-driver", "none",
        "-v", f"{models}:{inside}:ro",
        "-w", "/tmp",
        "-e", "HOME=/tmp", "-e", "TMPDIR=/tmp", "-e", "ARENA_WORKER_SCRATCH=/tmp", "-e", "ARENA_WORKER=1",
        "-e", "PYTHONHASHSEED=0", "-e", "PYTHONDONTWRITEBYTECODE=1",
        "-e", "HF_HUB_OFFLINE=1", "-e", "TRANSFORMERS_OFFLINE=1",
    ]
    for var in THREAD_VARS:
        cmd += ["-e", f"{var}={cpus}"]
    python = "python3"
    if env is not None:
        cmd += ["-v", f"{env}:/env:ro", "-e", "HF_HOME=/env/hf", "-e", "VIRTUAL_ENV=/env"]
        python = "/env/bin/python"
    return cmd + [cfg["image"], python, "-m", "arena.worker"]


def kill_command(cfg: dict) -> list[str]:
    return [cfg["docker"], "kill", "{id}"]


def runner_command(cfg: dict, *, snapshot: str, model_dir: Path, episodes: int, seed: int) -> list[str]:
    """`arena eval` on the host, from the pinned harness, in isolated mode
    (-I: no PYTHONPATH, no user site, no script dir on sys.path). It reads the
    snapshot itself (ARENA_HOME) and writes nothing (no --record, no cache)."""
    if not cfg.get("runner_python") or not cfg.get("harness"):
        raise RuntimeError("generation eval config lacks harness / runner_python (arena fleet launch sets them)")
    return [
        cfg["runner_python"], "-I", "-c", RUNNER_PY, cfg["harness"],
        "eval", str(model_dir), "--tier", cfg["tier"],
        "--episodes", str(episodes), "--seed", str(seed), "--snapshot", snapshot,
        "--threads", str(int(cfg["cpus"])), "--sig", str(cfg["sig_digits"]), "--json", "--no-cache",
    ]


def runner_env(cfg: dict, *, worker: list[str], tmp: Path) -> dict[str, str]:
    env = docker_env(cfg)
    env.update({"HOME": str(tmp), "TMPDIR": str(tmp), "ARENA_HOME": str(cfg["arena_home"]),
                "ARENA_WORKER_CMD": json.dumps(worker), "ARENA_WORKER_KILL_CMD": json.dumps(kill_command(cfg)),
                "PYTHONDONTWRITEBYTECODE": "1"})
    return env


def round_sig(v: float, digits: int) -> float | None:
    if not isinstance(v, (int, float)) or isinstance(v, bool) or not math.isfinite(v):
        return None
    return float(f"{float(v):.{digits}g}")


def filter_scores(stdout: str, digits: int) -> dict:
    """Rounded per-target scores from `arena eval --json`, and nothing else.
    Takes the last stdout line that parses as a JSON object; reads its
    "targets" (core's `arena eval --json`), else "scores", else the object
    itself, as {target: number} or {target: {metric: number}}. Keys must look
    like target and metric names, so not even a key can carry text out of the
    container. Episode and failure counts are dropped too: a count of failures
    is a channel."""
    obj = None
    for line in reversed(stdout.strip().splitlines()[-200:]):
        line = line.strip()
        if line.startswith("{"):
            try:
                obj = json.loads(line)
                break
            except ValueError:
                continue
    if obj is None:
        with contextlib.suppress(ValueError):
            obj = json.loads(stdout)
    if not isinstance(obj, dict):
        raise Failed("the scorer returned no scores")
    raw = obj.get("targets", obj.get("scores", obj))
    if not isinstance(raw, dict):
        raise Failed("the scorer returned no scores")
    out: dict = {}
    for target, val in list(raw.items())[:64]:
        if not isinstance(target, str) or not TARGET_KEY_RE.match(target):
            continue
        if isinstance(val, dict):
            metrics = {}
            for metric, v in list(val.items())[:MAX_METRICS]:
                if isinstance(metric, str) and METRIC_RE.match(metric):
                    r = round_sig(v, digits)
                    if r is not None or v is None:
                        metrics[metric] = r
            if metrics:
                out[target] = metrics
        else:
            r = round_sig(val, digits)
            if r is not None:
                out[target] = r
    if not out:
        raise Failed("the scorer returned no scores")
    return out


def _docker_kill(cfg: dict, name: str) -> None:
    with contextlib.suppress(Exception):
        subprocess.run([cfg["docker"], "kill", name], capture_output=True, timeout=30, env=docker_env(cfg))


def _docker_kill_prefix(cfg: dict, prefix: str) -> int:
    """Kill every container whose name starts with `prefix` (a call's
    workers); returns how many were still running."""
    try:
        r = subprocess.run([cfg["docker"], "ps", "-q", "--filter", f"name=^{prefix}-"], capture_output=True,
                           text=True, timeout=30, env=docker_env(cfg))
    except (OSError, subprocess.SubprocessError):
        return 0
    ids = r.stdout.split()
    if ids:
        with contextlib.suppress(Exception):
            subprocess.run([cfg["docker"], "kill", *ids], capture_output=True, timeout=60, env=docker_env(cfg))
    return len(ids)


def run_scoring(cfg: dict, cmd: list[str], name: str, log, *, env: dict | None = None,
                cwd: Path | None = None) -> str:
    """Run the host runner; on timeout kill its whole process group and every
    worker container of this call (named `<name>-<id>`)."""
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, cwd=cwd,
                            start_new_session=True)
    try:
        out, err = proc.communicate(timeout=float(cfg["timeout_s"]))
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(proc.pid, 9)
        proc.communicate()
        left = _docker_kill_prefix(cfg, name)
        log({"event": "timeout", "name": name, "containers_killed": left})
        raise Failed("scoring timed out") from None
    finally:
        left = _docker_kill_prefix(cfg, name)
        if left:
            log({"event": "leftover_containers", "name": name, "killed": left})
    # stdout/stderr go to the coordinator's log only, never to the agent.
    log({"event": "scored", "rc": proc.returncode, "stdout_tail": out[-20000:], "stderr_tail": err[-20000:]})
    if proc.returncode != 0:
        raise Failed("scoring failed: the model raised, timed out or returned an invalid forecast on this tier")
    return out


# --------------------------------------------------------------------------
# entry point


def _make_read_only(root: Path) -> None:
    for dirpath, _, filenames in os.walk(root, followlinks=False):
        for f in filenames:
            p = Path(dirpath) / f
            if not p.is_symlink():
                with contextlib.suppress(OSError):
                    p.chmod(p.stat().st_mode & 0o555)
        with contextlib.suppress(OSError):
            Path(dirpath).chmod(0o555)


def _rmtree(root: Path) -> None:
    def onexc(func, path, exc):
        with contextlib.suppress(OSError):
            os.chmod(os.path.dirname(path), 0o755)
            os.chmod(path, 0o755)
        func(path)

    shutil.rmtree(root, onexc=onexc)


def run(argv: list[str], *, script: Path, cwd: Path) -> tuple[int, dict]:
    cfg = load_config(script)
    try:
        return _run(cfg, argv, cwd)
    except (Refused, Failed):
        raise
    except Exception:
        import traceback
        err = Path(cfg["fleet_root"]) / "state" / "eval-errors.log"
        with contextlib.suppress(OSError):
            err.parent.mkdir(parents=True, exist_ok=True)
            with err.open("a") as fh:
                fh.write(f"--- {time.ctime()} argv={argv!r} cwd={cwd}\n{traceback.format_exc()}\n")
        raise


def _run(cfg: dict, argv: list[str], cwd: Path) -> tuple[int, dict]:
    gen, agent, args = parse_args(argv)
    g = gen_config(cfg, gen)
    root = Path(g["fleet_root"])
    agent_dir = root / f"gen{gen}" / agent
    state = root / "state" / f"gen{gen}" / agent
    if not agent_dir.is_dir() or not state.is_dir():
        raise Refused("unknown agent")

    calls = state / "calls.jsonl"

    def log(entry: dict) -> None:
        with calls.open("a") as fh:
            fh.write(json.dumps({"t": time.time(), **entry}) + "\n")

    if args == ["--budget"]:
        b = read_budget(state)
        return 0, {"budget_left": b["budget"] - b["used"], "budget": b["budget"]}
    if len(args) != 1:
        raise Refused("usage: $ARENA_EVAL models/<name>   (or --budget)")

    model_dir = resolve_model_dir(args[0], agent_dir, cwd)
    tree = resolve_tree(model_dir)
    with locked(state / "eval.lock", blocking=False) as mine:
        if not mine:
            raise Refused("another arena-eval of yours is still running (not charged)")
        b = charge(state)
        call_id = f"{int(time.time())}-{secrets.token_hex(4)}"
        staged = state / "staged" / call_id
        try:
            models = stage(tree, staged)
            mhash = model_hash(models / model_dir.name, sorted(tree[model_dir.name]["files"], key=str),
                               harness=Path(g["harness"]) if g.get("harness") else None)
            seed = secrets.randbits(31)
            episodes = int(g["episodes"])
            log({"event": "call", "call": call_id, "model": model_dir.name, "hash": mhash,
                 "tier": g["tier"], "episodes": episodes, "seed": seed, "used": b["used"]})
            if g["backend"] == "selftest":
                scores = {"selftest": {"ok": 1.0}}
            else:
                with fleet_slot(root, int(g["max_concurrent"]), float(g["timeout_s"])):
                    env = ensure_env(g, env_spec(tree, g["image"]), log)
                    name = f"arena-eval-{call_id}"
                    tmp = staged / "tmp"
                    tmp.mkdir()
                    worker = worker_command(g, models=models, env=env, prefix=name)
                    cmd = runner_command(g, snapshot=g["snapshot"], model_dir=models / model_dir.name,
                                         episodes=episodes, seed=seed)
                    stdout = run_scoring(g, cmd, name, log, env=runner_env(g, worker=worker, tmp=tmp), cwd=tmp)
                scores = filter_scores(stdout, int(g["sig_digits"]))
        except Failed as e:
            if e.refund:
                b = refund(state)
            log({"event": "failed", "call": call_id, "message": str(e)})
            raise
        except Refused:
            refund(state)
            raise
        except Exception as e:
            # Our fault (Docker down, a bug): give the call back.
            refund(state)
            log({"event": "internal_error", "call": call_id, "error": repr(e)[:500]})
            raise
        finally:
            with contextlib.suppress(Exception):
                _rmtree(staged)
        log({"event": "result", "call": call_id, "scores": scores})
    return 0, {
        "model": model_dir.name,
        "model_hash": mhash[:12],
        "tier": g["tier"],
        "episodes": episodes,
        "scores": scores,
        "budget_left": b["budget"] - b["used"],
    }


def main(argv: list[str] | None = None, script: Path | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    script = Path(os.path.realpath(script or __file__))
    try:
        code, out = run(argv, script=script, cwd=Path(os.getcwd()))
        print(json.dumps(out, indent=2))
        return code
    except Refused as e:
        print(f"arena-eval: refused: {e}", file=sys.stderr)
        return 2
    except Failed as e:
        print(f"arena-eval: {e}", file=sys.stderr)
        return 1
    except Exception as e:  # never a traceback: it could carry paths or data
        print(f"arena-eval: internal error ({type(e).__name__}); the coordinator has the log", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
