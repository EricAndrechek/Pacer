"""Model discovery, content hashes and pinned children.

A model is a folder with `model.toml` and `model.py`. Its identity is a
sha256 over its own files (sorted relative paths and bytes; caches and editor
junk excluded) AND the shared code it runs: the `kit/` tree, the harness code
that serves it and runs its worker (everything under `arena/` but scoring, the
command line, the results database and the self-tests), and `uv.lock`
(`code_hash`). Most models are a few lines over kit, so a kit edit is a
different model: its scores, its cached child forecasts and its pins must not
carry over. `folder_hash` is the folder alone. Children named
in `model.toml` are resolved when the parent loads and pinned by hash
(`children = ["name"]`, or `["name@<hash prefix>"]` to require a version);
the runner refuses to run a child whose folder changed since. Loops are an
error at load, and the call chain is capped at depth 8.
"""
from __future__ import annotations

import hashlib
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

MAX_DEPTH = 8
_SKIP_DIRS = {"__pycache__", ".git", ".ipynb_checkpoints", ".pytest_cache", ".venv"}
_SKIP_SUFFIXES = {".pyc", ".pyo"}
_SKIP_NAMES = {".DS_Store"}


class RegistryError(Exception):
    pass


def model_files(folder: Path) -> list[Path]:
    out = []
    for p in folder.rglob("*"):
        rel = p.relative_to(folder)
        if any(part in _SKIP_DIRS for part in rel.parts):
            continue
        if p.is_file() and p.suffix not in _SKIP_SUFFIXES and p.name not in _SKIP_NAMES:
            out.append(p)
    return sorted(out, key=lambda p: p.relative_to(folder).as_posix())


def _files_digest(h, root: Path, files: list[Path]) -> None:
    for p in files:
        data = p.read_bytes()
        h.update(p.relative_to(root).as_posix().encode())
        h.update(b"\0")
        h.update(len(data).to_bytes(8, "big"))
        h.update(data)


def folder_hash(folder: Path) -> str:
    """sha256 over each file's relative path, a NUL, its length (8 bytes,
    big-endian) and its bytes, in path order: the folder alone."""
    folder = Path(folder)
    h = hashlib.sha256()
    _files_digest(h, folder, model_files(folder))
    return h.hexdigest()


ARENA_ROOT = Path(__file__).resolve().parent.parent
# Harness code that cannot change what a model computes from what it is
# served: scoring, the command line, the results database, the self-tests,
# attribution (provenance) and the hashing itself. Everything else under
# arena/ (the worker, the protocol, the views and pricing that decide what a
# worker receives, the runner that serves it and its children) is part of
# every model's identity.
_NOT_MODEL_CODE = ("arena/scoring/", "arena/cli.py", "arena/cli_", "arena/results.py",
                   "arena/results_schema.sql", "arena/selftest.py", "arena/registry.py",
                   "arena/provenance.py", "arena/leakcheck.py")


def code_files(root: Path = ARENA_ROOT) -> list[Path]:
    """The shared code every model runs, under an arena root: kit/**,
    arena/** but `_NOT_MODEL_CODE`, and uv.lock; sorted by relative path."""
    root = Path(root)
    out = []
    for part in ("arena", "kit"):
        if not (root / part).is_dir():
            continue
        for p in model_files(root / part):
            rel = p.relative_to(root).as_posix()
            if part == "arena" and rel.startswith(_NOT_MODEL_CODE):
                continue
            out.append(p)
    if (root / "uv.lock").is_file():
        out.append(root / "uv.lock")
    return sorted(out, key=lambda p: p.relative_to(root).as_posix())


_code_memo: dict[Path, tuple[tuple, str]] = {}


def code_hash(root: Path = ARENA_ROOT) -> str:
    """sha256 of `code_files` (same encoding as `folder_hash`); recomputed
    only when a file's size or mtime changed."""
    root = Path(root).resolve()
    files = code_files(root)
    sig = tuple((p.relative_to(root).as_posix(), *(lambda st: (st.st_size, st.st_mtime_ns))(p.stat()))
                for p in files)
    hit = _code_memo.get(root)
    if hit is not None and hit[0] == sig:
        return hit[1]
    h = hashlib.sha256()
    _files_digest(h, root, files)
    out = h.hexdigest()
    _code_memo[root] = (sig, out)
    return out


def content_hash(folder: Path, code: str | None = None) -> str:
    """A model's identity: sha256 of b"model\0", its folder hash, b"\0code\0"
    and the code hash (`code`, default this harness's `code_hash()`), the hex
    digests as ASCII."""
    h = hashlib.sha256(b"model\0")
    h.update(folder_hash(folder).encode())
    h.update(b"\0code\0")
    h.update((code if code is not None else code_hash()).encode())
    return h.hexdigest()


@dataclass
class ModelInfo:
    name: str
    path: Path
    hash: str                    # content_hash: the folder and the shared code
    targets: tuple[str, ...]
    deps: tuple[str, ...]
    config: dict
    meta: dict
    children: dict[str, "ModelInfo"] = field(default_factory=dict)

    @property
    def short(self) -> str:
        return f"{self.name}@{self.hash[:12]}"

    def depth(self) -> int:
        """How deep its children nest (0 for a model without children)."""
        return max((1 + c.depth() for c in self.children.values()), default=0)

    def child_hashes(self) -> list[str]:
        return [c.hash for c in self.children.values()]


def read_toml(folder: Path) -> dict:
    f = Path(folder) / "model.toml"
    if not f.is_file() or not (Path(folder) / "model.py").is_file():
        raise RegistryError(f"{folder} is not a model (needs model.toml and model.py)")
    try:
        return tomllib.loads(f.read_text())
    except tomllib.TOMLDecodeError as e:
        raise RegistryError(f"{f}: {e}") from None


class Registry:
    """Models under one or more roots (each holding `<name>/model.toml`)."""

    def __init__(self, roots: list[Path] | None = None):
        default = Path(__file__).resolve().parent.parent / "models"
        self.roots = [Path(r) for r in (roots or [default])]
        self._by_name: dict[str, Path] | None = None

    def discover(self) -> dict[str, Path]:
        if self._by_name is None:
            found: dict[str, Path] = {}
            for root in self.roots:
                if not root.is_dir():
                    continue
                for d in sorted(root.iterdir()):
                    if (d / "model.toml").is_file() and (d / "model.py").is_file():
                        try:
                            read_toml(d)
                        except RegistryError:
                            continue
                        # A model is found by its folder name only. Indexing the
                        # toml `name` too let a copied model that kept its
                        # original's name shadow the original for every parent
                        # that names it as a child (gen 1: a copy of
                        # spend-decay-6h replaced it inside other ensembles).
                        found.setdefault(d.name, d)
            self._by_name = found
        return self._by_name

    def find(self, ref: str | Path) -> Path:
        p = Path(ref)
        if (p / "model.toml").is_file():
            return p.resolve()
        by = self.discover()
        if str(ref) in by:
            return by[str(ref)].resolve()
        raise RegistryError(f"no model {ref!r} (looked in {', '.join(map(str, self.roots))})")

    def load(self, ref: str | Path) -> ModelInfo:
        return self._load(self.find(ref), stack=())

    def _load(self, folder: Path, stack: tuple[Path, ...]) -> ModelInfo:
        if folder in stack:
            chain = " -> ".join(read_toml(p).get("name", p.name) for p in (*stack, folder))
            raise RegistryError(f"child loop: {chain}")
        if len(stack) > MAX_DEPTH:
            raise RegistryError(f"children nest deeper than {MAX_DEPTH}: {folder.name}")
        meta = read_toml(folder)
        info = ModelInfo(
            name=folder.name, path=folder, hash=content_hash(folder),
            targets=tuple(str(t) for t in meta.get("targets", ())),
            deps=tuple(str(d) for d in meta.get("deps", ())),
            config=dict(meta.get("config", {})), meta=meta)
        for ref in meta.get("children", ()):
            name, _, want = str(ref).partition("@")
            child = self._load(self.find(name), (*stack, folder))
            if want and not child.hash.startswith(want):
                raise RegistryError(f"{info.name}: child {name} is {child.hash[:12]}, pinned {want}")
            info.children[name] = child
        return info

    @staticmethod
    def verify(info: ModelInfo) -> None:
        """Refuse a model (or a child) whose folder changed since it loaded."""
        now = content_hash(info.path)
        if now != info.hash:
            raise RegistryError(f"{info.name} changed since it was loaded ({info.hash[:12]} -> {now[:12]})")
