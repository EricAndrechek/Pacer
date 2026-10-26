"""Where the exporter's inputs live, how they are copied, and their
fingerprints.

The live store is never opened. Every database is cloned into a private
temp dir first (`cp -c`, an APFS clone: no extra disk, each file captured at
one instant while the app keeps writing), with its WAL/SHM sidecars, and the
clones are deleted when the export ends. Transcripts are read in place,
read-only, and never copied.
"""
from __future__ import annotations

import hashlib
import os
import shutil
import sqlite3
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

GROUP_DIR = Path.home() / "Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer"
DESKTOP_AGENT_DIR = Path.home() / "Library/Application Support/Claude/local-agent-mode-sessions"
DESKTOP_SESSIONS_DIR = Path.home() / "Library/Application Support/Claude/claude-code-sessions"
REPO_RESEARCH = Path(__file__).resolve().parents[2]          # research/
REPO_ROOT = REPO_RESEARCH.parent
PRICE_CANDIDATE = REPO_RESEARCH / "price-history/candidate-price-history.json"
PRICE_CURATED = REPO_ROOT / "PacerCore/Sources/PacerCore/Resources/price-history.json"


@dataclass
class SourcePaths:
    """Originals. Tests point these at fixtures."""

    store: Path
    archive: Path | None
    transcript_roots: list[Path]
    history_jsonl: Path | None
    cswap_log: Path | None
    rotate_log: Path | None
    price_candidate: Path | None
    price_curated: Path | None
    desktop_sessions: Path | None = None

    @classmethod
    def default(cls, store: Path | None = None) -> "SourcePaths":
        if store is None:
            hits = sorted(GROUP_DIR.rglob("pacer.sqlite")) if GROUP_DIR.exists() else []
            if not hits:
                raise SystemExit(f"no pacer.sqlite under {GROUP_DIR}; pass --store")
            store = hits[0]
        archive = store.parent / "raw-archive.duckdb"
        roots = default_transcript_roots()
        home = Path.home()
        opt = lambda p: p if p.exists() else None
        return cls(
            store=store,
            archive=opt(archive),
            transcript_roots=roots,
            history_jsonl=opt(home / ".claude/history.jsonl"),
            cswap_log=opt(home / ".claude-swap-backup/claude-swap.log"),
            rotate_log=opt(home / ".local/state/pacer-account-rotation/state/rotate.log"),
            price_candidate=opt(PRICE_CANDIDATE),
            price_curated=opt(PRICE_CURATED),
            desktop_sessions=opt(DESKTOP_SESSIONS_DIR),
        )


def default_transcript_roots() -> list[Path]:
    """The roots Pacer itself scans: `CLAUDE_CONFIG_DIR` exclusively when set
    (correctness rule 4), else both `~/.claude` and `~/.config/claude`; plus
    Claude Desktop's agent-mode (Cowork) roots, which Pacer reads since 10-21."""
    roots: list[Path] = []
    env = os.environ.get("CLAUDE_CONFIG_DIR")
    if env:
        for part in env.split(","):
            p = Path(part.strip()).expanduser() / "projects"
            if p.is_dir():
                roots.append(p)
    else:
        for base in (Path.home() / ".claude", Path.home() / ".config/claude"):
            p = base / "projects"
            if p.is_dir():
                roots.append(p)
    if DESKTOP_AGENT_DIR.is_dir():
        roots.extend(sorted(DESKTOP_AGENT_DIR.glob("*/*/*/.claude/projects")))
    return roots


def list_transcripts(roots: list[Path]) -> list[Path]:
    """Every `.jsonl` under the roots, symlinks not followed (symlinked
    project dirs would double the file count), hidden dirs below a root
    skipped, sorted so every later stage sees the same order."""
    out: set[Path] = set()
    for root in roots:
        root = Path(root)
        for dp, dns, fns in os.walk(root, followlinks=False):
            rel = os.path.relpath(dp, root)
            dns[:] = [d for d in dns if not d.startswith(".")]
            if rel != "." and any(part.startswith(".") for part in Path(rel).parts):
                continue
            for f in fns:
                if f.endswith(".jsonl") and not f.startswith("."):
                    out.add(Path(dp) / f)
    return sorted(out, key=lambda p: str(p).encode())


def _clone(src: Path, dst: Path) -> None:
    if subprocess.run(["cp", "-c", str(src), str(dst)], capture_output=True).returncode != 0:
        shutil.copy2(src, dst)


@dataclass
class Copies:
    """Private clones of the databases, removed by `cleanup`."""

    workdir: Path
    store: Path
    archive: Path | None
    _cleaned: bool = field(default=False, repr=False)

    def cleanup(self) -> None:
        if not self._cleaned:
            shutil.rmtree(self.workdir, ignore_errors=True)
            self._cleaned = True


def make_copies(paths: SourcePaths) -> Copies:
    work = Path(tempfile.mkdtemp(prefix="arena-export-src-"))
    try:
        store = work / paths.store.name
        for suffix in ("", "-wal", "-shm"):
            src = Path(str(paths.store) + suffix)
            if src.exists():
                _clone(src, Path(str(store) + suffix))
        archive = None
        if paths.archive is not None and paths.archive.exists():
            archive = work / paths.archive.name
            for suffix in ("", ".wal"):
                src = Path(str(paths.archive) + suffix)
                if src.exists():
                    _clone(src, Path(str(archive) + suffix))
        return Copies(work, store, archive)
    except BaseException:
        shutil.rmtree(work, ignore_errors=True)
        raise


def open_store(copy: Path) -> sqlite3.Connection:
    """Read-only connection to a copy (never to the original)."""
    return sqlite3.connect(f"file:{copy}?mode=ro", uri=True)


def _sha256_file(p: Path | None) -> str | None:
    if p is None or not p.exists():
        return None
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


STORE_TABLES = ("ZTOKENSAMPLE", "ZRATELIMITSAMPLE", "ZUSAGELIMITSAMPLE", "ZACCOUNTUSAGEARCHIVE",
                "ZACCOUNTACTIVATION", "ZPREDICTIONSNAPSHOT", "ZENGINEEVALOUTCOME",
                "ZSPENDMETERFIT", "ZPRICERECORD", "ACHANGE", "ATRANSACTION")


def fingerprints(paths: SourcePaths, copies: Copies, transcripts: list[Path]) -> dict:
    """What the snapshot was built from, without anything identifying: sizes,
    counts, max primary keys, max times, and hashes of the price files."""
    conn = open_store(copies.store)
    try:
        have = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        max_pk = {}
        for t in STORE_TABLES:
            if t in have:
                max_pk[t] = conn.execute(f"SELECT MAX(Z_PK), COUNT(*) FROM {t}").fetchone()
        max_tx = None
        if "ATRANSACTION" in have:
            v = conn.execute("SELECT MAX(ZTIMESTAMP) FROM ATRANSACTION").fetchone()[0]
            max_tx = None if v is None else int(round((v + 978307200.0) * 1000))
    finally:
        conn.close()
    store_bytes = sum(Path(str(copies.store) + s).stat().st_size
                      for s in ("", "-wal") if Path(str(copies.store) + s).exists())
    t_bytes, t_mtime = 0, 0
    for p in transcripts:
        try:
            st = p.stat()
        except OSError:
            continue
        t_bytes += st.st_size
        t_mtime = max(t_mtime, int(st.st_mtime * 1000))
    return {
        "store": {"bytes": store_bytes,
                  "max_pk": {t: v[0] for t, v in max_pk.items()},
                  "rows": {t: v[1] for t, v in max_pk.items()},
                  "max_transaction_ms": max_tx},
        "archive_bytes": (sum(Path(str(copies.archive) + s).stat().st_size
                              for s in ("", ".wal") if Path(str(copies.archive) + s).exists())
                          if copies.archive else None),
        "transcripts": {"files": len(transcripts), "bytes": t_bytes, "max_mtime_ms": t_mtime,
                        "roots": len(paths.transcript_roots)},
        "price_candidate_sha256": _sha256_file(paths.price_candidate),
        "price_curated_sha256": _sha256_file(paths.price_curated),
    }
