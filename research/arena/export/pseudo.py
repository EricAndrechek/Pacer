"""Pseudonymization (spec §2.4).

- The salt is 32 random bytes at `ARENA_HOME/salt`, mode 0600, created on
  first use and never copied anywhere: not into a snapshot, not into git.
  A manifest carries only `salt_id = sha256(salt)[:8]`.
- Every id that could identify a person, a machine or a project (session ids,
  message/request ids, project paths, agent ids, file names) becomes
  HMAC-SHA256(salt, kind || 0x00 || value) truncated to its first 64 bits.
  The `kind` namespace keeps a session id and an agent id that happen to be
  equal from hashing to the same value.
- Accounts become `A1..An` in first-seen order.
"""
from __future__ import annotations

import hashlib
import hmac
import os
import secrets
import stat
from pathlib import Path

import numpy as np
import pyarrow as pa

SALT_BYTES = 32


def load_or_create_salt(home: Path) -> bytes:
    """The salt at `home/salt`; created (0600, exclusive) when missing. A salt
    of the wrong size or with group/other permissions is refused rather than
    silently fixed: either means something else wrote it."""
    path = Path(home) / "salt"
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.write(fd, secrets.token_bytes(SALT_BYTES))
        finally:
            os.close(fd)
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        raise PermissionError(f"salt file is readable by others (mode {mode:o}); expected 0600")
    data = path.read_bytes()
    if len(data) != SALT_BYTES:
        raise ValueError(f"salt must be {SALT_BYTES} bytes, found {len(data)}")
    return data


def salt_id(salt: bytes) -> str:
    return hashlib.sha256(salt).hexdigest()[:8]


class Hasher:
    """Salted 64-bit hashes, memoized (a session id recurs thousands of times)."""

    def __init__(self, salt: bytes):
        if len(salt) != SALT_BYTES:
            raise ValueError("salt must be 32 bytes")
        self._salt = salt
        self._memo: dict[tuple[str, str], int] = {}

    def h(self, kind: str, value: str | None) -> int | None:
        if value is None:
            return None
        key = (kind, value)
        got = self._memo.get(key)
        if got is None:
            mac = hmac.new(self._salt, kind.encode() + b"\x00" + value.encode(), hashlib.sha256).digest()
            got = int.from_bytes(mac[:8], "big")
            self._memo[key] = got
        return got

    def array(self, kind: str, values) -> pa.Array:
        """uint64 array of hashes; None stays null."""
        return pa.array([self.h(kind, v) for v in values], type=pa.uint64())

    def numpy(self, kind: str, values) -> np.ndarray:
        """uint64 numpy array; None maps to 0 (callers mask nulls themselves)."""
        return np.fromiter((self.h(kind, v) or 0 for v in values), dtype=np.uint64)


def label_accounts(first_seen: dict[str, int], hasher: Hasher) -> dict[str, str]:
    """Real account id -> "A1".. by first-seen time; equal times are broken by
    the salted hash, never by the raw id (whose order would say something)."""
    order = sorted(first_seen, key=lambda a: (first_seen[a], hasher.h("account", a)))
    return {a: f"A{i + 1}" for i, a in enumerate(order)}
