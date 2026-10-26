"""`arena weights fetch [--models a,b | all] [--dry-run]`: download the
pretrained weights the chosen models (and their children) pin into the
standard Hugging Face cache, so host workers then run offline.

Each model.toml lists its weights as `org/name@revision` (`weights = [...]`,
top level; the same list `arena build` fetches into a Docker env). Scoring
never downloads anything: `kit.fm.weights` forces the Hugging Face libraries
offline and looks the snapshots up in `$HF_HUB_CACHE`, `$HF_HOME/hub` or
`~/.cache/huggingface/hub`, which is where this command writes (it honours
the same variables). Needs the `fm` extra (`uv sync --extra fm`) for
`huggingface_hub`.
"""
from __future__ import annotations

import argparse
import os
import sys
import tomllib
from pathlib import Path
from typing import Callable, Iterable

# The shape the eval gate accepts (and `arena build` downloads).
from fleet.evalgate import WEIGHTS_RE  # noqa: E402

Downloader = Callable[[str, "str | None"], object]


def register(subparsers) -> argparse.ArgumentParser:
    p = subparsers.add_parser("weights", help="pretrained weights for host workers")
    sub = p.add_subparsers(dest="weights_cmd", required=True)
    f = sub.add_parser("fetch", help="download every weights entry of the chosen models into the HF cache")
    f.add_argument("--models", default="all", help="comma-separated names (children included) or 'all'")
    f.add_argument("--models-root", action="append", help="extra folder of models")
    f.add_argument("--dry-run", action="store_true", help="list what would be fetched and what is already cached")
    f.set_defaults(func=cmd_fetch)
    return p


def _parse(spec: str) -> tuple[str, str | None]:
    repo, _, rev = spec.partition("@")
    return repo, (rev or None)


def model_weights(model_dir: Path) -> list[str]:
    """The top-level `weights` list of one model.toml (not `[config] weights`)."""
    meta = tomllib.loads((Path(model_dir) / "model.toml").read_text())
    ws = meta.get("weights", []) or []
    if not isinstance(ws, list) or not all(isinstance(w, str) for w in ws):
        raise ValueError(f"{model_dir}/model.toml: weights must be a list of 'org/name@rev' strings")
    bad = [w for w in ws if not WEIGHTS_RE.match(w)]
    if bad:
        raise ValueError(f"{model_dir}/model.toml: not a Hugging Face repo id[@rev]: {bad}")
    return ws


def tree_weights(names: Iterable[str], roots: list[Path]) -> dict[str, list[str]]:
    """{weights spec: [models (or children) that need it]}, over each named
    model and its whole child tree, in first-seen order."""
    from arena.registry import Registry
    reg = Registry(roots)
    out: dict[str, list[str]] = {}
    seen: set[Path] = set()

    def walk(info) -> None:
        if info.path in seen:
            return
        seen.add(info.path)
        for w in model_weights(info.path):
            out.setdefault(w, []).append(info.name)
        for c in info.children.values():
            walk(c)

    for n in names:
        walk(reg.load(n))
    return out


def cached(spec: str) -> bool:
    """Is `spec` already in a Hugging Face cache the workers look in?"""
    from kit.fm.weights import has_weights
    return has_weights(spec)


def hf_download(repo: str, revision: str | None) -> object:
    """The real downloader: `huggingface_hub.snapshot_download` into the
    standard cache. Imported here, online: `kit.fm.weights` sets the
    offline switches for scoring processes, not for this one."""
    for var in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE"):
        os.environ[var] = "0"
    try:
        from huggingface_hub import snapshot_download
    except ImportError as e:
        raise SystemExit("arena weights fetch needs huggingface_hub: `uv sync --extra fm`") from e
    return snapshot_download(repo_id=repo, revision=revision)


def fetch(specs: Iterable[str], *, download: Downloader = hf_download, is_cached: Callable[[str], bool] = cached,
          dry_run: bool = False, log=print) -> dict[str, str]:
    """Fetch each spec unless it is cached: {spec: 'cached' | 'fetched' |
    'would fetch' | 'failed: …'}."""
    out: dict[str, str] = {}
    for spec in specs:
        if is_cached(spec):
            out[spec] = "cached"
        elif dry_run:
            out[spec] = "would fetch"
        else:
            repo, rev = _parse(spec)
            try:
                download(repo, rev)
                out[spec] = "fetched"
            except Exception as e:      # one bad repo must not stop the rest
                out[spec] = f"failed: {type(e).__name__}: {str(e)[:200]}"
        log(f"  {spec}: {out[spec]}")
    return out


def cmd_fetch(a) -> int:
    from arena.cli import DEFAULT_MODELS, _all_models
    roots = [Path(r).resolve() for r in (a.models_root or [])] + [DEFAULT_MODELS]
    names = _all_models() if a.models == "all" else [m.strip() for m in a.models.split(",") if m.strip()]
    try:
        need = tree_weights(names, roots)
    except Exception as e:
        print(f"arena weights fetch: {e}", file=sys.stderr)
        return 2
    if not need:
        print("no weights to fetch")
        return 0
    print(f"{len(need)} weights for {len(names)} models{' (dry run)' if a.dry_run else ''}:")
    if not a.dry_run:
        for var in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE"):
            os.environ[var] = "0"
    res = fetch(need, download=hf_download, is_cached=cached, dry_run=a.dry_run)
    failed = [s for s, v in res.items() if v.startswith("failed")]
    return 1 if failed else 0
