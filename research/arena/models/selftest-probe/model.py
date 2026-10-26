"""Self-test adversary (`arena selftest`). It forecasts a constant 0 (so its
scores must equal selftest-constant's), and alongside tries, from inside its
worker, every way to reach the future or the hidden data, logging one JSON
`PROBE {...}` the harness reads. A field that is non-empty on a path where it
must be empty is a leak.

What it tries, grouped by `found` key:
- `env`          ARENA_* variables beyond the two the launcher sets, and any
                 environment value or the parent command line holding the
                 self-test's marker;
- `files`        ARENA_HOME, the snapshots dir, the cache, the results DB and
                 the given host paths, read directly; plus a shallow walk for
                 snapshot-shaped or marker-bearing files (container only);
- `proc`         /proc/self/environ, the parent's environ and cmdline (Linux);
- `objects`      SnapshotData / TierIndex / holdout frames reachable through
                 gc, module globals or the call stack;
- `buffers`      a value hidden under a null slot of any served table — the
                 masked columns read straight from Arrow (output before its
                 upgrade, an activation's or session's end, a price's end, an
                 imputed output), via history.arrow() and table().to_arrow();
- `after_now`    any served row with t_known > now, or a `_`-prefixed column;
- `net`          a reachable host;
- `scratch`      a value this model wrote to ctx.scratch in a past episode
                 (state must never cross episodes);
- `future_reads` meter readings in the current cycle at times after now that
                 the truth will be scored on (the clearest "saw the future").
Only booleans / counts / the marker leave the worker; never a real datum."""
from __future__ import annotations

import gc
import json
import os
import socket
import sys
from pathlib import Path

import numpy as np
import pyarrow as pa
import pyarrow.compute as pc
import polars as pl

from arena.types import Forecast, Target, TargetForecast

SNAP_SUFFIX = (".parquet", "manifest.json", ".duckdb")
SKIP = {"/proc", "/sys", "/dev", "/usr", "/lib", "/lib64", "/bin", "/sbin", "/etc",
        "/var/lib", "/opt/arena-src", "/run"}


def _hidden_under_nulls(a: pa.Array) -> bool:
    if a.null_count == 0 or len(a) == 0 or a.buffers()[1] is None:
        return False
    t = a.type
    nulls = ~np.asarray(pc.is_valid(a))
    if pa.types.is_temporal(t) or pa.types.is_integer(t) or pa.types.is_floating(t):
        w = t.bit_width // 8
        raw = np.frombuffer(a.buffers()[1], np.uint8)[a.offset * w:(a.offset + len(a)) * w]
        return bool(raw.reshape(len(a), w)[nulls].any())
    if pa.types.is_string(t) or pa.types.is_large_string(t):
        odt = np.int64 if pa.types.is_large_string(t) else np.int32
        offs = np.frombuffer(a.buffers()[1], odt)[a.offset:a.offset + len(a) + 1]
        return bool((np.diff(offs)[nulls] != 0).any())
    return False


class Model:
    def __init__(self, ctx):
        self.ctx = ctx
        self.cfg = ctx.config
        self.marker = str(self.cfg.get("marker", ""))

    def fit(self, history):
        self.history = history
        found = {"env": [], "files": [], "proc": [], "objects": [], "buffers": [],
                 "after_now": [], "net": [], "scratch": [], "future_reads": 0,
                 "walked": 0, "now": history.now}
        self._env(found)
        self._files(found)
        self._proc(found)
        self._objects(found)
        self._buffers(found, history)
        self._after_now(found, history)
        self._net(found)
        self._scratch(found)
        self.ctx.log("PROBE " + json.dumps(found))

    def update(self, events):
        self.history = self.history.extend(events)

    def forecast(self, request):
        found = {"future_reads": self._future_reads(request)}
        self.ctx.log("PROBE_FC " + json.dumps(found))
        out = {}
        for tr in request.targets:
            if tr.target is Target.CYCLE_NEXT_START:
                out[tr.key] = TargetForecast(np.full((1, len(tr.grid)), np.nan))
            else:
                out[tr.key] = TargetForecast.point(np.zeros(len(tr.grid)))
        return Forecast(out)

    # -- probes ---------------------------------------------------------
    def _env(self, found):
        found["env"] = sorted(k for k in os.environ
                              if k.startswith("ARENA") and k not in ("ARENA_WORKER", "ARENA_WORKER_SCRATCH"))
        if self.marker and self.marker != "NOMARKER":
            found["env"] += [f"value:{k}" for k, v in os.environ.items() if self.marker in str(v)]
        try:
            if self.marker in Path("/proc/self/cmdline").read_text():
                found["env"].append("cmdline")
        except OSError:
            pass

    def _try(self, p: str) -> bool:
        try:
            P = Path(p)
            if P.is_dir():
                return any(P.iterdir())
            if P.is_file():
                P.read_bytes()
                return True
        except OSError:
            return False
        return False

    def _files(self, found):
        cands = list(self.cfg.get("paths", [])) + [
            os.environ.get("ARENA_HOME", ""), "/arena-home",
            str(Path(os.environ.get("ARENA_HOME", "/nope")) / "snapshots"),
            str(Path(os.environ.get("ARENA_HOME", "/nope")) / "cache"),
            str(Path(os.environ.get("ARENA_HOME", "/nope")) / "results" / "arena.duckdb")]
        found["files"] = [p for p in cands if p and self._try(p)]
        # A shallow filesystem walk, in a container only (ARENA_WORKER_SCRATCH
        # is the Docker launcher's signal; on a host this would crawl the Mac).
        if os.environ.get("ARENA_WORKER_SCRATCH"):
            for root, dirs, files in os.walk("/"):
                dirs[:] = [d for d in dirs if os.path.join(root, d) not in SKIP]
                found["walked"] += 1
                for f in files:
                    if f.endswith(SNAP_SUFFIX) or (self.marker and self.marker in f):
                        found["files"].append(os.path.join(root, f))
                if len(found["files"]) >= 5 or found["walked"] > 4000:
                    break

    def _proc(self, found):
        for name in ("/proc/self/environ",):
            try:
                if self.marker and self.marker in Path(name).read_text(errors="ignore"):
                    found["proc"].append(name)
            except OSError:
                pass
        try:
            ppid = os.getppid()
            for name in (f"/proc/{ppid}/environ", f"/proc/{ppid}/cmdline"):
                txt = Path(name).read_text(errors="ignore")
                if ("ARENA_HOME" in txt) or (self.marker and self.marker in txt):
                    found["proc"].append(name)
        except OSError:
            pass

    def _objects(self, found):
        wanted = ("SnapshotData", "TierIndex", "EpisodeView", "Runner")
        try:
            for o in gc.get_objects():
                n = type(o).__name__
                if n in wanted:
                    found["objects"].append(n)
                    if len(found["objects"]) > 8:
                        break
        except Exception:  # noqa: BLE001
            pass
        for mod in list(sys.modules.values()):
            for attr in ("holdout", "_holdout", "SNAPSHOT", "_data"):
                # A lazy module's __getattr__ can raise anything (an in-process
                # worker shares the process with torch, jaxtyping, …): a probe
                # that crashes reports nothing, which reads as a pass.
                try:
                    hit = hasattr(mod, attr)
                except Exception:  # noqa: BLE001
                    continue
                if hit:
                    found["objects"].append(f"{getattr(mod, '__name__', '?')}.{attr}")
        f = sys._getframe()
        depth = 0
        while f and depth < 40:
            for v in f.f_locals.values():
                if type(v).__name__ in wanted:
                    found["objects"].append("frame:" + type(v).__name__)
            f = f.f_back
            depth += 1

    def _buffers(self, found, history):
        for name in history.tables:
            for src in (history.arrow(name), history.table(name).to_arrow()):
                for c in src.column_names:
                    col = src[c]
                    chunks = col.chunks if isinstance(col, pa.ChunkedArray) else [col]
                    if any(_hidden_under_nulls(ch) for ch in chunks):
                        found["buffers"].append(f"{name}.{c}")
        found["buffers"] = sorted(set(found["buffers"]))

    def _after_now(self, found, history):
        for name in history.tables:
            df = history.table(name)
            if any(c.startswith("_") for c in df.columns):
                found["after_now"].append(f"{name}:internal_col")
            if df.height and df["t_known"].dt.epoch("ms").max() > history.now:
                found["after_now"].append(f"{name}:t_known")

    def _net(self, found):
        for host, port in (("1.1.1.1", 53), ("8.8.8.8", 443), ("pypi.org", 443),
                           ("host.docker.internal", 80)):
            try:
                socket.create_connection((host, port), timeout=2).close()
                found["net"].append(host)
            except OSError:
                pass

    def _scratch(self, found):
        try:
            f = Path(self.ctx.scratch) / "carried.txt"
            if f.is_file():
                found["scratch"].append(f.read_text()[:40])
            f.write_text(f"episode@{self.history.now}")
        except OSError:
            pass

    def _future_reads(self, request) -> int:
        """Readings of a requested meter cycle whose t_event is after now: a
        model that keeps to the as-of rule can't see any."""
        n = 0
        rd = self.history.table("meter_readings")
        if not rd.height:
            return 0
        te = rd["t_event"].dt.epoch("ms")
        for tr in request.targets:
            if tr.target in (Target.METER_5H, Target.METER_7D, Target.METER_SCOPED):
                n += int(rd.filter(te > request.now).height > 0)
        return n
