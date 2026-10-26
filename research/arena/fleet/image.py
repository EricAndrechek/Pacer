"""The scoring image, built locally from a template's harness."""
from __future__ import annotations

import hashlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

DOCKERFILE = Path(__file__).parent / "docker" / "Dockerfile"
CONTEXT_PARTS = ("pyproject.toml", "uv.lock", "arena", "kit")
IMAGE_REPO = "pacer-arena-eval"


def _context_files(src: Path) -> list[Path]:
    out = []
    for part in CONTEXT_PARTS:
        p = src / part
        if p.is_file():
            out.append(p)
        elif p.is_dir():
            out += sorted(f for f in p.rglob("*") if f.is_file() and "__pycache__" not in f.parts
                          and f.suffix != ".pyc")
    return out


def harness_hash(src: Path) -> str:
    h = hashlib.sha256(DOCKERFILE.read_bytes())
    for f in _context_files(src):
        h.update(str(f.relative_to(src)).encode() + b"\0" + hashlib.sha256(f.read_bytes()).digest())
    return h.hexdigest()


def image_tag(src: Path) -> str:
    return f"{IMAGE_REPO}:{harness_hash(src)[:12]}"


def uv_version() -> str:
    out = subprocess.run(["uv", "--version"], capture_output=True, text=True, check=True).stdout
    m = re.search(r"(\d+\.\d+\.\d+)", out)
    if not m:
        raise RuntimeError(f"cannot read the uv version from {out!r}")
    return m.group(1)


def image_exists(tag: str, docker: str = "docker") -> bool:
    return subprocess.run([docker, "image", "inspect", tag], capture_output=True).returncode == 0


def build_image(src: Path, *, docker: str = "docker", force: bool = False) -> str:
    """Build `pacer-arena-eval:<hash>` from `src` (a template or the arena
    dir) unless it already exists. `--rm` keeps no intermediate containers."""
    tag = image_tag(src)
    if image_exists(tag, docker) and not force:
        return tag
    with tempfile.TemporaryDirectory(prefix="arena-image-") as tmp:
        ctx = Path(tmp)
        for f in _context_files(src):
            out = ctx / f.relative_to(src)
            out.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, out)
        shutil.copy2(DOCKERFILE, ctx / "Dockerfile")
        subprocess.run([docker, "build", "--rm", "--build-arg", f"UV_VERSION={uv_version()}",
                        "-t", tag, str(ctx)], check=True)
    return tag
