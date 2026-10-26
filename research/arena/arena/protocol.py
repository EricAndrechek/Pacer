"""How the runner (trusted) and a model's worker process (untrusted) talk.

Why a process boundary at all: a model must only ever hold rows known at
`now`. If the model could open the snapshot itself, "as of now" would be a
promise; with the runner holding the data and sending batches over a pipe,
it is a fact. The same holds for children: the runner runs them.

Why no pickle: unpickling is code execution. The runner reads only JSON
headers, Arrow IPC streams and `.npy` arrays loaded with
`allow_pickle=False`, and checks shapes and finiteness, so nothing a model
sends back can run in the trusted process.

Framing, both directions, over the worker's stdin/stdout:

    u32 big-endian header length | header (UTF-8 JSON)
    for each attachment named in header["attachments"]:
        u64 big-endian length | bytes   (kind "arrow": an IPC stream; "npy": np.save)

Messages (header["type"]):

  runner -> worker
    hello     {protocol, model_dir, config, seed, scratch, children: [names]}
    fit       {id, now, scope, mode, start, tz_offset_min, tables: [names]} + one arrow attachment per table
    update    {id, since, until, tz_offset_min, tables: [names]}       + one arrow attachment per table
    forecast  {id, request}                             + one npy per target grid ("grid:<key>")
    child_result    {id, forecast} | {id, error}
    backtest_result {id, items}    | {id, error}
    shutdown  {}

    `hello.children` names the children model.toml declares; `ctx.model()`
    refuses any other name before asking. `hello.scratch` is the runner's
    scratch folder; a worker started through a worker command (ARENA_WORKER_CMD,
    e.g. inside Docker) uses $ARENA_WORKER_SCRATCH instead when it is set.
    `fit.start` is the episode's history start (ms, or null for everything);
    the worker's HistoryView carries it so a re-fit after `update` keeps it.
    `tz_offset_min` is the device's UTC offset known at `now` / `until` (the
    latest known turn's, any account; null when none is known yet):
    `History.tz_offset_min`.
    `error` on a child or backtest result is the runner's refusal or the
    child's failure (text, truncated); the worker raises it as ChildError in
    the parent model. A backtest item is {prefix, request, forecast}, its
    arrays named with that prefix.

  worker -> runner
    ready     {capabilities: {update: bool}}
    ok        {id}
    forecast_result {id, forecast}                      + "paths:<key>" npy per key, "extra:<key>:<name>" npy/float
    child_request   {id, child, request}                + grids as in `forecast`
    backtest_request {id, child, every, targets, since}
    log       {message}            (kept on local runs; dropped on hidden tiers)
    error     {id, kind, message}  (message truncated by the runner)

A worker answers each runner message with exactly one of ok / forecast_result /
error, and may interleave child_request / backtest_request / log before it.
"""
from __future__ import annotations

import io
import json
import struct
from dataclasses import dataclass, field
from typing import BinaryIO

import numpy as np
import pyarrow as pa

PROTOCOL_VERSION = 1
MAX_HEADER = 16 * 1024 * 1024
MAX_ATTACHMENT = 2 * 1024 * 1024 * 1024


@dataclass
class Message:
    type: str
    header: dict = field(default_factory=dict)
    arrow: dict[str, pa.Table] = field(default_factory=dict)
    arrays: dict[str, np.ndarray] = field(default_factory=dict)


def write_message(stream: BinaryIO, msg: Message) -> None:
    attachments, blobs = [], []
    for name, table in msg.arrow.items():
        sink = io.BytesIO()
        with pa.ipc.new_stream(sink, table.schema) as w:
            w.write_table(table)
        attachments.append({"name": name, "kind": "arrow"})
        blobs.append(sink.getvalue())
    for name, arr in msg.arrays.items():
        sink = io.BytesIO()
        np.save(sink, np.ascontiguousarray(arr), allow_pickle=False)
        attachments.append({"name": name, "kind": "npy"})
        blobs.append(sink.getvalue())
    header = json.dumps({**msg.header, "type": msg.type, "attachments": attachments},
                        separators=(",", ":")).encode()
    stream.write(struct.pack(">I", len(header)))
    stream.write(header)
    for blob in blobs:
        stream.write(struct.pack(">Q", len(blob)))
        stream.write(blob)
    stream.flush()


def _read_exact(stream: BinaryIO, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = stream.read(n - len(buf))
        if not chunk:
            raise EOFError("stream closed mid-message")
        buf.extend(chunk)
    return bytes(buf)


def read_message(stream: BinaryIO) -> Message:
    (n,) = struct.unpack(">I", _read_exact(stream, 4))
    if n > MAX_HEADER:
        raise ValueError(f"header too large: {n}")
    header = json.loads(_read_exact(stream, n))
    if not isinstance(header, dict) or not isinstance(header.get("type"), str):
        raise ValueError("malformed header")
    msg = Message(type=header.pop("type"))
    for att in header.pop("attachments", []):
        (size,) = struct.unpack(">Q", _read_exact(stream, 8))
        if size > MAX_ATTACHMENT:
            raise ValueError(f"attachment too large: {size}")
        blob = _read_exact(stream, size)
        if att["kind"] == "arrow":
            msg.arrow[att["name"]] = pa.ipc.open_stream(blob).read_all()
        elif att["kind"] == "npy":
            msg.arrays[att["name"]] = np.load(io.BytesIO(blob), allow_pickle=False)
        else:
            raise ValueError(f"unknown attachment kind {att['kind']!r}")
    msg.header = header
    return msg
