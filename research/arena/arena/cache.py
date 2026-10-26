"""Child forecasts, cached across runs.

A child's forecast is a pure function of (child hash, snapshot, view, now,
request): the runner fits a fresh child worker at `now` with exactly the
parent's view and derives the child's seed from the key. So the key names
everything that decides the answer, and a popular base model is computed once.

Entries are `.npz` files of float arrays plus a JSON index stored as bytes,
read with `allow_pickle=False`. Only the runner touches the cache; workers
never see its path.
"""
from __future__ import annotations

import hashlib
import json
import os
import tempfile
from pathlib import Path

import numpy as np

from arena.snapshot import arena_home
from arena.types import Forecast, Request, TargetForecast

CACHE_VERSION = 1


def request_hash(request: Request) -> str:
    h = hashlib.sha256()
    h.update(json.dumps({"now": request.now, "scope": [list(request.scope.accounts), request.scope.view]},
                        sort_keys=True).encode())
    for tr in request.targets:
        h.update(json.dumps({"key": tr.key, "target": str(tr.target), "accounts": list(tr.accounts),
                             "units": tr.units, "n_paths": tr.n_paths, "cap": tr.cap, "family": tr.family,
                             "reset_at": tr.reset_at}, sort_keys=True).encode())
        h.update(np.ascontiguousarray(tr.grid, dtype=np.int64).tobytes())
    return h.hexdigest()


def cache_key(child_hash: str, snapshot_id: str, view_key: dict, now: int, req_hash: str) -> str:
    blob = json.dumps({"v": CACHE_VERSION, "child": child_hash, "snapshot": snapshot_id,
                       "view": view_key, "now": int(now), "request": req_hash}, sort_keys=True)
    return hashlib.sha256(blob.encode()).hexdigest()


class ChildCache:
    def __init__(self, root: Path | None = None, enabled: bool = True):
        self.root = Path(root) if root is not None else arena_home() / "cache" / "children"
        self.enabled = enabled
        self.hits = 0
        self.misses = 0
        self._mem: dict[str, Forecast] = {}

    def _path(self, key: str) -> Path:
        return self.root / key[:2] / f"{key}.npz"

    def get(self, key: str) -> Forecast | None:
        if not self.enabled:
            return None
        if key in self._mem:
            self.hits += 1
            return self._mem[key]
        p = self._path(key)
        if p.is_file():
            try:
                fc = _load(p)
            except (OSError, ValueError, KeyError):
                fc = None
            if fc is not None:
                self._mem[key] = fc
                self.hits += 1
                return fc
        self.misses += 1
        return None

    def put(self, key: str, fc: Forecast) -> None:
        if not self.enabled:
            return
        self._mem[key] = fc
        if not self.writable:
            return
        try:
            self._write(key, fc)
        except OSError:
            # A read-only ARENA_HOME (e.g. the fleet's evaluator container)
            # keeps the in-memory cache and stops trying the disk.
            self.writable = False

    writable = True

    def _write(self, key: str, fc: Forecast) -> None:
        p = self._path(key)
        p.parent.mkdir(parents=True, exist_ok=True)
        arrays, index = {}, {}
        for i, (k, tf) in enumerate(fc.by_key.items()):
            arrays[f"p{i}"] = np.asarray(tf.paths, dtype=np.float64)
            ex = {}
            for j, (name, v) in enumerate(tf.extras.items()):
                arrays[f"e{i}_{j}"] = np.atleast_1d(np.asarray(v, dtype=np.float64))
                ex[name] = [f"e{i}_{j}", bool(np.ndim(v) == 0)]
            index[k] = {"paths": f"p{i}", "extras": ex}
        arrays["index"] = np.frombuffer(json.dumps(index).encode(), dtype=np.uint8)
        fd, tmp = tempfile.mkstemp(dir=p.parent, suffix=".tmp")
        os.close(fd)
        with open(tmp, "wb") as f:
            np.savez(f, **arrays)
        os.replace(tmp, p)


def _load(p: Path) -> Forecast:
    with np.load(p, allow_pickle=False) as z:
        index = json.loads(bytes(z["index"]).decode())
        out = {}
        for k, ent in index.items():
            extras = {}
            for name, (arr, scalar) in ent["extras"].items():
                v = z[arr]
                extras[name] = float(v[0]) if scalar else v.copy()
            out[k] = TargetForecast(z[ent["paths"]].copy(), extras)
    return Forecast(out)
