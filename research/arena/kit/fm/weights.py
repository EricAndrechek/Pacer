"""Pretrained weights, offline: where a model's Hugging Face snapshot lives on
this machine, and the process settings every pretrained model wants.

Nothing here touches the network. A weights spec is a Hugging Face repo id,
optionally pinned: `"mistralai/Timestral-28M@49b26409…"`, the same string a
model.toml lists under `weights` (what `arena build` downloads into the Docker
env). The snapshot is looked up, in order, under

1. `$HF_HUB_CACHE` (or the older `$HUGGINGFACE_HUB_CACHE`);
2. `$HF_HOME/hub` — a Docker worker gets `HF_HOME=/env/hf`, the env that
   `arena build` filled;
3. `~/.cache/huggingface/hub` of the account running the process, found
   through the password database. A host worker runs with `HOME` pointed at
   its scratch folder (arena/runner.py `worker_env`), so `Path.home()` alone
   would miss the owner's cache;
4. `Path.home()/.cache/huggingface/hub`.

A pinned revision must exist as `snapshots/<rev>`; an unpinned spec takes
`refs/main`. Missing weights raise `WeightsMissing` with every place looked.
"""
from __future__ import annotations

import os
import pwd
import threading
from pathlib import Path
from typing import Callable, TypeVar

T = TypeVar("T")

# Pretrained-model libraries read these at import; set them before any import.
for _var in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_DATASETS_OFFLINE"):
    os.environ.setdefault(_var, "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")


class WeightsMissing(FileNotFoundError):
    pass


def parse_spec(spec: str) -> tuple[str, str | None]:
    """'org/name@rev' -> ('org/name', 'rev'); 'org/name' -> ('org/name', None)."""
    repo, _, rev = str(spec).partition("@")
    if repo.count("/") != 1:
        raise ValueError(f"weights spec must be org/name[@revision]: {spec!r}")
    return repo, (rev or None)


def hub_caches() -> list[Path]:
    """Every Hugging Face hub cache folder that exists, in lookup order."""
    cands: list[Path] = []
    for var in ("HF_HUB_CACHE", "HUGGINGFACE_HUB_CACHE"):
        if os.environ.get(var):
            cands.append(Path(os.environ[var]))
    if os.environ.get("HF_HOME"):
        cands.append(Path(os.environ["HF_HOME"]) / "hub")
    try:
        cands.append(Path(pwd.getpwuid(os.getuid()).pw_dir) / ".cache" / "huggingface" / "hub")
    except (KeyError, OSError):
        pass
    cands.append(Path.home() / ".cache" / "huggingface" / "hub")
    out, seen = [], set()
    for c in cands:
        try:
            ok = c.is_dir()
        except OSError:            # e.g. a home the sandbox won't let us stat
            ok = False
        if ok and str(c) not in seen:
            seen.add(str(c))
            out.append(c)
    return out


def local_snapshot(spec: str) -> Path:
    """The local folder holding a cached snapshot of `spec`'s repo."""
    repo, rev = parse_spec(spec)
    org, name = repo.split("/")
    looked = []
    for cache in hub_caches():
        d = cache / f"models--{org}--{name}"
        looked.append(str(d))
        snaps = d / "snapshots"
        if not snaps.is_dir():
            continue
        if rev is not None:
            if (snaps / rev).is_dir():
                return snaps / rev
            ref = d / "refs" / rev                   # a branch or tag name
            if ref.is_file() and (snaps / ref.read_text().strip()).is_dir():
                return snaps / ref.read_text().strip()
            continue
        ref = d / "refs" / "main"
        if ref.is_file() and (snaps / ref.read_text().strip()).is_dir():
            return snaps / ref.read_text().strip()
        found = sorted(p for p in snaps.iterdir() if p.is_dir())
        if len(found) == 1:
            return found[0]
    raise WeightsMissing(f"no local snapshot of {spec} (looked in: {', '.join(looked) or 'no hub cache found'}); "
                         "on the host the Hugging Face cache must hold it, in Docker `arena build` fetches it")


def has_weights(spec: str) -> bool:
    try:
        local_snapshot(spec)
        return True
    except (WeightsMissing, ValueError):
        return False


_threads_set = False


def set_threads(default: int = 4) -> int:
    """Pin torch's intra-op threads once per process: `$OMP_NUM_THREADS` when
    the launcher set it (a Docker worker gets its CPU cap; `--threads` sets it
    for host workers), else `default`. Torch otherwise takes every core, and a
    container sees all 14 while it may use 2."""
    global _threads_set
    import torch
    n = default
    for var in ("TORCH_NUM_THREADS", "OMP_NUM_THREADS"):
        v = os.environ.get(var)
        if v and v.isdigit() and int(v) > 0:
            n = int(v)
            break
    if not _threads_set:
        torch.set_num_threads(max(1, n))
        try:
            torch.set_num_interop_threads(1)
        except RuntimeError:       # already set by someone in this process
            pass
        _threads_set = True
    return torch.get_num_threads()


_cache: dict[tuple, object] = {}
_lock = threading.Lock()


def cached(key: tuple, load: Callable[[], T]) -> T:
    """One loaded network per key per process. A Docker or host-subprocess
    worker lives for one episode, so this only saves reloads within it (and
    across episodes under `arena test`'s in-process workers, which share the
    process; the networks are only ever used for inference)."""
    with _lock:
        if key not in _cache:
            _cache[key] = load()
        return _cache[key]  # type: ignore[return-value]
