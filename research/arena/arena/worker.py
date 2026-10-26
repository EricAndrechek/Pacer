"""The model side of the protocol: `python -m arena.worker`.

Loads `<model_dir>/model.py`'s `Model`, hands it a `Context`, and answers the
runner's fit / update / forecast messages over stdin/stdout (arena/protocol.py).
The worker only ever holds what the runner sent it. Anything a model prints
goes to stderr: stdout carries the protocol.

A model exception becomes an `error` reply; the protocol keeps going. A model
without `update` is re-fitted on the extended history at each update.

The request / forecast codecs at the bottom are shared with the runner.
"""
from __future__ import annotations

import hashlib
import importlib.util
import os
import random
import sys
import traceback
from pathlib import Path
from typing import BinaryIO

import numpy as np

from arena.protocol import PROTOCOL_VERSION, Message, read_message, write_message
from arena.snapshot.views import EventsView, HistoryView
from arena.types import Forecast, Request, Scope, Target, TargetForecast, TargetRequest, TargetTruth

MAX_ERROR = 4000


class ChildError(RuntimeError):
    """A child model failed, or the runner refused the call."""


# ---------------------------------------------------------------------------
# Codecs (runner and worker)
# ---------------------------------------------------------------------------

def encode_request(req: Request, prefix: str = "") -> tuple[dict, dict[str, np.ndarray]]:
    head = {"now": int(req.now), "scope": {"accounts": list(req.scope.accounts), "view": req.scope.view},
            "targets": []}
    arrays = {}
    for tr in req.targets:
        head["targets"].append({"key": tr.key, "target": str(tr.target), "accounts": list(tr.accounts),
                                "units": tr.units, "n_paths": int(tr.n_paths), "cap": tr.cap,
                                "family": tr.family, "reset_at": tr.reset_at})
        arrays[f"{prefix}grid:{tr.key}"] = np.asarray(tr.grid, dtype=np.int64)
    return head, arrays


def decode_request(head: dict, arrays: dict[str, np.ndarray], prefix: str = "") -> Request:
    trs = tuple(TargetRequest(key=t["key"], target=Target(t["target"]), accounts=tuple(t["accounts"]),
                              grid=np.asarray(arrays[f"{prefix}grid:{t['key']}"], dtype=np.int64),
                              units=t["units"], n_paths=int(t["n_paths"]), cap=t.get("cap"),
                              family=t.get("family"), reset_at=t.get("reset_at"))
                for t in head["targets"])
    sc = head["scope"]
    return Request(now=int(head["now"]), scope=Scope(tuple(sc["accounts"]), sc["view"]), targets=trs)


def encode_forecast(fc, prefix: str = "") -> tuple[dict, dict[str, np.ndarray]]:
    if isinstance(fc, dict):
        fc = Forecast(fc)
    if not isinstance(fc, Forecast):
        raise TypeError(f"forecast() must return a Forecast, got {type(fc).__name__}")
    head = {"keys": [], "extras": {}}
    arrays = {}
    for key, tf in fc.by_key.items():
        if not isinstance(tf, TargetForecast):
            raise TypeError(f"{key}: expected a TargetForecast, got {type(tf).__name__}")
        head["keys"].append(str(key))
        arrays[f"{prefix}paths:{key}"] = np.asarray(tf.paths, dtype=np.float64)
        ex = {}
        for name, v in (tf.extras or {}).items():
            if np.ndim(v) == 0:
                ex[str(name)] = float(v)
            else:
                arrays[f"{prefix}extra:{key}:{name}"] = np.asarray(v, dtype=np.float64)
        if ex:
            head["extras"][str(key)] = ex
    return head, arrays


def decode_forecast(head: dict, arrays: dict[str, np.ndarray], prefix: str = "") -> Forecast:
    """No validation beyond structure: the runner validates against the
    request (`runner.validate_forecast`)."""
    out = {}
    for key in head.get("keys", []):
        arr = arrays.get(f"{prefix}paths:{key}")
        if arr is None:
            continue
        extras: dict = dict(head.get("extras", {}).get(key, {}))
        tag = f"{prefix}extra:{key}:"
        for name, v in arrays.items():
            if name.startswith(tag):
                extras[name[len(tag):]] = v
        out[key] = TargetForecast(arr, extras)
    return Forecast(out)


def decode_oracle(meta: dict | None, arrays: dict[str, np.ndarray]) -> dict[str, TargetTruth] | None:
    """The truth a self-test oracle is handed with a request (runner
    `_with_oracle`), by target key; None for every other model."""
    if meta is None:
        return None
    out = {}
    for key, m in meta.items():
        out[key] = TargetTruth(times=np.asarray(arrays[f"oracle_t:{key}"], np.int64),
                               values=np.asarray(arrays[f"oracle_v:{key}"], np.float64),
                               horizon_end=int(m["horizon_end"]), reset_at=m.get("reset_at"),
                               hit_limit=m.get("hit_limit"), time_to_limit=float(m["time_to_limit"]),
                               next_start=float(m["next_start"]))
    return out


# ---------------------------------------------------------------------------
# The worker loop
# ---------------------------------------------------------------------------

def load_model_class(model_dir: Path):
    path = Path(model_dir) / "model.py"
    name = "arena_model_" + hashlib.sha1(str(path.resolve()).encode()).hexdigest()[:12]
    if str(model_dir) not in sys.path:
        sys.path.insert(0, str(model_dir))           # the model's own helper modules
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    if not hasattr(module, "Model"):
        raise AttributeError(f"{path} defines no class Model")
    return module.Model


class _ChildProxy:
    def __init__(self, loop: "WorkerLoop", name: str):
        self._loop, self.name = loop, name

    def forecast(self, request: Request) -> Forecast:
        return self._loop.child_forecast(self.name, request)

    def __repr__(self) -> str:
        return f"<child {self.name}>"


class WorkerContext:
    """The `Context` of arena.types."""

    def __init__(self, loop: "WorkerLoop", seed: int, scratch: str, config: dict, children: list[str]):
        self._loop = loop
        self.seed = int(seed)
        self.rng = np.random.default_rng(self.seed)
        self.scratch = Path(scratch)
        self.config = dict(config)
        self.children = tuple(children)
        self.oracle = None          # self-test only: see WorkerLoop._handle and runner._with_oracle

    def model(self, name: str) -> _ChildProxy:
        if name not in self.children:
            raise ChildError(f"{name!r} is not a declared child (model.toml children: {list(self.children)})")
        return _ChildProxy(self._loop, name)

    def backtest(self, name: str, *, every: int, targets, since: int | None = None):
        if name not in self.children:
            raise ChildError(f"{name!r} is not a declared child")
        return self._loop.backtest(name, int(every), tuple(str(t) for t in targets), since)

    def log(self, message: str) -> None:
        self._loop.send(Message("log", {"message": str(message)[:MAX_ERROR]}))


class WorkerLoop:
    def __init__(self, rin: BinaryIO, wout: BinaryIO):
        self.rin, self.wout = rin, wout
        self.model = None
        self.history: HistoryView | None = None
        self._next = 0

    def send(self, msg: Message) -> None:
        write_message(self.wout, msg)

    def recv(self) -> Message:
        return read_message(self.rin)

    def _await(self, typ: str, rid: str) -> Message:
        m = self.recv()
        if m.type != typ or m.header.get("id") != rid:
            raise RuntimeError(f"protocol: expected {typ} {rid}, got {m.type} {m.header.get('id')}")
        return m

    def child_forecast(self, name: str, request: Request) -> Forecast:
        self._next += 1
        rid = f"c{self._next}"
        head, arrays = encode_request(request)
        self.send(Message("child_request", {"id": rid, "child": name, "request": head}, arrays=arrays))
        m = self._await("child_result", rid)
        if m.header.get("error"):
            raise ChildError(m.header["error"])
        return decode_forecast(m.header["forecast"], m.arrays)

    def backtest(self, name: str, every: int, targets: tuple[str, ...], since: int | None):
        self._next += 1
        rid = f"b{self._next}"
        self.send(Message("backtest_request", {"id": rid, "child": name, "every": every,
                                               "targets": list(targets), "since": since}))
        m = self._await("backtest_result", rid)
        if m.header.get("error"):
            raise ChildError(m.header["error"])
        out = []
        for it in m.header["items"]:
            p = it["prefix"]
            out.append((decode_request(it["request"], m.arrays, p), decode_forecast(it["forecast"], m.arrays, p)))
        return out

    def run(self) -> None:
        hello = self.recv()
        if hello.type != "hello":
            raise RuntimeError(f"protocol: expected hello, got {hello.type}")
        h = hello.header
        try:
            if int(h.get("protocol", -1)) != PROTOCOL_VERSION:
                raise RuntimeError(f"protocol {h.get('protocol')} != {PROTOCOL_VERSION}")
            seed = int(h.get("seed", 0))
            random.seed(seed)
            np.random.seed(seed % (2 ** 32))
            cls = load_model_class(Path(h["model_dir"]))
            # A worker started through a worker command (in a container) can't
            # use the runner's scratch path; its launcher names one instead.
            scratch = os.environ.get("ARENA_WORKER_SCRATCH") or h.get("scratch", ".")
            self.ctx = WorkerContext(self, seed, scratch, h.get("config", {}), h.get("children", []))
            self.model = cls(self.ctx)
        except BaseException as e:  # noqa: BLE001 - reported, then the worker exits
            self._error(0, "init", e)
            return
        self.send(Message("ready", {"capabilities": {"update": callable(getattr(self.model, "update", None))}}))
        while True:
            try:
                msg = self.recv()
            except EOFError:
                return
            if msg.type == "shutdown":
                return
            rid = msg.header.get("id")
            try:
                self._handle(msg)
            except KeyboardInterrupt:
                raise
            except BaseException as e:  # noqa: BLE001 - a model error (even sys.exit) never kills the protocol
                self._error(rid, type(e).__name__, e)

    def _error(self, rid, kind: str, e: BaseException) -> None:
        text = "".join(traceback.format_exception(e))[-MAX_ERROR:]
        self.send(Message("error", {"id": rid, "kind": kind, "message": text}))

    def _handle(self, msg: Message) -> None:
        h = msg.header
        rid = h.get("id")
        if msg.type == "fit":
            sc = h["scope"]
            hist = HistoryView.from_arrow(msg.arrow, h["now"], Scope(tuple(sc["accounts"]), sc["view"]),
                                          h.get("mode", "current_code"), h.get("start"), h.get("tz_offset_min"))
            self.history = hist
            self.model.fit(hist)
            self.send(Message("ok", {"id": rid}))
        elif msg.type == "update":
            ev = EventsView.from_arrow(msg.arrow, h["since"], h["until"], h.get("tz_offset_min"))
            if callable(getattr(self.model, "update", None)):
                self.model.update(ev)
                self.history = None                 # the model keeps its own state
            else:
                if self.history is None:
                    raise RuntimeError("update before fit")
                self.history = self.history.extend(ev)
                self.model.fit(self.history)
            self.send(Message("ok", {"id": rid}))
        elif msg.type == "forecast":
            req = decode_request(h["request"], msg.arrays)
            # Self-test only: the truth, when the runner's trusted caller
            # enabled the oracle for this model (runner `_with_oracle`).
            self.ctx.oracle = decode_oracle(h["request"].get("oracle"), msg.arrays)
            fc = self.model.forecast(req)
            head, arrays = encode_forecast(fc)
            self.send(Message("forecast_result", {"id": rid, "forecast": head}, arrays=arrays))
        else:
            raise RuntimeError(f"protocol: unexpected {msg.type}")


def main() -> None:
    # stdout carries the protocol: give it its own descriptor and point fd 1
    # (and print) at stderr, so nothing a model prints can corrupt a message.
    proto_out = os.fdopen(os.dup(1), "wb", buffering=0)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    proto_in = os.fdopen(os.dup(0), "rb", buffering=0)
    devnull = os.open(os.devnull, os.O_RDONLY)
    os.dup2(devnull, 0)                       # and a model can't read the runner's messages
    WorkerLoop(_Buffered(proto_in), proto_out).run()


class _Buffered:
    """Minimal buffered reader over an unbuffered pipe (read(n) may return
    short; protocol._read_exact loops)."""

    def __init__(self, raw):
        import io
        self._f = io.BufferedReader(raw, buffer_size=1 << 20)

    def read(self, n: int) -> bytes:
        return self._f.read1(n) if n > 0 else b""


if __name__ == "__main__":
    main()
