"""Docker workers for the coordinator's own runs (`arena run --docker`).

The same isolation `arena-eval` gives an agent's model, for a tournament run
from this checkout: the runner stays in this process (it holds the data);
every worker of a model, children included, is its own container of the
scoring image (`fleet.image`), with no network, a read-only root, the staged
models and the model tree's env (`arena build`) mounted read-only, and no
data at all (rows arrive over stdin). Host workers can read anything this
user can, so they are for trusted models only; an agent's model runs here.

`docker_workers` stages every model tree into one folder under /tmp (Docker
Desktop and OrbStack share /tmp), reloads the models from there (same
identity: a model's hash is its files and the harness code, not its path),
builds or finds each tree's env, and returns the per-model worker commands
for `RunConfig.worker_cmds`.
"""
from __future__ import annotations

import os
import secrets
import shutil
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from arena.registry import ARENA_ROOT, ModelInfo, Registry, RegistryError, model_files
from fleet import evalgate
from fleet.image import build_image
from fleet.paths import FleetPaths


@dataclass
class DockerWorkers:
    models: list[ModelInfo]                       # reloaded from the staged copies
    commands: dict[str, tuple[tuple[str, ...], tuple[str, ...]]] = field(default_factory=dict)
    image: str = ""
    staged: Path | None = None
    envs: dict[str, str | None] = field(default_factory=dict)   # model name -> env dir (None: image only)

    def cleanup(self) -> None:
        if self.staged is not None:
            root = self.staged.parent
            for dirpath, dirnames, _ in os.walk(root):
                for d in dirnames:
                    os.chmod(os.path.join(dirpath, d), 0o755)
            shutil.rmtree(root, ignore_errors=True)


def _tree(info: ModelInfo):
    yield info
    for c in info.children.values():
        yield from _tree(c)


def docker_workers(infos: list[ModelInfo], *, docker: str | None = None, cpus: int = 2, memory: str = "4g",
                   paths: FleetPaths | None = None, log=print) -> DockerWorkers:
    docker = docker or shutil.which("docker") or "docker"
    paths = paths or FleetPaths.default()
    root = Path(tempfile.mkdtemp(prefix="arena-run-", dir="/tmp"))
    staged = root / "models"
    staged.mkdir()
    out = DockerWorkers([], staged=staged)
    try:
        seen: dict[str, Path] = {}
        for info in infos:
            for m in _tree(info):
                name = m.path.name
                if name in seen:
                    if seen[name] != m.path:
                        raise RegistryError(f"two different models are both called {name!r}")
                    continue
                seen[name] = m.path
                for f in model_files(m.path):
                    dest = staged / name / f.relative_to(m.path)
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(f, dest)
                    dest.chmod(0o444)
        for dirpath, _, _ in os.walk(staged):
            os.chmod(dirpath, 0o555)
        reg = Registry([staged])
        out.models = [reg.load(info.path.name) for info in infos]
        for a, b in zip(infos, out.models):
            if a.hash != b.hash:
                raise RegistryError(f"{a.name}: the staged copy hashes differently ({a.hash[:12]} vs {b.hash[:12]})")
        out.image = build_image(ARENA_ROOT, docker=docker)
        log(f"docker workers: image {out.image}, models staged in {staged}")
        build_cfg = {**evalgate.DEFAULTS, "fleet_root": str(paths.root), "arena_home": str(paths.home),
                     "docker": docker}
        run_cfg = {**evalgate.DEFAULTS, "docker": docker, "image": out.image, "cpus": int(cpus), "memory": memory}
        prefix = f"arena-run-{secrets.token_hex(4)}"
        for m in out.models:
            tree = evalgate.resolve_tree(staged / m.path.name)
            spec = evalgate.env_spec(tree, out.image)
            env = evalgate.ensure_env(build_cfg, spec, lambda e: log(f"  build {e.get('key', '')} rc={e.get('rc')}"))
            out.envs[m.name] = str(env) if env else None
            cmd = evalgate.worker_command(run_cfg, models=staged, env=env, prefix=prefix)
            out.commands[m.hash] = (tuple(cmd), tuple(evalgate.kill_command(run_cfg)))
            log(f"  {m.name}: env {env.name if env else '(image only)'}")
        return out
    except BaseException:
        out.cleanup()
        raise


def under_fleet_root(info: ModelInfo, paths: FleetPaths | None = None) -> bool:
    """Is this model (or a child) an agent's, from the fleet's folders?"""
    root = Path(os.path.realpath((paths or FleetPaths.default()).root))
    for m in _tree(info):
        p = Path(os.path.realpath(m.path))
        if p == root or root in p.parents:
            return True
    return False
