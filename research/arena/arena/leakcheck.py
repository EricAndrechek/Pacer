"""Leak check: find what must not reach the public repo.

Generic rules are CI-safe (they need nothing but the files): home paths,
e-mail addresses, money figures, data files. Local rules read the runner's own
identifiers at check time (user name, full name, home path, git identity, the
Pacer store's accounts, project folder names, the account switcher's list) and
flag any tracked text that contains one. Those identifiers live only in memory
for the length of the run: never written anywhere, never printed unmasked.

Every finding is `file:line: rule (masked match)`.
"""
from __future__ import annotations

import getpass
import os
import re
import sqlite3
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

MAX_BYTES = 2 * 1024 * 1024
DEFAULT_PATHS = ("research/arena", ".github/workflows/arena.yml")

DATA_SUFFIX = re.compile(r"\.(parquet|duckdb|db|npz|npy)$|\.sqlite[^/]*$", re.I)

HOME_RE = re.compile(r"(?<![\w.])/(?:Users|home)/([^/\s'\"`)\]}>,;:]+)/")
HOME_OK = {"someone", "you", "<you>", "x", "runner", "shared"}
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})(?![\w-])")
EMAIL_OK = {"noreply@anthropic.com", "git@github.com"}
MONEY_RE = re.compile(r"\$\s?(\d{1,3}(?:,\d{3})+|\d+)(\.\d+)?([kKmMbB])?\b")
MULT = {"k": 1e3, "m": 1e6, "b": 1e9}

# The app's public identifiers: removed from a line before the local rules run.
PUBLIC_IDS = ("YZXWMJ5VBY.com.ericandrechek.pacer", "group.com.ericandrechek.pacer",
              "com.ericandrechek.pacer", "EricAndrechek/Pacer")

# Folder names too common to be an identifier.
GENERIC_NAMES = {"code", "projects", "project", "documents", "desktop", "downloads", "workspace", "workspaces",
                 "github", "gitlab", "source", "sources", "public", "private", "public-projects", "work",
                 "repos", "playground", "scratch", "sandbox", "temp", "tmp", "worktrees", "library",
                 "applications", "developer", "development", "software", "projects-public", "console"}
TEMP_PREFIXES = ("-private-var-", "-var-folders", "-tmp", "-private-tmp")


@dataclass(frozen=True)
class Finding:
    file: str
    line: int
    rule: str
    masked: str

    def __str__(self) -> str:
        return f"{self.file}:{self.line}: {self.rule} ({self.masked})"


def mask(s: str) -> str:
    """Enough to find it again, not enough to read it."""
    if len(s) <= 4:
        return s[:1] + "***"
    return s[:2] + "*" * min(len(s) - 3, 6) + s[-1]


# ------------------------------------------------------------ generic rules


def _is_text(data: bytes) -> bool:
    return b"\0" not in data[:8192]


def generic_line(line: str):
    """Yield (rule, matched-text) for one line."""
    for m in HOME_RE.finditer(line):
        name = m.group(1)
        if name.lower() in HOME_OK or name.startswith(("<", "$", "{", "~", "%")) or "*" in name:
            continue
        yield "home-path", name
    for m in EMAIL_RE.finditer(line):
        full, dom = m.group(0), m.group(1).lower()
        if full.lower() in EMAIL_OK or dom == "arena.invalid" or dom.endswith("arena.invalid"):
            continue
        if dom in ("example.com", "example.org") or dom.endswith((".example.com", ".example.org", ".example",
                                                                     ".test", ".invalid")):
            continue
        yield "email", full
    for m in MONEY_RE.finditer(line):
        try:
            v = float(m.group(1).replace(",", "") + (m.group(2) or ""))
        except ValueError:
            continue
        v *= MULT.get((m.group(3) or "").lower(), 1)
        if v >= 100:
            yield "money", m.group(0)


# -------------------------------------------------------------- local ids


def _run(cmd: list[str], cwd: Path | None = None) -> str:
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


def person_ids(repo: Path | None = None) -> dict[str, list[str]]:
    user = os.environ.get("USER") or ""
    try:
        user = user or getpass.getuser()
    except Exception:
        pass
    full = _run(["id", "-F"])
    if not full and user:
        gecos = _run(["getent", "passwd", user])
        full = gecos.split(":")[4].split(",")[0] if gecos.count(":") >= 4 else ""
    names = [user, full]
    names += [p for p in re.split(r"\s+", full) if len(p) >= 5]
    out = {
        "user-name": [n for n in names if n],
        "home-dir": [str(Path.home())],
        "git-identity": [v for v in (_run(["git", "config", "user.name"], repo),
                                     _run(["git", "config", "user.email"], repo)) if v],
    }
    return out


_ID_COLS = re.compile(r"EMAIL|^ZACCOUNTID$|^ZORGANI[SZ]ATIONID$|^ZORGID$", re.I)
_NOT_IDENT = re.compile(r"SUBSCRIPTION|TIER|PLAN|SOURCE|KIND|SLOT|ACTIVE|PCT|CENTS|AT$", re.I)
_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)


def store_ids(store_copy: Path) -> list[str]:
    """Account ids, org ids and e-mail addresses from a COPY of the store:
    every identifying text column of the Account table (id, org id, e-mail,
    display and organisation names), plus the e-mail / account-id / org-id
    columns of any other table."""
    out: set[str] = set()
    conn = sqlite3.connect(f"file:{store_copy}?mode=ro", uri=True)
    try:
        tables = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")]
        for t in tables:
            cols = [r[1] for r in conn.execute(f'PRAGMA table_info("{t}")')]
            is_account = t.upper() == "ZACCOUNT"
            pick = [c for c in cols if _ID_COLS.search(c)
                    or (is_account and not c.upper().startswith("Z_") and c.upper() != "Z_PK"
                        and not _NOT_IDENT.search(c))]
            for c in pick:
                try:
                    rows = conn.execute(f'SELECT DISTINCT "{c}" FROM "{t}" WHERE typeof("{c}")=\'text\' LIMIT 500')
                except sqlite3.Error:
                    continue
                for (v,) in rows:
                    v = (v or "").strip()
                    if 6 <= len(v) <= 100 and (_UUID.match(v) or not re.fullmatch(r"[\d.:/ -]+", v)):
                        out.add(v)
    finally:
        conn.close()
    return sorted(out)


def _decode_cwd(folder: str) -> Path | None:
    """Last path segment of a dash-encoded cwd (`-Users-a-Code-my-proj`).
    The encoding is lossy, so walk the real filesystem to find which dashes are
    separators. Only folders that still exist count: the tail of a deleted path
    is a guess."""
    toks = folder.lstrip("-").split("-")
    cur = Path("/")
    i = 0
    while i < len(toks):
        for j in range(len(toks), i, -1):
            cand = cur / "-".join(toks[i:j])
            if cand.exists():
                cur, i = cand, j
                break
        else:
            return None        # a path that is gone: its tail is a guess, and the guesses are common words
    return cur


def project_names(roots: list[Path], exclude_under: Path | None = None) -> list[str]:
    """Names of the user's project folders, minus anything inside the repo being
    checked (those are public by construction)."""
    out: set[str] = set()
    for root in roots:
        try:
            entries = sorted(p.name for p in Path(root).iterdir() if p.is_dir())
        except OSError:
            continue
        for e in entries:
            if "worktrees" in e or e.startswith(TEMP_PREFIXES):   # scratch checkouts, not projects
                continue
            path = _decode_cwd(e)
            name = path.name if path else None
            if path and exclude_under and (path == exclude_under or exclude_under in path.parents):
                continue
            if path and "arena-fleet" in path.parts:       # fleet agent workspaces: named for public models
                continue
            if name and len(name) >= 6 and name.lower() not in GENERIC_NAMES:
                out.add(name)
    return sorted(out)


def swap_emails(base: Path | None = None) -> list[str]:
    base = base or Path.home() / ".claude-swap-backup"
    out: set[str] = set()
    if not base.is_dir():
        return []
    for p in base.rglob("*.json"):
        try:
            if p.stat().st_size > 1 << 20 or len(p.relative_to(base).parts) > 3:
                continue
            for m in EMAIL_RE.finditer(p.read_text(errors="replace")):
                out.add(m.group(0))
        except OSError:
            continue
    return sorted(out)


def collect_local_ids(repo: Path | None = None, notes: list[str] | None = None) -> dict[str, list[str]]:
    """label -> identifiers. Nothing here is stored beyond the caller's variable."""
    notes = notes if notes is not None else []
    ids = person_ids(repo)
    try:
        from export import sources
        paths = sources.SourcePaths.default()
        copies = sources.make_copies(paths)
        try:
            ids["pacer-store"] = store_ids(copies.store)
        finally:
            copies.cleanup()
        roots = sources.default_transcript_roots()
    except (SystemExit, Exception) as e:     # no store on this machine: say so, carry on
        notes.append(f"pacer store not read ({type(e).__name__})")
        roots = [Path.home() / ".claude/projects"]
    tracked = {part for f in _run(["git", "ls-files", "-z"], repo).split("\0") for part in f.split("/")}
    ids["project-folder"] = [n for n in project_names(roots, repo) if n not in tracked]
    ids["swap-account"] = swap_emails()
    return {k: [x for x in v if x] for k, v in ids.items() if v}


class LocalMatcher:
    def __init__(self, ids: dict[str, list[str]]):
        self.label: dict[str, str] = {}
        for lab, toks in ids.items():
            for t in toks:
                t = t.strip()
                if len(t) >= 3:
                    self.label.setdefault(t.lower(), lab)
        toks = sorted(self.label, key=len, reverse=True)
        self.rx = (re.compile(r"(?<![A-Za-z0-9])(?:" + "|".join(re.escape(t) for t in toks) + r")(?![A-Za-z0-9])",
                              re.I) if toks else None)

    def scan(self, line: str):
        if not self.rx:
            return
        for pub in PUBLIC_IDS:
            line = re.sub(re.escape(pub), " " * len(pub), line, flags=re.I)
        for m in self.rx.finditer(line):
            yield "local:" + self.label[m.group(0).lower()], m.group(0)


# ------------------------------------------------------------------ scan


@dataclass
class Report:
    findings: list[Finding] = field(default_factory=list)
    scanned: int = 0
    notes: list[str] = field(default_factory=list)


def _toplevel(cwd: Path) -> Path:
    top = _run(["git", "rev-parse", "--show-toplevel"], cwd)
    if not top:
        raise SystemExit("arena leakcheck: not inside a git repository")
    return Path(top)


def _scan_text(name: str, text: str, local: LocalMatcher | None, out: list[Finding]) -> None:
    for n, line in enumerate(text.splitlines(), 1):
        for rule, hit in generic_line(line):
            out.append(Finding(name, n, rule, mask(hit)))
        if local:
            for rule, hit in local.scan(line):
                out.append(Finding(name, n, rule, mask(hit)))


def _check_data(name: str, size: int, out: list[Finding]) -> None:
    if DATA_SUFFIX.search(name):
        out.append(Finding(name, 0, "data-file", Path(name).suffix or Path(name).name))
    if size > MAX_BYTES:
        out.append(Finding(name, 0, "large-file", f"{size / 1048576:.1f} MiB"))


def scan(paths: list[str] | None = None, *, cwd: Path | None = None, staged: bool = False,
         commit_msg: Path | None = None, local: bool = True,
         local_ids: dict[str, list[str]] | None = None) -> Report:
    cwd = Path(cwd or os.getcwd()).resolve()
    top = _toplevel(cwd)
    rep = Report()
    matcher = None
    if local:
        ids = local_ids if local_ids is not None else collect_local_ids(top, rep.notes)
        matcher = LocalMatcher(ids)
    rel: list[str] = []
    for p in paths or []:
        ap = (cwd / p).resolve()
        rel.append(os.path.relpath(ap, top))
    if not paths and not staged and commit_msg is None:
        rel = list(DEFAULT_PATHS)

    if rel:
        listing = _run(["git", "ls-files", "-z", "--", *rel], top)
        for f in filter(None, listing.split("\0")):
            fp = top / f
            try:
                if not fp.is_file():
                    continue
                size = fp.stat().st_size
                _check_data(f, size, rep.findings)
                if size <= 20 * MAX_BYTES:
                    data = fp.read_bytes()
                    if _is_text(data):
                        _scan_text(f, data.decode("utf-8", "replace"), matcher, rep.findings)
            except OSError:
                continue
            rep.scanned += 1

    if staged:
        names = _run(["git", "diff", "--cached", "--name-only", "--diff-filter=ACM", "-z"], top)
        for f in filter(None, names.split("\0")):
            if rel and not any(f == r or f.startswith(r.rstrip("/") + "/") for r in rel):
                continue
            blob = subprocess.run(["git", "show", f":{f}"], capture_output=True, cwd=top).stdout
            _check_data(f, len(blob), rep.findings)
            if _is_text(blob):
                _scan_text(f + " (staged)", blob.decode("utf-8", "replace"), matcher, rep.findings)
            rep.scanned += 1

    if commit_msg is not None:
        text = Path(commit_msg).read_text(errors="replace")
        text = "\n".join("" if ln.startswith("#") else ln for ln in text.splitlines())
        _scan_text(str(commit_msg), text, matcher, rep.findings)
        rep.scanned += 1

    rep.findings = sorted(set(rep.findings), key=lambda f: (f.file, f.line, f.rule, f.masked))
    return rep


def main(argv: list[str] | None = None) -> int:
    import argparse
    p = argparse.ArgumentParser(prog="arena leakcheck")
    add_args(p)
    return run(p.parse_args(argv))


def add_args(p) -> None:
    p.add_argument("paths", nargs="*", help="tracked paths to scan (default: research/arena and .github/workflows/arena.yml)")
    p.add_argument("--staged", action="store_true", help="scan the staged content")
    p.add_argument("--commit-msg", metavar="FILE", help="scan a commit message file")
    p.add_argument("--no-local", action="store_true",
                   help="generic rules only (CI): skip the runner's own identifiers")


def run(a) -> int:
    rep = scan(a.paths, staged=a.staged, commit_msg=Path(a.commit_msg) if a.commit_msg else None,
               local=not a.no_local)
    for n in rep.notes:
        print(f"leakcheck: note: {n}", file=sys.stderr)
    for f in rep.findings:
        print(f)
    mode = "generic" if a.no_local else "generic+local"
    print(f"leakcheck ({mode}): {len(rep.findings)} finding(s) in {rep.scanned} file(s)", file=sys.stderr)
    return 1 if rep.findings else 0


if __name__ == "__main__":
    sys.exit(main())
