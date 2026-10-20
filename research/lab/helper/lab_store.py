"""Read Pacer's live store, read-only, the way the app's engine does.

The store is the app's SwiftData SQLite file. It is opened with
`mode=ro` (never `immutable=1`, which would ignore the WAL and read stale or
torn pages), one short connection per load, so the app's checkpoints are never
held up for long.

Series, per (window, account):
  fixed windows (`five_hour`, `seven_day`): ZRATELIMITSAMPLE, plus the
    account's ZACCOUNTUSAGEARCHIVE rows of kind 'rate_limit' (the live table is
    a 35-day cache; older rows move to the archive, never deleted);
  scoped windows (any other key, a `limits[]` identity): ZUSAGELIMITSAMPLE,
    plus archive rows of kind 'usage_limit'.
Mirrors `research/harness/pacer_replay.py`'s `rate_samples_by_account` and
the app's `RawLimitReader`: live and archive merged on the sample instant, the
live copy winning; with no account, every account's live rows and no archive
(the app reads the archive per account only).

Loaded once (every account's fixed windows at startup, `preload`: a cold load
of a busy 5-hour series is ~1 s, most of the app's live budget), then topped up
with newer live rows on each request, and reloaded in full every
`full_reload_s`, in the background, to pick up anything unusual (an archive
move of a row this cache never saw live, a backfilled timestamp).
"""
from __future__ import annotations

import bisect
import logging
import sqlite3
import threading
import time
from pathlib import Path
from urllib.parse import quote

from lab_history import Reading

CORE_DATA_EPOCH = 978307200.0  # 2001-01-01 → unix
DEFAULT_STORE = Path.home() / "Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer/pacer.sqlite"
FIXED_WINDOWS = {"five_hour": 5 * 3600.0, "seven_day": 7 * 86400.0}

log = logging.getLogger("lab.store")


class Series:
    """An immutable snapshot of one series. A top-up builds a new one, so a
    request slicing a snapshot never sees it change under it."""
    __slots__ = ("readings", "times", "max_live_raw", "topped_at", "loaded_at")

    def __init__(self, readings, max_live_raw: float | None, loaded_at: float | None = None):
        self.readings: tuple[Reading, ...] = tuple(readings)
        self.times: tuple[float, ...] = tuple(r.t for r in self.readings)
        self.max_live_raw = max_live_raw
        self.topped_at = time.monotonic()
        self.loaded_at = self.topped_at if loaded_at is None else loaded_at

    def until(self, t_cut: float) -> tuple[Reading, ...]:
        """A copy of every reading at or before `t_cut`."""
        return self.readings[: bisect.bisect_right(self.times, t_cut)]


class Store:
    def __init__(self, path: Path = DEFAULT_STORE, top_up_s: float = 5.0, full_reload_s: float = 900.0):
        self.path = Path(path)
        self.top_up_s = top_up_s
        self.full_reload_s = full_reload_s
        self._lock = threading.Lock()
        self._series: dict[tuple[str, str | None], Series] = {}
        self._reloading: set[tuple[str, str | None]] = set()

    def _connect(self) -> sqlite3.Connection:
        if not self.path.exists():
            raise FileNotFoundError(f"store not found: {self.path}")
        conn = sqlite3.connect(f"file:{quote(str(self.path))}?mode=ro", uri=True, timeout=5,
                               check_same_thread=False)
        conn.execute("PRAGMA query_only = 1")
        return conn

    @staticmethod
    def _tables(conn) -> set[str]:
        return {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}

    @staticmethod
    def _cols(conn, table: str) -> set[str]:
        return {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}

    # -- queries ----------------------------------------------------------------

    @staticmethod
    def _live_sql(window: str) -> tuple[str, str, str, str]:
        """(table, pct column, key column, key value) of a window's live rows."""
        if window in FIXED_WINDOWS:
            return "ZRATELIMITSAMPLE", "ZUSEDPERCENTAGE", "ZWINDOW", window
        return "ZUSAGELIMITSAMPLE", "ZPERCENT", "ZIDENTITY", window

    def _live_rows(self, conn, window: str, account: str | None, after_raw: float | None):
        table, pct, key_col, key = self._live_sql(window)
        if table not in self._tables(conn):
            return []
        cols = self._cols(conn, table)
        if not {"ZSAMPLEDAT", pct, key_col, "ZRESETSAT"} <= cols:
            return []
        sql = f"SELECT ZSAMPLEDAT, {pct}, ZRESETSAT FROM {table} WHERE {key_col} = ? AND ZRESETSAT IS NOT NULL"
        args: list = [key]
        if account and "ZACCOUNTID" in cols:
            sql += " AND ZACCOUNTID = ?"
            args.append(account)
        if after_raw is not None:
            sql += " AND ZSAMPLEDAT > ?"
            args.append(after_raw)
        sql += " ORDER BY ZSAMPLEDAT"
        return conn.execute(sql, args).fetchall()

    def _archive_rows(self, conn, window: str, account: str | None):
        if not account or "ZACCOUNTUSAGEARCHIVE" not in self._tables(conn):
            return []
        fixed = window in FIXED_WINDOWS
        kind, key_col = ("rate_limit", "ZWINDOW") if fixed else ("usage_limit", "ZIDENTITY")
        return conn.execute(
            f"SELECT ZSAMPLEDAT, ZUSEDPERCENTAGE, ZRESETSAT FROM ZACCOUNTUSAGEARCHIVE "
            f"WHERE ZKIND = ? AND {key_col} = ? AND ZACCOUNTID = ? "
            f"AND ZRESETSAT IS NOT NULL AND ZUSEDPERCENTAGE IS NOT NULL",
            (kind, window, account)).fetchall()

    @staticmethod
    def _readings(*row_sets) -> list[Reading]:
        merged: dict[float, Reading] = {}
        for rows in row_sets:              # later sets win: pass the live rows last
            for at, pct, reset in rows:
                if pct is None or reset is None:
                    continue
                t = at + CORE_DATA_EPOCH
                merged[round(t, 3)] = Reading(t, float(pct), reset + CORE_DATA_EPOCH)
        return sorted(merged.values())

    # -- the cache --------------------------------------------------------------

    def series(self, window: str, account: str | None) -> Series:
        key = (window, account or None)
        now = time.monotonic()
        with self._lock:
            s = self._series.get(key)
            if s is None:
                s = self._load(window, account)
                self._series[key] = s
                return s
            if now - s.loaded_at > self.full_reload_s and key not in self._reloading:
                self._reloading.add(key)
                threading.Thread(target=self._reload, args=(key,), daemon=True).start()
            if now - s.topped_at > self.top_up_s:
                s = self._top_up(s, window, account)
                self._series[key] = s
            return s

    def _reload(self, key: tuple[str, str | None]) -> None:
        """A full reload off the request path; the old snapshot serves meanwhile."""
        try:
            s = self._load(*key)
            with self._lock:
                self._series[key] = s
        except Exception:  # noqa: BLE001 — keep serving the snapshot we have
            log.exception("background reload of %s failed", key)
        finally:
            with self._lock:
                self._reloading.discard(key)

    def preload(self) -> None:
        """Load every account's fixed windows, so the app's first live request
        doesn't pay for a cold read."""
        try:
            conn = self._connect()
            try:
                if "ZRATELIMITSAMPLE" not in self._tables(conn):
                    return
                pairs = conn.execute("SELECT DISTINCT ZWINDOW, ZACCOUNTID FROM ZRATELIMITSAMPLE "
                                     "WHERE ZRESETSAT IS NOT NULL").fetchall()
            finally:
                conn.close()
            for window, account in pairs:
                if window in FIXED_WINDOWS and account:
                    self.series(window, account)
        except Exception:  # noqa: BLE001
            log.exception("preload failed")

    def _load(self, window: str, account: str | None) -> Series:
        started = time.monotonic()
        conn = self._connect()
        try:
            live = self._live_rows(conn, window, account, None)
            archived = self._archive_rows(conn, window, account)
        finally:
            conn.close()
        s = Series(self._readings(archived, live), max((r[0] for r in live), default=None))
        log.info("loaded %s/%s: %d readings (%d live, %d archived) in %.0f ms", window,
                 (account or "all")[-4:], len(s.readings), len(live), len(archived),
                 (time.monotonic() - started) * 1000)
        return s

    def _top_up(self, s: Series, window: str, account: str | None) -> Series:
        conn = self._connect()
        try:
            rows = self._live_rows(conn, window, account, s.max_live_raw)
        finally:
            conn.close()
        if not rows:
            s.topped_at = time.monotonic()
            return s
        last = s.times[-1] if s.times else float("-inf")
        newer = [r for r in self._readings(rows) if r.t > last]
        return Series(s.readings + tuple(newer), max(s.max_live_raw or rows[-1][0], rows[-1][0]),
                      loaded_at=s.loaded_at)
