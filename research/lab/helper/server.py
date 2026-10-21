"""Pacer prediction-lab helper: serves research forecasters to a dev build of
the app over loopback HTTP, so they compete live in the app's record.

    uv run server.py                       # 127.0.0.1:7231, the live store, predictors/
    uv run server.py --port 7299 --store /path/to/pacer.sqlite --predictors ./predictors

Endpoints (JSON):
    GET  /healthz       liveness, store path, per-predictor call stats
    GET  /v1/models     {"models": [{id, displayName, summary, howItWorks, windows, complexity}]}
    POST /v1/forecast   see `forecast()` below
    POST /v1/reload     re-scan predictors/ (edits and new files), answers like /v1/models

The store is read read-only (`lab_store`). Predictors see only readings at or
before the cut they are asked about (`lab_history.History`): the helper slices
the data, a predictor never gets more.
"""
from __future__ import annotations

import argparse
import json
import logging
import math
import os
import signal
import sys
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import lab_registry
from lab_history import History
from lab_store import DEFAULT_STORE, FIXED_WINDOWS, Store

DEFAULT_PORT = 7231
MAX_BODY = 8 * 1024 * 1024
log = logging.getLogger("lab.server")


def _finite(v) -> float | None:
    if v is None:
        return None
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None


def coerce(out) -> dict | None:
    """A predictor's answer as the wire entry, or None (a decline). Accepts a
    number, a (final, q10, q90) tuple/list of length 1–3, or a dict with
    those keys. Anything without a finite final is a decline."""
    if out is None:
        return None
    if isinstance(out, dict):
        final, q10, q90 = out.get("final"), out.get("q10"), out.get("q90")
    elif isinstance(out, (tuple, list)):
        if not 1 <= len(out) <= 3:
            return None
        final, q10, q90 = (list(out) + [None, None])[:3]
    else:
        final, q10, q90 = out, None, None
    final = _finite(final)
    if final is None:
        return None
    return {"final": final, "q10": _finite(q10), "q90": _finite(q90)}


class Helper:
    def __init__(self, store: Store, predictors_dir: Path):
        self.store = store
        self.predictors_dir = predictors_dir
        self._lock = threading.Lock()
        self.predictors = lab_registry.load(predictors_dir)
        self.started = time.time()

    def reload(self) -> None:
        fresh = lab_registry.load(self.predictors_dir)
        with self._lock:
            self.predictors = fresh

    def models(self) -> dict:
        with self._lock:
            return {"models": [p.meta() for p in self.predictors]}

    def health(self) -> dict:
        with self._lock:
            preds = list(self.predictors)
        return {"ok": True, "store": str(self.store.path), "storeExists": self.store.path.exists(),
                "uptimeS": round(time.time() - self.started), "pid": os.getpid(),
                "predictors": {p.id: p.stats() for p in preds}}

    def forecast(self, body: dict) -> dict:
        """
        Request (batch form; the app sends this):
            {"window": "five_hour", "duration": 18000, "account": "<uuid>" | null,
             "cycles": [{"cycleStart": unix, "resetsAt": unix, "cuts": [unix, …]}, …],
             "models": ["lab-…"],      optional: only these (default: all serving the window)
             "deadlineMs": 1200}       optional: stop calling predictors after this
        or the single-cycle form: "cycleStart", "resetsAt", "cuts" at the top level.

        Response:
            {"window": …, "account": …,
             "cycles": [{"cycleStart", "resetsAt", "cuts",
                         "predictions": {"<model id>": [{"final", "q10", "q90"} | null, …per cut]}}],
             "predictions": {…}        the first cycle's, for the single-cycle form
             "truncated": bool,        true when the deadline cut some predictor calls
             "elapsedMs": float}
        """
        started = time.monotonic()
        window = body.get("window")
        if not isinstance(window, str) or not window:
            raise ValueError("window is required")
        account = body.get("account") or None
        duration = _finite(body.get("duration")) or FIXED_WINDOWS.get(window)
        if not duration or duration <= 0:
            raise ValueError("duration is required for a window the helper doesn't know")
        single = "cycles" not in body
        raw_cycles = [body] if single else body.get("cycles")
        if not isinstance(raw_cycles, list):
            raise ValueError("cycles must be a list")
        cycles = []
        for c in raw_cycles:
            start, reset = _finite(c.get("cycleStart")), _finite(c.get("resetsAt"))
            cuts = c.get("cuts")
            if start is None or reset is None or not isinstance(cuts, list):
                raise ValueError("each cycle needs cycleStart, resetsAt and cuts")
            cuts = [_finite(t) for t in cuts]
            if any(t is None for t in cuts):
                raise ValueError("cuts must be unix seconds")
            cycles.append((start, reset, cuts))

        wanted = body.get("models")
        with self._lock:
            predictors = [p for p in self.predictors
                          if p.serves(window) and (wanted is None or p.id in wanted)]
        deadline = started + (_finite(body.get("deadlineMs")) or 1e12) / 1000

        series = self.store.series(window, account)

        def other(name: str, t_cut: float):
            return self.store.series(name, account).until(t_cut)

        truncated = False
        out_cycles = []
        for start, reset, cuts in cycles:
            preds: dict[str, list] = {p.id: [] for p in predictors}
            for t_cut in cuts:
                history = History(window=window, account=account, t_cut=t_cut, cycle_start=start,
                                  resets_at=reset, duration=duration, readings=series.until(t_cut),
                                  other=other)
                for p in predictors:
                    if time.monotonic() > deadline:
                        truncated = True
                        preds[p.id].append(None)
                        continue
                    t0 = time.monotonic()
                    try:
                        entry = coerce(p.predict(window, account, t_cut, start, reset, history))
                        p.note(time.monotonic() - t0, "ok" if entry else "declined")
                    except Exception as e:  # noqa: BLE001 — one model's bug is its own decline
                        entry = None
                        p.note(time.monotonic() - t0, "error", f"{type(e).__name__}: {e}")
                        if p.errors <= 3 or p.errors % 100 == 0:
                            log.exception("%s failed at %s/%s cut %.0f", p.id, window, (account or "")[-4:], t_cut)
                    preds[p.id].append(entry)
            out_cycles.append({"cycleStart": start, "resetsAt": reset, "cuts": cuts, "predictions": preds})

        elapsed = (time.monotonic() - started) * 1000
        log.info("forecast %s/%s: %d cycle(s), %d cut(s), %d model(s) in %.0f ms%s", window,
                 (account or "all")[-4:], len(cycles), sum(len(c[2]) for c in cycles), len(predictors),
                 elapsed, " (deadline hit)" if truncated else "")
        response = {"window": window, "account": account, "cycles": out_cycles,
                    "truncated": truncated, "elapsedMs": round(elapsed, 1)}
        if single and out_cycles:
            response["predictions"] = out_cycles[0]["predictions"]
        return response


def make_handler(helper: Helper):
    class Handler(BaseHTTPRequestHandler):
        server_version = "PacerLabHelper/0.1"
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):  # route http.server's access log through logging
            log.debug("%s %s", self.address_string(), fmt % args)

        def _send(self, status: int, payload: dict) -> None:
            data = json.dumps(payload, allow_nan=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _body(self) -> dict:
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_BODY:
                raise ValueError("request too large")
            raw = self.rfile.read(length) if length else b"{}"
            body = json.loads(raw or b"{}")
            if not isinstance(body, dict):
                raise ValueError("body must be a JSON object")
            return body

        def do_GET(self):
            if self.path == "/healthz":
                return self._send(200, helper.health())
            if self.path == "/v1/models":
                return self._send(200, helper.models())
            self._send(404, {"error": f"no route {self.path}"})

        def do_POST(self):
            try:
                body = self._body()
                if self.path == "/v1/forecast":
                    return self._send(200, helper.forecast(body))
                if self.path == "/v1/reload":
                    helper.reload()
                    return self._send(200, helper.models())
                self._send(404, {"error": f"no route {self.path}"})
            except (ValueError, json.JSONDecodeError) as e:
                self._send(400, {"error": str(e)})
            except FileNotFoundError as e:
                self._send(503, {"error": str(e)})
            except Exception as e:  # noqa: BLE001
                log.exception("request failed")
                self._send(500, {"error": f"{type(e).__name__}: {e}"})

    return Handler


def serve(host: str, port: int, helper: Helper) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer((host, port), make_handler(helper))
    server.daemon_threads = True
    return server


def warm(helper) -> None:
    """Preload the store, then ask every predictor once about each account's
    live window, off the request path. Predictors build their own caches on
    first use (the token ledger loads every turn; the fade scores every past
    cycle), and a cold first request from the app ran past its 1.5 s budget
    while Python's GIL starved the other request threads."""
    helper.store.preload()
    started = time.monotonic()
    now = time.time()
    with helper.store._lock:
        keys = list(helper.store._series)
    for window, account in keys:
        duration = {"five_hour": 5 * 3600.0, "seven_day": 7 * 86400.0}.get(window)
        if duration is None or not account:
            continue
        s = helper.store.series(window, account)
        readings = s.until(now)
        if not readings or readings[-1].resets_at <= now:
            continue
        reset = readings[-1].resets_at
        history = History(window=window, account=account, t_cut=now, cycle_start=reset - duration,
                          resets_at=reset, duration=duration, readings=readings)
        for p in helper.predictors:
            if p.serves(window):
                try:
                    p.predict(window, account, now, reset - duration, reset, history)
                except Exception:  # noqa: BLE001 — warming is best effort
                    log.exception("warming %s on %s/%s failed", p.id, window, account[-4:])
    log.info("warmed %d series in %.1f s", len(keys), time.monotonic() - started)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--host", default="127.0.0.1", help="bind address (loopback by default; keep it that way)")
    ap.add_argument("--port", type=int, default=int(os.environ.get("PACER_LAB_PORT", DEFAULT_PORT)))
    ap.add_argument("--store", type=Path, default=Path(os.environ.get("PACER_LAB_STORE", DEFAULT_STORE)),
                    help="Pacer's pacer.sqlite (opened read-only)")
    ap.add_argument("--predictors", type=Path, default=lab_registry.DEFAULT_DIR)
    ap.add_argument("--pidfile", type=Path, help="write this process's pid here, removed on exit")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s", stream=sys.stderr)
    helper = Helper(Store(args.store), args.predictors)
    server = serve(args.host, args.port, helper)
    threading.Thread(target=warm, args=(helper,), daemon=True).start()
    if args.pidfile:
        args.pidfile.write_text(f"{os.getpid()}\n")

    def stop(*_):
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    log.info("serving %d predictor(s) on http://%s:%d (store %s)", len(helper.predictors),
             args.host, args.port, args.store)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        if args.pidfile and args.pidfile.exists() and args.pidfile.read_text().strip() == str(os.getpid()):
            args.pidfile.unlink()
        log.info("stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
