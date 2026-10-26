"""Installing the eval gate, the per-agent wrappers and the eval state.

Everything here is written by the coordinator, outside every agent's
writable area, and left read-only."""
from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from fleet import evalgate
from fleet.paths import FleetPaths, check_agent_name

PYTHON_CANDIDATES = (
    "/opt/homebrew/bin/python3.12", "/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3.14",
    "/usr/local/bin/python3.12", "/usr/local/bin/python3.13",
)


def find_gate_python() -> str:
    """A stable interpreter (>= 3.11, for tomllib) outside every repo and
    venv: the gate must keep working while worktrees come and go."""
    for c in PYTHON_CANDIDATES:
        if Path(c).exists() and _version_ok(c):
            return c
    r = subprocess.run(["uv", "python", "find", "3.12"], capture_output=True, text=True)
    c = r.stdout.strip()
    if r.returncode == 0 and c and _version_ok(c) and ".venv" not in c:
        return c
    raise RuntimeError("no Python >= 3.11 found for the eval gate")


def _version_ok(python: str) -> bool:
    r = subprocess.run([python, "-c", "import sys; print(sys.version_info >= (3, 11))"],
                       capture_output=True, text=True)
    return r.returncode == 0 and r.stdout.strip() == "True"


def _write_ro(path: Path, text: str, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.chmod(0o644)
    path.write_text(text)
    path.chmod(mode)


def install_gate(paths: FleetPaths, *, python: str | None = None, backend: str = "docker",
                 overrides: dict | None = None) -> Path:
    """`<root>/bin/arena-eval` = fleet/evalgate.py with a pinned interpreter
    in isolated mode (-I: no PYTHON* variables, no user site, no script dir
    on sys.path), and its configuration beside it."""
    python = python or find_gate_python()
    source = Path(evalgate.__file__).read_text()
    _write_ro(paths.eval_gate, f"#!{python} -I\n" + source, 0o555)
    docker = shutil.which("docker") or "docker"
    cfg = {
        "fleet_root": str(paths.root),
        "arena_home": str(paths.home),
        "docker": docker,
        # Pinned here, never read from the caller's environment: the gate
        # streams hidden-tier rows to `docker run -i`, so an agent that could
        # point DOCKER_HOST at a daemon of its own would receive them.
        "docker_host": docker_host(docker) if backend == "docker" else None,
        "backend": backend,
    }
    cfg.update(overrides or {})
    _write_ro(paths.eval_config, json.dumps(cfg, indent=2) + "\n", 0o444)
    return paths.eval_gate


def docker_host(docker: str) -> str | None:
    """The daemon endpoint of the coordinator's current Docker context."""
    r = subprocess.run([docker, "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"],
                       capture_output=True, text=True)
    host = r.stdout.strip()
    return host if r.returncode == 0 and host else None


def build_runner_env(paths: FleetPaths, gen: int, template: Path, *, python: str = "3.12") -> Path:
    """The interpreter `arena-eval` runs the trusted runner with, on the host:
    a venv under the fleet's state (out of every agent's reach) holding the
    template's locked dependencies. The harness itself is imported from the
    template, which agents cannot write, so the runner is the generation's
    pinned harness and nothing an agent edited."""
    env_dir = paths.state / f"gen{gen}" / "runner-env"
    py = env_dir / "bin" / "python"
    want = hashlib.sha256((template / "uv.lock").read_bytes()).hexdigest()
    stamp = env_dir / ".uv-lock-sha256"
    if py.exists() and stamp.is_file() and stamp.read_text().strip() == want:
        return py
    with tempfile.TemporaryDirectory(prefix="arena-runner-env-") as tmp:
        req = Path(tmp) / "requirements.txt"
        subprocess.run(["uv", "export", "--frozen", "--no-dev", "--no-emit-project", "--no-hashes",
                        "--quiet", "-o", str(req)], cwd=template, check=True)
        subprocess.run(["uv", "venv", "--quiet", "--clear", "--python", python, str(env_dir)], check=True)
        subprocess.run(["uv", "pip", "install", "--quiet", "--python", str(py), "-r", str(req)], check=True)
    stamp.write_text(want + "\n")
    return py


def wrapper_text(paths: FleetPaths, gen: int, name: str) -> str:
    check_agent_name(name)
    return f'#!/bin/sh\nexec {paths.eval_gate} --agent gen{gen}/{name} -- "$@"\n'


def write_wrapper(paths: FleetPaths, gen: int, name: str) -> Path:
    w = paths.eval_wrapper(gen, name)
    _write_ro(w, wrapper_text(paths, gen, name), 0o555)
    w.parent.chmod(0o555)
    return w


def write_gen_eval_config(paths: FleetPaths, gen: int, *, snapshot: str, image: str | None,
                          episodes: int, tier: str = "leaderboard", harness: Path | None = None,
                          runner_python: Path | None = None) -> Path:
    """`harness` (the generation's template) and `runner_python` (from
    `build_runner_env`) are where the gate runs the runner on the host."""
    if tier not in ("leaderboard",):
        raise ValueError("agents only ever score on the leaderboard tier")
    p = paths.state / f"gen{gen}" / "eval.json"
    _write_ro(p, json.dumps({"snapshot": snapshot, "image": image, "episodes": episodes, "tier": tier,
                             "harness": str(harness) if harness else None,
                             "runner_python": str(runner_python) if runner_python else None},
                            indent=2) + "\n", 0o444)
    return p


def init_budget(paths: FleetPaths, gen: int, name: str, budget: int) -> Path:
    """Create the budget once; a relaunch keeps what was already spent."""
    state = paths.agent_state(gen, name)
    state.mkdir(parents=True, exist_ok=True)
    b = state / "budget.json"
    if not b.exists():
        b.write_text(json.dumps({"budget": budget, "used": 0}, indent=2) + "\n")
    return b
