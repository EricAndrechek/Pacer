"""`arena build <model_dir>`: a model's environment, outside every sandbox.

Models may declare extra PyPI packages (`deps`) and Hugging Face weights
(`weights`) in model.toml. The build runs in the scoring image with the network
on and no data mounted, and leaves a read-only venv (made with
`--system-site-packages`, so the harness and its pinned packages stay visible)
and the weights under `<ARENA_HOME>/envs/<key>/`. The key hashes the image and
the sorted deps and weights, so models that need the same things share one env
and an edit to a model's code does not rebuild it. Scoring mounts the env
read-only and runs with `HF_HUB_OFFLINE=1`: nothing is fetched while scoring.

`arena-eval` calls the same code (fleet.evalgate.ensure_env) on demand; the
coordinator runs this to pre-build ports and earlier models.
"""
from __future__ import annotations

import json
import shutil
from pathlib import Path

from fleet import evalgate
from fleet.paths import FleetPaths


def build_model_env(paths: FleetPaths, model_dir: Path, image: str, *, docker: str | None = None,
                    timeout_s: float = 3600, log=print) -> Path | None:
    model_dir = Path(model_dir).resolve()
    tree = evalgate.resolve_tree(model_dir)
    spec = evalgate.env_spec(tree, image)
    cfg = {"fleet_root": str(paths.root), "arena_home": str(paths.home),
           "docker": docker or shutil.which("docker") or "docker", "build_timeout_s": timeout_s}
    key = evalgate.env_key(spec)
    if key is None:
        log(f"{model_dir.name}: needs nothing beyond the image")
        return None
    env = evalgate.ensure_env(cfg, spec, lambda e: log(json.dumps({k: v for k, v in e.items() if k != "stderr_tail"})))
    log(f"{model_dir.name}: env {key} ready at {env}")
    return env
