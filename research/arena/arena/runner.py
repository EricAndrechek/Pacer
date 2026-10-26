"""The runner: the trusted side. It holds the episode's data, runs each model
in its own worker, streams what became known, asks for forecasts, builds the
truth from data the model never saw, and scores.

Per (model, episode):

1. a fresh worker (a subprocess speaking arena/protocol.py, or a thread over
   pipes in in-process debug mode) — a model never carries state from one
   episode into an overlapping one;
2. `fit` with the as-of history at the cutoff; then, per checkpoint, `update`
   with the rows that became known since the last one and `forecast` for the
   remaining horizon;
3. every forecast is validated (keys, shapes `[n_paths, len(grid)]`, finite,
   n_paths >= 1) and scored against `Truth` by `arena.scoring.score_checkpoint`.

**The as-of guarantee is asserted here, at the protocol layer:** every table
in every fit/update message is a data table, has no internal column, and holds
no row with `t_known` later than the message's `now` (`assert_as_of`). A
violation is a harness bug and stops the run.

**Children.** `child_request` / `backtest_request` are served by running the
child in its own worker, fitted afresh at the parent's `now` on exactly the
parent's view. That makes a child's answer a function of (child hash,
snapshot, view, now, request), which is the cache key (`arena/cache.py`). The
parent's deadline covers its children.

**Failures** (timeouts, model errors, invalid forecasts, crashes) become
`failures` rows; a timeout or crash ends that model's episode, an error in
update or forecast skips one checkpoint.

**How a worker starts** (`worker_command`). By default `python -m
arena.worker` with this interpreter. A configured command
(`RunConfig.worker_cmd`, `--worker-cmd`, or `$ARENA_WORKER_CMD`: a JSON list or
a shell-quoted string) replaces it for every worker, children included, and
must speak the protocol on stdin/stdout. The hidden-tier scorer uses it to run
each worker in its own Docker container with no data mounted and no network
(fleet/evalgate.py), so a model cannot read what the runner holds even by
opening files. Placeholders in its arguments: `{id}` (unique per worker, safe
as a container name), `{model_dir}`, `{scratch}`. `worker_kill_cmd`
(`$ARENA_WORKER_KILL_CMD`, same forms, `{id}`) runs when a worker is killed,
e.g. `docker kill {id}`: killing the client process alone can leave a
container running.
"""
from __future__ import annotations

import hashlib
import json
import os
import queue
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import warnings
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Callable

import numpy as np
import pyarrow as pa
import pyarrow.compute as pc

import arena
from arena.cache import ChildCache, cache_key, request_hash
from arena.episodes import (
    HOUR_MS, METER_TARGETS, Episode, SamplerConfig, TargetSpec, TierIndex, build_request, grid_for,
    hourly_specs, longrun_episodes, meter_specs, next_start_spec, sample_episodes, specs_at,
)
from arena.protocol import PROTOCOL_VERSION, Message, read_message, write_message
from arena.registry import MAX_DEPTH, ModelInfo, Registry, RegistryError
from arena.snapshot.schema import DATA_TABLES
from arena.snapshot.views import EpisodeView, SnapshotData
from arena.types import (
    Forecast, Millis, Request, ScoreRow, Target, TargetForecast, TargetRequest, TargetTruth, Truth,
)
from arena.worker import (
    MAX_ERROR, WorkerLoop, decode_forecast, decode_request, encode_forecast, encode_request,
)

Scorer = Callable[[Request, Forecast, Truth], list[ScoreRow]]
FAR = 2 ** 62


class LeakError(AssertionError):
    """The harness was about to hand a worker something it must not see."""


class WorkerTimeout(Exception):
    pass


class WorkerCrash(Exception):
    pass


class ChildFailure(Exception):
    pass


def invalid_forecast_error() -> type[BaseException]:
    """The scorer's `InvalidForecast` (NaN/inf in a path; recorded as
    failures.kind = 'invalid_forecast'), or a stand-in nothing raises."""
    try:
        from arena.scoring import InvalidForecast  # type: ignore[attr-defined]
        return InvalidForecast
    except ImportError:
        class _NeverRaised(Exception):
            pass
        return _NeverRaised


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

@dataclass
class Timeouts:
    start: float = 120.0
    fit: float = 900.0
    update: float = 300.0
    forecast: float = 300.0


@dataclass
class RunConfig:
    tier: str = "visible"
    episodes: int = 20
    seed: int = 0
    targets: tuple[str, ...] | None = None    # None: every target the models declare
    mode: str = "current_code"
    in_process: bool = False
    timeouts: Timeouts = field(default_factory=Timeouts)
    checkpoint_cap: int = 24
    n_paths: int = 200
    longrun: bool = False
    longrun_every: int = HOUR_MS
    keep_logs: bool = True
    archive: str = "none"                     # none | quantiles | paths
    cache: bool = True
    max_backtest_points: int = 48
    max_paths_factor: int = 10
    kind: str = "test"
    requested_by: str | None = None
    threads: int | None = None                # BLAS/OMP/Polars threads in each worker
    worker_cmd: tuple[str, ...] | None = None        # None: $ARENA_WORKER_CMD, else python -m arena.worker
    worker_kill_cmd: tuple[str, ...] | None = None   # None: $ARENA_WORKER_KILL_CMD, else nothing
    # Per top-level model (by hash): (command, kill command) for its workers
    # and its children's, e.g. each model's own Docker env (`arena run
    # --docker`). Overrides worker_cmd for that model's tree.
    worker_cmds: dict[str, tuple[tuple[str, ...], tuple[str, ...] | None]] | None = None
    scrub: bool = True                               # empty null slots before serving; False only for
                                                     # arena selftest's "a leak is caught" control
    jobs: int = 1                                    # (model, episode) units run at once, each in its
                                                     # own job process; results identical for any N


def derive_seed(*parts) -> int:
    h = hashlib.sha256(json.dumps([str(p) for p in parts]).encode()).hexdigest()
    return int(h[:15], 16)


def harness_version() -> str:
    sha = "nogit"
    try:
        out = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=Path(__file__).parent,
                             capture_output=True, text=True, timeout=5)
        if out.returncode == 0:
            sha = out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return f"{arena.__version__}+{sha}"


# ---------------------------------------------------------------------------
# The as-of assertion
# ---------------------------------------------------------------------------

def assert_as_of(tables: dict[str, pa.Table], now: Millis, *, check_nulls: bool = True) -> None:
    for name, t in tables.items():
        if name not in DATA_TABLES:
            raise LeakError(f"{name!r} is not a data table")
        hidden = [c for c in t.column_names if c.startswith("_")]
        if hidden:
            raise LeakError(f"{name}: internal columns {hidden}")
        if t.num_rows:
            tk = pc.max(t.column("t_known").cast(pa.int64())).as_py()
            if tk is not None and tk > now:
                raise LeakError(f"{name}: a row known at {tk} reached a worker at now={now}")
        # `check_nulls` is off only for arena selftest's "a leak is caught"
        # control, which deliberately serves unscrubbed tables.
        if check_nulls:
            for col in t.column_names:
                if any(_hidden_under_nulls(ch) for ch in t.column(col).chunks):
                    raise LeakError(f"{name}.{col}: a null slot carries a value (see scrub_nulls)")


# ---------------------------------------------------------------------------
# Null slots carry nothing
#
# The views hide a value that is not yet known by making it null
# (`_apply_masks`: e.g. when the current account activation ends, when the
# session in progress ends, a price's end before its successor is known, an
# imputed output before its evidence). A null is only a validity bit: polars'
# when/then leaves the hidden value in the column's value buffer under it, and
# Arrow IPC ships the buffer whole, so a worker reading `arr.buffers()` read
# the future (found by `arena selftest`'s internals probe, on the Docker path
# too). Every table bound for a worker is rebuilt so null slots hold zeros or
# empty strings, and `assert_as_of` refuses one that doesn't.
# ---------------------------------------------------------------------------

def _null_fill(t: pa.DataType):
    if pa.types.is_boolean(t):
        return False
    if pa.types.is_string(t) or pa.types.is_large_string(t):
        return ""
    if pa.types.is_binary(t) or pa.types.is_large_binary(t):
        return b""
    if pa.types.is_integer(t) or pa.types.is_floating(t) or pa.types.is_temporal(t):
        return 0
    return None                       # anything else: rebuilt from Python values


def _hidden_under_nulls(a: pa.Array) -> bool:
    """Does any null slot of `a` hold a value? Only the layouts the schema
    uses are read; any other type with nulls counts as unclean unless it is
    all nulls of a rebuilt array (scrub_nulls never sends one)."""
    if a.null_count == 0 or len(a) == 0:
        return False
    t = a.type
    nulls = ~np.asarray(pc.is_valid(a))
    bufs = a.buffers()
    if bufs[1] is None:
        return False
    if pa.types.is_boolean(t):
        bits = np.unpackbits(np.frombuffer(bufs[1], np.uint8), bitorder="little")[a.offset:a.offset + len(a)]
        return bool(bits[nulls].any())
    if pa.types.is_string(t) or pa.types.is_binary(t) or pa.types.is_large_string(t) or pa.types.is_large_binary(t):
        odt = np.int64 if (pa.types.is_large_string(t) or pa.types.is_large_binary(t)) else np.int32
        offs = np.frombuffer(bufs[1], odt)[a.offset:a.offset + len(a) + 1]
        return bool((np.diff(offs)[nulls] != 0).any())
    if pa.types.is_integer(t) or pa.types.is_floating(t) or pa.types.is_temporal(t):
        width = t.bit_width // 8
        raw = np.frombuffer(bufs[1], np.uint8)[a.offset * width:(a.offset + len(a)) * width]
        return bool(raw.reshape(len(a), width)[nulls].any())
    return True


def _scrub_chunk(a: pa.Array) -> pa.Array:
    if a.null_count == 0 or not _hidden_under_nulls(a):
        return a
    fill = _null_fill(a.type)
    if fill is not None:
        filled = pc.fill_null(a, pa.scalar(fill, type=a.type))
        if filled.offset == 0:
            bufs = list(filled.buffers())
            bufs[0] = pc.is_valid(a).buffers()[1]     # a fresh validity bitmap, offset 0
            out = pa.Array.from_buffers(a.type, len(a), bufs, null_count=a.null_count)
            if not _hidden_under_nulls(out):
                return out
    return pa.array(a.to_pylist(), type=a.type)       # the slow, always-clean way


def scrub_nulls(table: pa.Table) -> pa.Table:
    """`table` with every null slot emptied (see above)."""
    cols = []
    for col in table.columns:
        cols.append(pa.chunked_array([_scrub_chunk(ch) for ch in col.chunks], type=col.type))
    return pa.Table.from_arrays(cols, schema=table.schema)


def served(frames: dict) -> dict[str, pa.Table]:
    """What a worker is sent: each view frame as Arrow, null slots emptied."""
    return {n: scrub_nulls(df.to_arrow()) for n, df in frames.items()}


# ---------------------------------------------------------------------------
# Workers
# ---------------------------------------------------------------------------

DEFAULT_WORKER_CMD = ("{python}", "-m", "arena.worker")
# What a worker command (e.g. the docker CLI) may need from the runner's
# environment to reach its daemon. Never handed to a default worker.
LAUNCHER_ENV = ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG", "DOCKER_CERT_PATH", "DOCKER_TLS_VERIFY")


def parse_command(value: str | list | tuple | None) -> tuple[str, ...] | None:
    """A command from a JSON list or a shell-quoted string (None/empty: none)."""
    if value is None:
        return None
    if isinstance(value, (list, tuple)):
        out = tuple(str(v) for v in value)
    else:
        text = value.strip()
        if not text:
            return None
        if text.startswith("["):
            parsed = json.loads(text)
            if not isinstance(parsed, list) or not all(isinstance(v, str) for v in parsed):
                raise ValueError("a worker command in JSON must be a list of strings")
            out = tuple(parsed)
        else:
            out = tuple(shlex.split(text))
    return out or None


def worker_command(cfg: "RunConfig") -> tuple[tuple[str, ...], tuple[str, ...] | None, bool]:
    """(command, kill command, custom?) for this run's workers."""
    cmd = cfg.worker_cmd or parse_command(os.environ.get("ARENA_WORKER_CMD"))
    kill = cfg.worker_kill_cmd or parse_command(os.environ.get("ARENA_WORKER_KILL_CMD"))
    if cmd is None:
        return DEFAULT_WORKER_CMD, kill, False
    return cmd, kill, True


def _fill(cmd: tuple[str, ...], **values: str) -> list[str]:
    out = []
    for arg in cmd:
        for k, v in values.items():
            arg = arg.replace("{" + k + "}", v)
        out.append(arg)
    return out


def worker_env(scratch: Path, threads: int | None) -> dict[str, str]:
    """A small, explicit environment: nothing of the runner's (no ARENA_HOME,
    no tokens), deterministic hashing, no bytecode written into model folders."""
    env = {k: os.environ[k] for k in ("PATH", "LANG", "LC_ALL", "TZ", "SYSTEMROOT") if k in os.environ}
    env.update(PYTHONHASHSEED="0", PYTHONDONTWRITEBYTECODE="1", ARENA_WORKER="1",
               HOME=str(scratch), TMPDIR=str(scratch))
    if threads:
        for k in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS",
                  "NUMEXPR_NUM_THREADS", "POLARS_MAX_THREADS"):
            env[k] = str(threads)
    return env


class WorkerHandle:
    """One model process (or debug thread) speaking the protocol. A reader
    thread drains its output into a queue so every wait has a deadline."""

    def __init__(self, info: ModelInfo, *, in_process: bool, scratch: Path, role: str,
                 threads: int | None = None, own_scratch: bool = False,
                 command: tuple[str, ...] = DEFAULT_WORKER_CMD, kill_command: tuple[str, ...] | None = None,
                 custom: bool = False):
        self.info, self.role, self.scratch, self.in_process = info, role, scratch, in_process
        self.own_scratch = own_scratch
        self.q: queue.Queue = queue.Queue()
        self.proc = None
        self._err = None
        self.id = f"w{os.getpid()}-{secrets.token_hex(6)}"
        self._kill_cmd = _fill(kill_command, id=self.id) if kill_command else None
        self._killed = False
        if in_process:
            r1, w1 = os.pipe()
            r2, w2 = os.pipe()
            self._w = os.fdopen(w1, "wb")
            self._r = os.fdopen(r2, "rb")
            win, wout = os.fdopen(r1, "rb"), os.fdopen(w2, "wb")
            self._thread = threading.Thread(target=self._loop, args=(win, wout), daemon=True,
                                            name=f"arena-worker-{role}")
            self._thread.start()
        else:
            self._err = open(scratch / "stderr.log", "wb")
            argv = _fill(command, python=sys.executable, id=self.id, model_dir=str(info.path),
                         scratch=str(scratch))
            env = worker_env(scratch, threads)
            if custom:
                env.update({k: os.environ[k] for k in LAUNCHER_ENV if k in os.environ})
            self.proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                         stderr=self._err, cwd=scratch, env=env)
            self._w, self._r = self.proc.stdin, self.proc.stdout
        self._reader = threading.Thread(target=self._read, daemon=True, name=f"arena-reader-{role}")
        self._reader.start()

    @staticmethod
    def _loop(win, wout):
        try:
            WorkerLoop(win, wout).run()
        except BaseException:  # noqa: BLE001 - surfaces as EOF to the runner
            pass
        finally:
            for f in (wout, win):
                try:
                    f.close()
                except OSError:
                    pass

    def _read(self):
        while True:
            try:
                self.q.put(read_message(self._r))
            except BaseException as e:  # noqa: BLE001
                self.q.put(WorkerCrash(f"worker output ended: {type(e).__name__}: {e}"))
                try:
                    self._r.close()
                except OSError:
                    pass
                return

    def send(self, msg: Message, deadline: float) -> None:
        err: list[BaseException] = []

        def go():
            try:
                write_message(self._w, msg)
            except BaseException as e:  # noqa: BLE001
                err.append(e)
        t = threading.Thread(target=go, daemon=True)
        t.start()
        t.join(max(0.0, deadline - time.monotonic()))
        if t.is_alive():
            self.kill()
            raise WorkerTimeout(f"sending {msg.type}")
        if err:
            raise WorkerCrash(f"sending {msg.type}: {type(err[0]).__name__}: {err[0]}{self.stderr_tail()}")

    def recv(self, deadline: float) -> Message:
        try:
            item = self.q.get(timeout=max(0.0, deadline - time.monotonic())) if deadline > time.monotonic() \
                else self.q.get_nowait()
        except queue.Empty:
            raise WorkerTimeout("no reply before the deadline") from None
        if isinstance(item, WorkerCrash):
            raise WorkerCrash(f"{item}{self.stderr_tail()}")
        return item

    def stderr_tail(self, n: int = 1500) -> str:
        if self._err is None:
            return ""
        try:
            self._err.flush()
            data = (self.scratch / "stderr.log").read_bytes()[-n:]
        except OSError:
            return ""
        return ("\n--- worker stderr ---\n" + data.decode(errors="replace")) if data.strip() else ""

    def kill(self) -> None:
        if self.proc is not None and self.proc.poll() is None:
            self.proc.kill()
            self._run_kill_cmd()
        for f in (self._w,):
            try:
                f.close()
            except OSError:
                pass

    def _run_kill_cmd(self) -> None:
        """A launcher killed is not always its worker gone (`docker run`'s
        client vs its container): the configured kill command finishes it."""
        if not self._kill_cmd or self._killed:
            return
        self._killed = True
        try:
            subprocess.run(self._kill_cmd, capture_output=True, timeout=60,
                           env={**worker_env(self.scratch, None),
                                **{k: os.environ[k] for k in LAUNCHER_ENV if k in os.environ}})
        except (OSError, subprocess.SubprocessError):
            pass

    def close(self) -> None:
        try:
            write_message(self._w, Message("shutdown"))
        except BaseException:  # noqa: BLE001
            pass
        if self.proc is not None:
            try:
                self.proc.wait(timeout=10 if self._kill_cmd else 5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self._run_kill_cmd()
                self.proc.wait(timeout=5)
        self.kill()
        if self._err is not None:
            self._err.close()
        if self.own_scratch:
            shutil.rmtree(self.scratch, ignore_errors=True)


@dataclass
class CallCtx:
    """Who is calling and at which moment: what a child request is served
    against. Children get exactly this view at exactly this `now`."""

    info: ModelInfo
    view: EpisodeView
    now: Millis
    depth: int
    role: str
    pool: dict = field(default_factory=dict)       # child name -> (worker, ctx) fitted at `now`
    root: ModelInfo | None = None                  # the top-level model whose unit this is (worker command)


# ---------------------------------------------------------------------------
# Forecast validation and truth
# ---------------------------------------------------------------------------

def validate_forecast(req: Request, fc: Forecast, max_factor: int = 10) -> tuple[Forecast, list[str]]:
    """Keep each key whose forecast is well formed; name the problem with
    each one that isn't."""
    ok, problems = {}, []
    for tr in req.targets:
        tf = fc.by_key.get(tr.key)
        if tf is None:
            problems.append(f"{tr.key}: missing")
            continue
        p = np.asarray(tf.paths)
        if p.dtype.kind not in "fiu":
            problems.append(f"{tr.key}: paths dtype {p.dtype}")
            continue
        p = p.astype(np.float64)
        if p.ndim != 2 or p.shape[1] != len(tr.grid):
            problems.append(f"{tr.key}: paths shape {p.shape}, want [n_paths, {len(tr.grid)}]")
            continue
        if not 1 <= p.shape[0] <= max(1, max_factor * tr.n_paths):
            problems.append(f"{tr.key}: {p.shape[0]} paths")
            continue
        bad = ~np.isfinite(p)
        if tr.target is Target.CYCLE_NEXT_START:
            bad = np.isinf(p)                         # NaN = no start before the horizon
        if bad.any():
            problems.append(f"{tr.key}: {int(bad.sum())} non-finite values")
            continue
        extras = {}
        for name, v in (tf.extras or {}).items():
            a = np.asarray(v)
            if a.dtype.kind not in "fiu" or a.ndim > 1 or a.size > max(1, max_factor * tr.n_paths):
                problems.append(f"{tr.key}: extra {name!r} malformed")
                continue
            a = a.astype(np.float64)
            if name == "p_hit_limit" and not (a.ndim == 0 and 0.0 <= float(a) <= 1.0):
                problems.append(f"{tr.key}: p_hit_limit must be a probability")
                continue
            if np.isinf(a).any():
                problems.append(f"{tr.key}: extra {name!r} infinite")
                continue
            extras[name] = float(a) if a.ndim == 0 else a
        ok[tr.key] = TargetForecast(p, extras)
    return Forecast(ok), problems


def build_truth(index: TierIndex, spec: TargetSpec, now: Millis, grid: np.ndarray) -> TargetTruth | None:
    """What happened after `now` for one key, from data the model never saw.
    Meters: the cycle's own readings, never interpolated, stopping at reset.
    Hourly: realised values over each grid hour, priced with final rates.
    Next start: the first turn on the account after the idle stretch began."""
    t = spec.target
    if t in METER_TARGETS:
        m = index.meter(spec.accounts[0], t, spec.cap)
        if m is None:
            return None
        times, values = m.truth(now, spec.horizon_end, spec.reset_at)
        hit = values >= 100.0
        ttl = float(times[hit][0]) if hit.any() else float("nan")
        complete = len(times) > 0 and times[-1] >= spec.reset_at - max(15 * 60_000, 0.05 * m.duration)
        return TargetTruth(times=times.astype(np.int64), values=values.astype(np.float64),
                           horizon_end=spec.reset_at, reset_at=spec.reset_at,
                           hit_limit=bool(hit.any()) if (hit.any() or complete) else None,
                           time_to_limit=ttl)
    if t is Target.CYCLE_NEXT_START:
        s = index.first_turn_after(spec.accounts[0], spec.idle_since)
        ns = float(s) if s is not None and s <= spec.horizon_end else float("nan")
        return TargetTruth(times=np.array([spec.horizon_end], np.int64), values=np.array([ns]),
                           horizon_end=spec.horizon_end, next_start=ns)
    g = np.asarray(grid, dtype=np.int64)
    if t is Target.SPEND_HOURLY:
        v = index.hourly(spec.accounts, g, "spend")
    elif t is Target.TOKENS_HOURLY:
        v = index.hourly(spec.accounts, g, "tokens", spec.family)
    elif t is Target.SPLIT:
        num = index.hourly(spec.accounts, g, "spend")
        # Sum per account, so an account alone in the group is exactly 1
        # (one cumulative sum over the whole group rounds differently).
        den = sum(index.hourly((a,), g, "spend") for a in (spec.group or spec.accounts))
        with np.errstate(divide="ignore", invalid="ignore"):
            v = np.where(den > 0, num / den, np.nan)
    else:
        return None
    keep = np.isfinite(v)
    return TargetTruth(times=g[keep], values=v[keep], horizon_end=spec.horizon_end)


def fallback_score_checkpoint(request: Request, forecast: Forecast, truth: Truth) -> list[ScoreRow]:
    """Used only when `arena.scoring` is not installed (the core built alone):
    ensemble CRPS and the middle path's absolute error, each forecast path read
    at the truth times by linear interpolation of the grid."""
    rows = []
    for tr in request.targets:
        tt = truth.by_key.get(tr.key)
        tf = forecast.by_key.get(tr.key)
        if tt is None or tf is None or len(tt.times) == 0:
            continue
        P = np.asarray(tf.paths, dtype=np.float64)
        if tr.target is Target.CYCLE_NEXT_START:
            started = ~np.isnan(P[:, 0])
            y = 0.0 if np.isnan(tt.next_start) else 1.0
            rows.append(ScoreRow(tr.key, str(tr.target), "brier_start", None, float((started.mean() - y) ** 2)))
            continue
        g = tr.grid.astype(np.float64)
        X = np.stack([np.interp(tt.times.astype(np.float64), g, p) for p in P])     # [n, T]
        y = tt.values
        crps = np.abs(X - y).mean(axis=0) - 0.5 * np.abs(X[:, None, :] - X[None, :, :]).mean(axis=(0, 1))
        rows.append(ScoreRow(tr.key, str(tr.target), "crps", None, float(crps.mean())))
        rows.append(ScoreRow(tr.key, str(tr.target), "ae_point", None, float(np.abs(np.median(X, axis=0) - y).mean())))
    return rows


def default_scorer() -> tuple[Scorer, bool]:
    """(score_checkpoint, is_fallback)."""
    try:
        from arena.scoring import score_checkpoint  # type: ignore[attr-defined]
        return score_checkpoint, False
    except ModuleNotFoundError as e:
        if e.name not in ("arena.scoring",):
            raise
        return fallback_score_checkpoint, True


# ---------------------------------------------------------------------------
# Per-episode batches (shared by every model in a run)
# ---------------------------------------------------------------------------

class EpisodeBatches:
    def __init__(self, runner: "Runner", ep: Episode):
        self.r, self.ep = runner, ep
        self.view = runner.data.view(ep.scope, ep.mode, ep.history_start)
        self._fit: dict | None = None
        self._events: dict[int, dict] = {}
        self._specs: dict[int, list[TargetSpec]] = {}
        self._truth: dict[tuple[int, str], TargetTruth | None] = {}
        self._hist: dict[Millis, dict] = {}

    def _serve(self, frames: dict) -> dict[str, pa.Table]:
        return served(frames) if self.r.cfg.scrub else {n: df.to_arrow() for n, df in frames.items()}

    def history(self, now: Millis) -> dict[str, pa.Table]:
        if now not in self._hist:
            if self._hist:                     # one moment at a time beside the cutoff's (memory)
                self._hist.pop(next(iter(self._hist)))
            self._hist[now] = self._serve(self.view.history(now))
        return self._hist[now]

    def fit_tables(self) -> dict[str, pa.Table]:
        if self._fit is None:
            self._fit = self._serve(self.view.history(self.ep.cutoff))
        return self._fit

    def events(self, i: int) -> dict[str, pa.Table]:
        if i not in self._events:
            cp = self.ep.checkpoints
            self._events[i] = self._serve(self.view.events(cp[i - 1], cp[i]))
        return self._events[i]

    def specs(self, i: int) -> list[TargetSpec]:
        if i not in self._specs:
            self._specs[i] = specs_at(self.ep, self.ep.checkpoints[i], self.r.index, self.r.sampler)
        return self._specs[i]

    def request(self, i: int, targets: set[str] | None) -> Request:
        return build_request(self.ep.scope, self.ep.checkpoints[i], self.specs(i), self.r.cfg.n_paths, targets)

    def truth(self, i: int, tr: TargetRequest) -> TargetTruth | None:
        k = (i, tr.key)
        if k not in self._truth:
            spec = next((s for s in self.specs(i) if s.key == tr.key), None)
            self._truth[k] = None if spec is None else build_truth(self.r.index, spec, self.ep.checkpoints[i], tr.grid)
        return self._truth[k]


# ---------------------------------------------------------------------------
# The runner
# ---------------------------------------------------------------------------

@dataclass
class RunOutcome:
    run_id: str
    episodes: list[Episode]
    scores: list[dict] = field(default_factory=list)
    failures: list[dict] = field(default_factory=list)
    logs: list[dict] = field(default_factory=list)
    forecasts: list[dict] = field(default_factory=list)
    fallback_scoring: bool = False
    timings: list[dict] = field(default_factory=list)   # per (model, episode): wall seconds of its unit


class Runner:
    def __init__(self, data: SnapshotData, cfg: RunConfig, *, scorer: Scorer | None = None,
                 cache: ChildCache | None = None, results=None, index: TierIndex | None = None,
                 say: Callable[[str], None] | None = None):
        self.data, self.cfg = data, cfg
        self.index = index or TierIndex(data)
        self._default_scorer = scorer is None
        if scorer is None:
            scorer, self.fallback = default_scorer()
        else:
            self.fallback = False
        self.scorer = scorer
        self.invalid = invalid_forecast_error()
        self.cache = cache if cache is not None else ChildCache(enabled=cfg.cache)
        self.results = results
        self.say = say or (lambda s: None)
        self.tap: Callable[[str, Message], None] | None = None   # tests: sees every message sent
        # Self-test only (arena/selftest.py): hashes of models handed the
        # truth with each forecast request (`_with_oracle`). Never set from a
        # config, a flag or the environment.
        self.oracle_for: set[str] = set()
        self.sampler = SamplerConfig(episodes=cfg.episodes, seed=cfg.seed, mode=cfg.mode,
                                     checkpoint_cap=cfg.checkpoint_cap, n_paths=cfg.n_paths,
                                     longrun_every=cfg.longrun_every)
        self._id = 0
        self._verified: set[str] = set()
        self._spawned = 0
        self.worker_cmd, self.worker_kill_cmd, self.custom_worker = worker_command(cfg)
        if (self.custom_worker or cfg.worker_cmds) and cfg.in_process:
            raise ValueError("a worker command needs subprocess workers (in_process=False)")

    # episodes ----------------------------------------------------------
    def episodes(self, models: list[ModelInfo]) -> list[Episode]:
        targets = self.cfg.targets
        if targets is None:
            declared = {t for m in models for t in (m.targets or ())}
            targets = tuple(str(t) for t in Target if (not declared or str(t) in declared))
        self.sampler.targets = tuple(targets)
        if self.cfg.longrun:
            return longrun_episodes(self.index, self.sampler)
        return sample_episodes(self.index, self.sampler)

    # run ---------------------------------------------------------------
    def run(self, models: list[ModelInfo], episodes: list[Episode] | None = None) -> RunOutcome:
        """Every model on every episode. The work is (model, episode) units,
        each self-contained (a fresh worker, a seed from the run seed and the
        episode); with `cfg.jobs` > 1 they run in that many job processes and
        their rows are merged back in (episode, model) order, so the outcome
        is the same for any number of jobs."""
        episodes = self.episodes(models) if episodes is None else episodes
        out = RunOutcome(uuid.uuid4().hex[:16], episodes, fallback_scoring=self.fallback)
        if self.results is not None:
            self.results.start_run(out.run_id, kind=self.cfg.kind, tier=self.data.tier.name,
                                   snapshot_id=self.data.snapshot_id, seed=self.cfg.seed,
                                   harness_version=harness_version(), mode=self.cfg.mode,
                                   requested_by=self.cfg.requested_by)
            for m in models:
                self.results.register_model(m)
            self.results.add_episodes(out.run_id, episodes)
        units = [(ei, mi) for ei in range(len(episodes)) for mi in range(len(models))]

        def merge(unit: tuple[int, int], res: "UnitResult") -> None:
            out.scores += res.scores
            out.failures += res.failures
            out.logs += res.logs
            out.forecasts += res.forecasts
            if res.ran:
                out.timings.append({"model": models[unit[1]].name, "model_hash": models[unit[1]].hash,
                                    "episode_id": episodes[unit[0]].episode_id, "seconds": res.seconds})
            if self.results is not None:
                self.results.add_scores(res.scores)
                self.results.add_failures(res.failures)
            if res.ran:
                self.say(f"{models[unit[1]].name} episode {episodes[unit[0]].episode_id}: "
                         f"{res.seconds:.1f}s, {len(res.scores)} scores, {len(res.failures)} failures")

        if self.cfg.jobs <= 1 or len(units) <= 1:
            for ei, ep in enumerate(episodes):
                eb = EpisodeBatches(self, ep)
                for mi, m in enumerate(models):
                    merge((ei, mi), self.run_unit(out.run_id, m, ep, eb))
        else:
            self._run_parallel(out.run_id, models, episodes, units, merge)
        if self.results is not None:
            if self.cfg.archive != "none":
                for m in models:
                    self.results.write_forecasts(out.run_id, m.hash,
                                                 [f for f in out.forecasts if f["model_hash"] == m.hash])
            self.results.finish_run(out.run_id)
        return out

    def _fail(self, out: RunOutcome, info: ModelInfo, ep: Episode, t: Millis | None, kind: str, msg: str):
        out.failures.append({"run_id": out.run_id, "episode_id": ep.episode_id, "model_hash": info.hash,
                             "model": info.name, "checkpoint_t": t, "kind": kind,
                             "message": str(msg)[:MAX_ERROR]})

    def run_unit(self, run_id: str, info: ModelInfo, ep: Episode, eb: "EpisodeBatches") -> "UnitResult":
        """One model on one episode: everything it adds to the outcome."""
        sub = RunOutcome(run_id, [ep], fallback_scoring=self.fallback)
        t0 = time.monotonic()
        ran = self._run_one(info, ep, eb, sub)
        return UnitResult(sub.scores, sub.failures, sub.logs, sub.forecasts, time.monotonic() - t0, ran)

    def _run_parallel(self, run_id, models, episodes, units, merge) -> None:
        """Units in `cfg.jobs` job processes (spawned: each loads the tier
        from disk once and keeps the batches of its last episodes). Rows
        come back as plain lists and are merged in unit order."""
        import concurrent.futures as cf
        import multiprocessing as mp
        if self.data.root is None:
            raise ValueError("--jobs needs a snapshot loaded from disk (SnapshotData.load / from_dir)")
        spec = _JobSpec(str(self.data.root), self.data.snapshot_id, self.data.tier.name, self.cfg,
                        str(self.cache.root), bool(self.cache.enabled), list(models), list(episodes),
                        set(self.oracle_for), None if self._default_scorer else self.scorer,
                        getattr(self.data, "after", None))
        done: dict[tuple[int, int], UnitResult] = {}
        nxt = 0
        with cf.ProcessPoolExecutor(max_workers=min(self.cfg.jobs, len(units)), mp_context=mp.get_context("spawn"),
                                    initializer=_job_init, initargs=(spec,)) as pool:
            futs = {pool.submit(_job_unit, run_id, ei, mi): (ei, mi) for ei, mi in units}
            try:
                for f in cf.as_completed(futs):
                    done[futs[f]] = f.result()
                    while nxt < len(units) and units[nxt] in done:
                        merge(units[nxt], done.pop(units[nxt]))
                        nxt += 1
            except BaseException:
                for f in futs:
                    f.cancel()
                raise

    def _run_one(self, info: ModelInfo, ep: Episode, eb: EpisodeBatches, out: RunOutcome) -> bool:
        targets = set(info.targets) if info.targets else None
        cps = ep.checkpoints
        if not ep.longrun and targets is not None and not any(str(s.target) in targets for s in ep.targets):
            return False
        to = self.cfg.timeouts
        scratch = Path(tempfile.mkdtemp(prefix="arena-w-"))
        w = None
        now = ep.cutoff
        logs: list[str] = []
        ctx = CallCtx(info, eb.view, ep.cutoff, 0, "model", root=info)
        # Scored once the worker is gone, never between its calls: scoring
        # reads the truth, and its run time (how many future readings there
        # are) would otherwise show in the gap before the next update — a
        # clock a model can read (`arena selftest`, timing probe).
        to_score: list[tuple[int, Request, Forecast]] = []
        try:
            seed = derive_seed(self.cfg.seed, ep.episode_id)
            w = self._spawn(info, seed, scratch, "model", time.monotonic() + to.start, logs, root=info)
            r = self._call(w, ctx, "fit", {"now": ep.cutoff, "scope": _scope(ep.scope), "mode": ep.mode,
                                           "start": ep.history_start,
                                           "tz_offset_min": self.index.tz_offset_at(ep.cutoff)},
                           eb.fit_tables(), {}, time.monotonic() + to.fit, logs, eb)
            if r.type == "error":
                self._fail(out, info, ep, ep.cutoff, "error", f"fit: {r.header.get('message')}")
                return True
            for i, now in enumerate(cps):
                ctx.now = now
                if i > 0:
                    r = self._call(w, ctx, "update", {"since": cps[i - 1], "until": now,
                                                      "tz_offset_min": self.index.tz_offset_at(now)},
                                   eb.events(i), {}, time.monotonic() + to.update, logs, eb)
                    if r.type == "error":
                        self._fail(out, info, ep, now, "error", f"update: {r.header.get('message')}")
                req = eb.request(i, targets)
                if not req.targets:
                    continue
                head, arrays = encode_request(req)
                if info.hash in self.oracle_for:
                    head, arrays = self._with_oracle(eb, i, req, head, arrays)
                r = self._call(w, ctx, "forecast", {"request": head}, None, arrays,
                               time.monotonic() + to.forecast, logs, eb)
                if r.type == "error":
                    self._fail(out, info, ep, now, "error", f"forecast: {r.header.get('message')}")
                    continue
                fc, problems = validate_forecast(req, decode_forecast(r.header.get("forecast", {}), r.arrays),
                                                 self.cfg.max_paths_factor)
                for p in problems:
                    self._fail(out, info, ep, now, "invalid_forecast", p)
                to_score.append((i, req, fc))
                if self.cfg.archive != "none":
                    self._archive(out, info, ep, req, fc)
        except WorkerTimeout as e:
            if w is not None:
                w.kill()                       # stuck: don't wait for it to finish
            self._fail(out, info, ep, now, "timeout", str(e))
        except WorkerCrash as e:
            self._fail(out, info, ep, now, "crash", str(e))
        finally:
            if w is not None:
                w.close()
            shutil.rmtree(scratch, ignore_errors=True)
            for i, req, fc in to_score:
                self._score(out, info, ep, eb, i, req, fc)
            if logs and self.cfg.keep_logs:
                out.logs += [{"model": info.name, "episode_id": ep.episode_id, "message": m} for m in logs]
        return True

    def _with_oracle(self, eb: "EpisodeBatches", i: int, req: Request, head: dict,
                     arrays: dict) -> tuple[dict, dict]:
        """Self-test only: the forecast message also carries the truth the
        checkpoint will be scored against (`ctx.oracle` in the worker), so
        `arena selftest` can check that a model handed the future scores
        perfectly. Sent only to models whose hash is in `oracle_for`, which
        only trusted Python in the runner's own process can set: no RunConfig
        field, command-line flag, environment variable or model.toml reaches
        it, and a worker has no way to ask for it."""
        meta, extra = {}, {}
        for tr in req.targets:
            tt = eb.truth(i, tr)
            if tt is None:
                continue
            meta[tr.key] = {"horizon_end": int(tt.horizon_end), "reset_at": tt.reset_at,
                            "hit_limit": tt.hit_limit, "time_to_limit": float(tt.time_to_limit),
                            "next_start": float(tt.next_start)}
            extra[f"oracle_t:{tr.key}"] = np.asarray(tt.times, np.int64)
            extra[f"oracle_v:{tr.key}"] = np.asarray(tt.values, np.float64)
        return {**head, "oracle": meta}, {**arrays, **extra}

    def _score(self, out, info, ep, eb, i, req, fc) -> None:
        truths, keep = {}, []
        for tr in req.targets:
            if tr.key not in fc.by_key:
                continue
            tt = eb.truth(i, tr)
            if tt is None or len(tt.times) == 0:
                continue
            truths[tr.key] = tt
            keep.append(tr)
        if not keep:
            return
        t = ep.checkpoints[i]
        try:
            rows = self.scorer(replace(req, targets=tuple(keep)), Forecast({k: fc.by_key[k] for k in truths}),
                               Truth(truths))
        except self.invalid as e:
            self._fail(out, info, ep, t, "invalid_forecast", f"scoring: {e}")
            return
        for s in rows:
            out.scores.append({"run_id": out.run_id, "episode_id": ep.episode_id, "model_hash": info.hash,
                               "model": info.name, "checkpoint_t": t, "target_key": s.target_key,
                               "target": s.target, "metric": s.metric, "lead_s": s.lead_s, "value": s.value})

    def _archive(self, out, info, ep, req, fc) -> None:
        levels = np.array([0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 0.95])
        for tr in req.targets:
            tf = fc.by_key.get(tr.key)
            if tf is None:
                continue
            if self.cfg.archive == "paths":
                data = tf.paths
            else:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", RuntimeWarning)     # all-NaN next-start columns
                    data = np.nanquantile(tf.paths, levels, axis=0)
            out.forecasts.append({"model_hash": info.hash, "episode_id": ep.episode_id, "checkpoint_t": req.now,
                                  "target_key": tr.key, "grid": tr.grid.tolist(),
                                  "kind": self.cfg.archive, "values": np.asarray(data, np.float32).tolist()})

    # protocol ------------------------------------------------------------
    def _command_for(self, root: ModelInfo | None) -> tuple[tuple[str, ...], tuple[str, ...] | None, bool]:
        """How the workers of `root`'s unit start (children included)."""
        per = self.cfg.worker_cmds or {}
        if root is not None and root.hash in per:
            cmd, kill = per[root.hash]
            return tuple(cmd), (tuple(kill) if kill else None), True
        return self.worker_cmd, self.worker_kill_cmd, self.custom_worker

    def _spawn(self, info: ModelInfo, seed: int, scratch: Path, role: str, deadline: float,
               logs: list[str], own_scratch: bool = False, root: ModelInfo | None = None) -> WorkerHandle:
        self._verify(info)
        self._spawned += 1
        command, kill, custom = self._command_for(root)
        w = WorkerHandle(info, in_process=self.cfg.in_process, scratch=scratch, role=role,
                         threads=self.cfg.threads, own_scratch=own_scratch, command=command,
                         kill_command=kill, custom=custom)
        hello = Message("hello", {"protocol": PROTOCOL_VERSION, "model_dir": str(info.path),
                                  "config": info.config, "seed": seed, "scratch": str(scratch),
                                  "children": list(info.children)})
        if self.tap:
            self.tap(role, hello)
        try:
            w.send(hello, deadline)
            while True:
                m = w.recv(deadline)
                if m.type == "log":
                    logs.append(m.header.get("message", ""))
                    continue
                if m.type == "ready":
                    return w
                if m.type == "error":
                    raise WorkerCrash(f"model failed to start: {m.header.get('message')}")
                raise WorkerCrash(f"protocol: expected ready, got {m.type}")
        except BaseException:
            w.kill()                           # never leave a half-started worker behind
            w.close()
            raise

    def _verify(self, info: ModelInfo) -> None:
        if info.hash in self._verified:
            return
        try:
            Registry.verify(info)
        except RegistryError as e:
            raise WorkerCrash(str(e)) from None
        self._verified.add(info.hash)

    def _call(self, w: WorkerHandle, ctx: CallCtx, typ: str, header: dict, tables: dict | None,
              arrays: dict, deadline: float, logs: list[str], eb: EpisodeBatches) -> Message:
        self._id += 1
        rid = self._id
        h = {"id": rid, **header}
        if tables is not None:
            # The as-of guarantee, at the protocol layer.
            assert_as_of(tables, header["now"] if typ == "fit" else header["until"],
                         check_nulls=self.cfg.scrub)
            h["tables"] = list(tables)
        msg = Message(typ, h, arrow=tables or {}, arrays=arrays)
        if self.tap:
            self.tap(ctx.role, msg)
        try:
            w.send(msg, deadline)
            while True:
                m = w.recv(deadline)
                if m.type == "log":
                    logs.append(m.header.get("message", ""))
                elif m.type == "child_request":
                    w.send(self._serve_child(ctx, m, deadline, logs, eb), deadline)
                elif m.type == "backtest_request":
                    w.send(self._serve_backtest(ctx, m, deadline, logs, eb), deadline)
                elif m.type in ("ok", "forecast_result", "error") and m.header.get("id") == rid:
                    return m
                else:
                    w.kill()
                    raise WorkerCrash(f"protocol: unexpected {m.type} (id {m.header.get('id')}) awaiting {rid}")
        finally:
            for cw, _ in ctx.pool.values():
                cw.close()
            ctx.pool.clear()

    # children ------------------------------------------------------------
    def _serve_child(self, ctx: CallCtx, m: Message, deadline: float, logs, eb) -> Message:
        rid = m.header.get("id")
        try:
            name = m.header.get("child")
            child = ctx.info.children.get(name)
            if child is None:
                raise ChildFailure(f"{name!r} is not a declared child of {ctx.info.name}")
            req = decode_request(m.header["request"], m.arrays)
            # The child answers for the parent's moment and scope, whatever the
            # request claims.
            req = replace(req, now=ctx.now, scope=ctx.view.scope)
            for tr in req.targets:
                g = tr.grid
                if g.ndim != 1 or len(g) == 0 or g[0] <= ctx.now or (np.diff(g) <= 0).any():
                    raise ChildFailure(f"{tr.key}: grid must be increasing and after now")
            fc = self._child_forecast(ctx, name, child, req, deadline, logs, eb)
            head, arrays = encode_forecast(fc)
            return Message("child_result", {"id": rid, "forecast": head}, arrays=arrays)
        except (ChildFailure, WorkerTimeout, WorkerCrash, KeyError, ValueError) as e:
            return Message("child_result", {"id": rid, "error": f"{type(e).__name__}: {e}"[:MAX_ERROR]})

    def _child_forecast(self, ctx: CallCtx, name: str, child: ModelInfo, req: Request, deadline: float,
                        logs, eb) -> Forecast:
        if ctx.depth + 1 > MAX_DEPTH:
            raise ChildFailure(f"call depth over {MAX_DEPTH}")
        key = cache_key(child.hash, self.data.snapshot_id, ctx.view.key, ctx.now, request_hash(req))
        hit = self.cache.get(key)
        if hit is not None:
            return hit
        if name not in ctx.pool:
            cctx = CallCtx(child, ctx.view, ctx.now, ctx.depth + 1, f"{ctx.role}/{name}", root=ctx.root)
            scratch = Path(tempfile.mkdtemp(prefix="arena-c-"))
            seed = derive_seed(child.hash, self.data.snapshot_id, json.dumps(ctx.view.key, sort_keys=True), ctx.now)
            cw = self._spawn(child, seed, scratch, cctx.role, deadline, logs, own_scratch=True, root=ctx.root)
            ctx.pool[name] = (cw, cctx)
            hist = eb.history(ctx.now) if eb.view is ctx.view else eb._serve(ctx.view.history(ctx.now))
            r = self._child_call(ctx, name, "fit", {"now": ctx.now, "scope": _scope(ctx.view.scope),
                                                    "mode": ctx.view.mode, "start": ctx.view.start,
                                                    "tz_offset_min": self.index.tz_offset_at(ctx.now)},
                                 hist, {}, deadline, logs, eb)
            if r.type == "error":
                raise ChildFailure(f"{name} fit: {r.header.get('message')}")
        head, arrays = encode_request(req)
        r = self._child_call(ctx, name, "forecast", {"request": head}, None, arrays, deadline, logs, eb)
        if r.type == "error":
            raise ChildFailure(f"{name} forecast: {r.header.get('message')}")
        fc, problems = validate_forecast(req, decode_forecast(r.header.get("forecast", {}), r.arrays),
                                         self.cfg.max_paths_factor)
        if problems:
            raise ChildFailure(f"{name}: " + "; ".join(problems))
        self.cache.put(key, fc)
        return fc

    def _child_call(self, ctx: CallCtx, name: str, typ: str, header: dict, tables, arrays, deadline, logs, eb):
        """A call to a pooled child; a child that times out or crashes is
        killed and dropped from the pool at once."""
        cw, cctx = ctx.pool[name]
        try:
            return self._call(cw, cctx, typ, header, tables, arrays, deadline, logs, eb)
        except (WorkerTimeout, WorkerCrash):
            ctx.pool.pop(name, None)
            cw.kill()
            cw.close()
            raise

    def _serve_backtest(self, ctx: CallCtx, m: Message, deadline: float, logs, eb) -> Message:
        rid = m.header.get("id")
        try:
            name = m.header.get("child")
            child = ctx.info.children.get(name)
            if child is None:
                raise ChildFailure(f"{name!r} is not a declared child of {ctx.info.name}")
            every = int(m.header.get("every") or 0)
            if every <= 0:
                raise ChildFailure("every must be > 0")
            wanted = {Target(t) for t in m.header.get("targets", [])}
            floor = ctx.view.start if ctx.view.start is not None else self.data.data_start
            since = m.header.get("since")
            start = max(int(since), floor) if since is not None else floor
            times = np.arange(start, ctx.now, every, dtype=np.int64)[-self.cfg.max_backtest_points:]
            items, arrays = [], {}
            for k, t in enumerate(times):
                t = int(t)
                req = build_request(ctx.view.scope, t, self._backtest_specs(ctx.view.scope.accounts, t, wanted),
                                    self.cfg.n_paths)
                if not req.targets:
                    continue
                at = CallCtx(ctx.info, ctx.view, t, ctx.depth, ctx.role, root=ctx.root)
                try:
                    fc = self._child_forecast(at, name, child, req, deadline, logs, eb)
                finally:
                    for cw, _ in at.pool.values():
                        cw.close()
                p = f"i{k}|"
                rh, ra = encode_request(req, p)
                fh, fa = encode_forecast(fc, p)
                items.append({"prefix": p, "request": rh, "forecast": fh})
                arrays.update(ra)
                arrays.update(fa)
            return Message("backtest_result", {"id": rid, "items": items}, arrays=arrays)
        except (ChildFailure, WorkerTimeout, WorkerCrash, KeyError, ValueError) as e:
            return Message("backtest_result", {"id": rid, "error": f"{type(e).__name__}: {e}"[:MAX_ERROR]})

    def _backtest_specs(self, accounts, t: Millis, wanted: set[Target]) -> list[TargetSpec]:
        """What a request at `t` would have asked, built from what was known
        at `t` (as-of meter cycles and turns); no truth needed, so no tier
        bound on the horizon."""
        specs: list[TargetSpec] = []
        for a in accounts:
            specs += meter_specs(self.index, a, t, wanted, FAR, 1)
            if Target.CYCLE_NEXT_START in wanted:
                s = next_start_spec(self.index, a, t, self.sampler.next_start_horizon, FAR)
                if s is not None:
                    specs.append(s)
        specs += hourly_specs(self.index, tuple(accounts), t, self.sampler.hourly_horizons[0], wanted)
        return [s for s in specs if grid_for(s, t) is not None]


def _scope(scope) -> dict:
    return {"accounts": list(scope.accounts), "view": scope.view}


# ---------------------------------------------------------------------------
# Parallel units (`RunConfig.jobs`)
# ---------------------------------------------------------------------------

@dataclass
class UnitResult:
    """What one (model, episode) unit adds to a run, in its own order."""

    scores: list[dict]
    failures: list[dict]
    logs: list[dict]
    forecasts: list[dict]
    seconds: float
    ran: bool = True                   # False: the model asks for none of the episode's targets


@dataclass
class _JobSpec:
    """Everything a job process needs to rebuild the parent's runner. Plain
    data (pickled to a spawned process the parent started: trusted)."""

    root: str
    snapshot_id: str
    tier: str
    cfg: RunConfig
    cache_root: str
    cache_enabled: bool
    models: list[ModelInfo]
    episodes: list[Episode]
    oracle_for: set[str]
    scorer: Scorer | None = None       # None: the default (a custom one must pickle by reference)
    after: int | None = None           # the prospective tier's start (SnapshotData.after)


_JOB: dict = {}


def _job_init(spec: _JobSpec) -> None:
    data = SnapshotData.from_dir(Path(spec.root), spec.tier, spec.snapshot_id, after=spec.after)
    r = Runner(data, replace(spec.cfg, jobs=1), scorer=spec.scorer,
               cache=ChildCache(Path(spec.cache_root), enabled=spec.cache_enabled))
    r.oracle_for = set(spec.oracle_for)
    _JOB.update(runner=r, spec=spec, batches={})


def _job_unit(run_id: str, ei: int, mi: int) -> UnitResult:
    r: Runner = _JOB["runner"]
    spec: _JobSpec = _JOB["spec"]
    ep = spec.episodes[ei]
    batches: dict = _JOB["batches"]
    eb = batches.get(ei)
    if eb is None:
        if len(batches) >= 2:                  # a job takes units in episode order: keep the last two
            batches.pop(next(iter(batches)))
        eb = batches[ei] = EpisodeBatches(r, ep)
    return r.run_unit(run_id, spec.models[mi], ep, eb)


# ---------------------------------------------------------------------------
# Summaries
# ---------------------------------------------------------------------------

def _round(v: float, sig: int) -> float:
    if v is None or not np.isfinite(v) or v == 0:
        return v
    return float(f"{v:.{sig}g}")


def summarize(out: RunOutcome, sig: int = 3) -> dict:
    """Per target and metric: the mean over every scored checkpoint of the
    whole-path rows (lead_s null; the per-lead-bin rows are breakdowns of the
    same score and would weight it twice), rounded, as `arena board` reads
    them; counts of scores and failures. Nothing per episode, nothing from
    the data."""
    by: dict[str, dict[str, list[float]]] = {}
    for s in out.scores:
        if s.get("lead_s") is not None or s["value"] is None or not np.isfinite(s["value"]):
            continue
        by.setdefault(s["target"], {}).setdefault(s["metric"], []).append(float(s["value"]))
    targets = {t: {m: _round(float(np.mean(v)), sig) for m, v in sorted(ms.items())} for t, ms in sorted(by.items())}
    fails: dict[str, int] = {}
    for f in out.failures:
        fails[f["kind"]] = fails.get(f["kind"], 0) + 1
    return {"episodes": len(out.episodes), "targets": targets, "failures": fails,
            "fallback_scoring": out.fallback_scoring}
