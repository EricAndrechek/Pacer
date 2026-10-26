"""`arena port-fixtures`: JSON fixtures that a port of a model (Swift, in
Pacer) checks itself against, written from a SYNTHETIC snapshot only.

    arena port-fixtures --model NAME --snapshot ID --cases N --seed S --out DIR

Each case is one meter target (five-hour and weekly alternate) of one
account at one moment. Per case the file holds:

- **inputs**: exactly what the model read, compactly: the account's readings
  of that window from the history start to `now` (thinned: a row is kept when
  its value, state or cycle changes, at least every `KEEPALIVE_MIN` minutes, and
  the first and last), with their own `t_known`; the device's UTC offset; the
  history start. The model's outputs below were computed from THESE rows (a
  snapshot reduced to them), not from the full snapshot, so they are exact
  for these inputs by construction;
- **request**: target, grid, `now`, `reset_at`;
- **outputs**: the model's deterministic quantiles (`kit.detq`) at LEVELS_OUT
  on the grid and the median path; `exact` says whether they are exact (to
  float precision) or a Monte-Carlo estimate (`mc_paths` paths, with
  per-level bounds);
- **detail**: intermediates worth checking on their own (Timestral's context
  vector and raw quantile head; the analog's query features and effective
  sample size; the calibration layer's fitted map).

The format is specified in docs/port-spec.md ("Parity"). Real snapshots are
refused: fixtures are committed and published, and must hold synthetic data
only (the manifest must say `synthetic` and a `truth/` folder must exist).

The local harness here (`Local`, `LocalContext`) runs models in this process
on a snapshot's as-of views exactly as the runner serves them (fresh fit per
moment, `ctx.backtest` at the same origins, the same seeds); it reads the
whole tier, so it is trusted-side code, for fixtures and debugging only.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import tempfile
from dataclasses import replace
from pathlib import Path

import numpy as np
import polars as pl

from arena.cache import ChildCache
from arena.episodes import GRID_HEAD, GRID_STEP, METER_TARGETS, TierIndex, build_request, target_key
from arena.registry import ModelInfo, Registry
from arena.runner import RunConfig, Runner, derive_seed, served
from arena.snapshot import snapshot_dir
from arena.snapshot.views import EpisodeView, HistoryView, SnapshotData, Tier, resolve_snapshot
from arena.types import Request, Scope, Target, TargetRequest
from arena.worker import load_model_class

MIN_MS = 60_000
HOUR_MS = 3_600_000
DAY_MS = 24 * HOUR_MS
KEEPALIVE_MIN = 60
WEEKLY_FIXTURE_STEP = 2 * HOUR_MS          # fixtures' weekly grids: the dense head, then every 2 h
HISTORY_DAYS = {"five_hour": 4, "seven_day": 10}
MIN_LEAD = {"five_hour": 30 * MIN_MS, "seven_day": DAY_MS}
WINDOW = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day"}
FORMAT = "pacer-arena-port-fixture/1"
MODELS_DIR = Path(__file__).resolve().parent.parent / "models"


# ---------------------------------------------------------------------------
# Local, in-process harness
# ---------------------------------------------------------------------------

class LocalContext:
    """`arena.types.Context` for a model run in this process: `model(name)`
    is the child itself (fitted at the same moment on the same view), and
    `backtest` runs the child afresh at each origin as the runner does."""

    def __init__(self, local: "Local", info: ModelInfo, view: EpisodeView, now: int, seed: int, scratch: Path):
        self._local, self._info, self._view, self._now = local, info, view, int(now)
        self.seed = int(seed)
        self.rng = np.random.default_rng(self.seed)
        self.scratch = scratch
        self.config = dict(info.config)
        self.children = tuple(info.children)
        self._kids: dict[str, object] = {}

    def model(self, name: str):
        if name not in self.children:
            raise KeyError(f"{name!r} is not a declared child of {self._info.name}")
        if name not in self._kids:
            self._kids[name] = self._local.instance(self._info.children[name], self._view, self._now)
        return self._kids[name]

    def backtest(self, name: str, *, every: int, targets, since: int | None = None):
        if name not in self.children:
            raise KeyError(f"{name!r} is not a declared child of {self._info.name}")
        return self._local.backtest(self._info.children[name], self._view, self._now, int(every),
                                    {Target(str(t)) for t in targets}, since)

    def log(self, message: str) -> None:
        self._local.logs.append(f"{self._info.name}: {message}")


class Local:
    def __init__(self, data: SnapshotData, *, n_paths: int = 200, max_backtest_points: int = 48,
                 tz_offset_min: int | None = None):
        self.data = data
        self.runner = Runner(data, RunConfig(in_process=True, n_paths=n_paths,
                                             max_backtest_points=max_backtest_points),
                             cache=ChildCache(enabled=False))
        self.index: TierIndex = self.runner.index
        self.n_paths = n_paths
        self.max_backtest_points = max_backtest_points
        self.tz_override = tz_offset_min
        self.logs: list[str] = []
        self._scratch = Path(tempfile.mkdtemp(prefix="arena-portfix-"))

    def history(self, view: EpisodeView, now: int) -> HistoryView:
        tz = self.tz_override if self.tz_override is not None else self.index.tz_offset_at(now)
        return HistoryView.from_arrow(served(view.history(now)), now, view.scope, view.mode, view.start, tz)

    def instance(self, info: ModelInfo, view: EpisodeView, now: int):
        """The model fitted at `now` on `view`, seeded as the runner seeds a child."""
        seed = derive_seed(info.hash, self.data.snapshot_id, json.dumps(view.key, sort_keys=True), now)
        m = load_model_class(info.path)(LocalContext(self, info, view, now, seed, self._scratch))
        m.fit(self.history(view, now))
        return m

    def backtest(self, child: ModelInfo, view: EpisodeView, now: int, every: int, wanted: set[Target],
                 since: int | None):
        floor = view.start if view.start is not None else self.data.data_start
        start = max(int(since), floor) if since is not None else floor
        times = np.arange(start, now, every, dtype=np.int64)[-self.max_backtest_points:]
        out = []
        for t in times:
            t = int(t)
            req = build_request(view.scope, t, self.runner._backtest_specs(view.scope.accounts, t, wanted),
                                self.n_paths)
            if not req.targets:
                continue
            out.append((req, self.instance(child, view, t).forecast(req)))
        return out


# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

def is_synthetic(snapshot_id: str) -> bool:
    d = snapshot_dir(snapshot_id)
    try:
        man = json.loads((d / "manifest.json").read_text())
    except (OSError, ValueError):
        return False
    return bool(man.get("synthetic")) and (d / "truth").is_dir()


def thin(frame: pl.DataFrame) -> pl.DataFrame:
    """One meter's readings (t_event order): keep the first and last, every
    change of value, state or cycle (a reset 30 min or more from the
    previous one), and at least one every KEEPALIVE_MIN minutes."""
    if frame.height <= 2:
        return frame
    te = frame["t_event"].dt.epoch("ms").to_numpy().astype(np.int64)
    u = frame["util_pct"].fill_null(-1.0).to_numpy()
    st = frame["state"].fill_null("").to_list()
    rs = frame["resets_at"].dt.epoch("ms").fill_null(-1).to_numpy().astype(np.int64)
    keep = np.zeros(frame.height, dtype=bool)
    keep[0] = keep[-1] = True
    last = te[0]
    for i in range(1, frame.height):
        if (u[i] != u[i - 1] or st[i] != st[i - 1] or abs(rs[i] - rs[i - 1]) >= 30 * MIN_MS
                or te[i] - last >= KEEPALIVE_MIN * MIN_MS):
            keep[i] = True
        if keep[i]:
            last = te[i]
    return frame.filter(pl.Series(keep))


def fixture_grid(target: Target, now: int, reset: int) -> np.ndarray:
    """Five-hour: the runner's grid. Weekly: the runner's dense head, then
    every 2 h (fixtures stay small; models must not assume an even step)."""
    step = GRID_STEP[target] if target is Target.METER_5H else WEEKLY_FIXTURE_STEP
    head = np.asarray(GRID_HEAD[target], dtype=np.int64) + now
    g = np.concatenate([head, np.arange(now + step, reset, step, dtype=np.int64)])
    return np.append(g[g < reset], np.int64(reset))


def pick_cases(index: TierIndex, n: int, seed: int) -> list[dict]:
    rng = np.random.default_rng(seed)
    accts = [a for a in index.accounts if index.meter(a, Target.METER_5H) is not None]
    t0, t1 = index.tier.start, index.tier.end
    cases = []
    for i in range(n):
        target = Target.METER_5H if i % 2 == 0 else Target.METER_7D
        wk = WINDOW[target]
        for _ in range(500):
            acct = accts[int(rng.integers(len(accts)))]
            now = int(rng.integers(t0 + HISTORY_DAYS[wk] * DAY_MS + DAY_MS, t1 - DAY_MS))
            now -= now % 1000
            c = index.meter(acct, target).cycle_at(now)
            if c is not None and c.reset_at - now >= MIN_LEAD[wk]:
                cases.append({"id": f"c{i:02d}", "target": target, "account": acct, "now": now,
                              "reset_at": int(c.reset_at), "start": now - HISTORY_DAYS[wk] * DAY_MS})
                break
        else:
            raise SystemExit(f"no active {wk} cycle found for case {i}")
    return cases


def reduced(data: SnapshotData, case: dict) -> tuple[SnapshotData, pl.DataFrame, int | None]:
    """The snapshot cut to what the case's model reads: the account's thinned
    readings of the window, known by now and from the history start; plus the
    device's UTC offset at now."""
    wk = WINDOW[case["target"]]
    r = data.tables["meter_readings"]
    te, tk = pl.col("t_event").dt.epoch("ms"), pl.col("t_known").dt.epoch("ms")
    f = r.filter((pl.col("account") == case["account"]) & (pl.col("window_kind") == wk)
                 & (tk <= case["now"]) & (te >= case["start"])).sort(["t_event", "t_known"])
    f = thin(f).with_columns(pl.lit("observed").alias("t_known_src"), pl.lit(None, pl.Utf8).alias("identity"),
                             pl.lit(None, f.schema["severity"]).alias("severity"),
                             pl.lit("oauth").alias("source"), pl.lit("archive").alias("origin"),
                             pl.lit(None, f.schema["dup_group"]).alias("dup_group"),
                             pl.lit(0.0).alias("backwards_pp"))
    f = f.select(r.columns).cast(r.schema)
    tz = TierIndex(data).tz_offset_at(case["now"]) if data.tables["turns"].height else None
    small = SnapshotData({"meter_readings": f}, snapshot_id=f"{data.snapshot_id}/{case['id']}",
                         tier=Tier("synthetic", case["start"], case["now"]), manifest={})
    return small, f, tz


def inputs_json(f: pl.DataFrame, case: dict, tz: int | None) -> dict:
    now = case["now"]
    te = f["t_event"].dt.epoch("ms").to_numpy().astype(np.int64)
    tk = f["t_known"].dt.epoch("ms").to_numpy().astype(np.int64)
    return {
        "account": case["account"], "window_kind": WINDOW[case["target"]], "scope_model": None,
        "history_start": int(case["start"]), "tz_offset_min": tz,
        "readings": {
            "columns": ["t_event", "t_known", "util_pct", "resets_at", "state"],
            "note": "times are epoch ms; util_pct null when unknown; resets_at null when idle",
            "t_event": te.tolist(), "t_known": tk.tolist(),
            "util_pct": [None if v is None else _num(v) for v in f["util_pct"].to_list()],
            "resets_at": [None if (v is None or (isinstance(v, float) and math.isnan(v))) else int(v)
                          for v in f["resets_at"].dt.epoch("ms").to_list()],
            "state": f["state"].to_list(),
        },
        "n_readings": f.height,
        "span_s": int((now - int(te[0])) / 1000) if len(te) else 0,
    }


def _num(x, nd: int = 6):
    """A float as the shortest JSON number within nd decimals."""
    if x is None:
        return None
    x = float(x)
    if not math.isfinite(x):
        return None
    r = round(x, nd)
    return int(r) if r == int(r) and abs(r) < 2 ** 53 else r


def _arr(a, nd: int = 6):
    a = np.asarray(a, dtype=np.float64)
    if a.ndim == 0:
        return _num(a, nd)
    return [_arr(x, nd) for x in a] if a.ndim > 1 else [_num(x, nd) for x in a]


def _full(x):
    """Plain JSON at full float precision (a fitted map a port applies as is)."""
    return json.loads(json.dumps(x, default=float))


def detail_json(d: dict) -> dict:
    out = {}
    for k, v in d.items():
        if isinstance(v, np.ndarray):
            out[k] = _arr(v)
        elif isinstance(v, (np.floating, float)):
            out[k] = _num(v)
        elif isinstance(v, (np.integer,)):
            out[k] = int(v)
        elif isinstance(v, dict):
            out[k] = detail_json(v)
        elif isinstance(v, list):
            out[k] = [detail_json(x) if isinstance(x, dict) else _arr(x) if isinstance(x, (list, np.ndarray))
                      else _num(x) if isinstance(x, float) else x for x in v]
        else:
            out[k] = v
    return out


# ---------------------------------------------------------------------------
# The command
# ---------------------------------------------------------------------------

def make_case(data: SnapshotData, info: ModelInfo, case: dict, *, include_raw: bool,
              keep_model: bool = False):
    """(inputs, outputs) of one case for one model (and the fitted model
    itself when `keep_model`)."""
    from kit import detq
    small, f, tz = reduced(data, case)
    local = Local(small, tz_offset_min=tz)
    target = case["target"]
    acct = case["account"]
    grid = fixture_grid(target, case["now"], case["reset_at"])
    key = target_key(target, (acct,))
    req = Request(case["now"], Scope((acct,), "scope_only"),
                  (TargetRequest(key, target, (acct,), grid, "pct", 200, None, None, case["reset_at"]),))
    view = small.view(req.scope, "current_code", case["start"])
    model = local.instance(info, view, case["now"])
    det = detq.quantiles(model, req, detq.LEVELS_OUT)[key]
    detail = dict(det.detail)
    if not include_raw:
        detail.pop("raw", None)
    out = {
        "levels": list(detq.LEVELS_OUT), "quantiles": _arr(det.q), "median": _arr(det.median),
        "exact": bool(det.exact), "mc_paths": int(det.mc_paths),
        "detail": detail_json(detail),
    }
    if detail.get("fit") is not None:
        out["detail"]["fit"] = _full(detail["fit"])        # full precision: a port applies it as is
    if not det.exact and det.lo is not None:
        out["mc_bounds"] = {"lo": _arr(det.lo), "hi": _arr(det.hi)}
    inputs = inputs_json(f, case, tz)
    request = {"key": key, "target": str(target), "account": acct, "now": case["now"],
               "reset_at": case["reset_at"], "grid": [int(x) for x in grid]}
    if keep_model:
        return {"inputs": inputs, "request": request}, out, model
    return {"inputs": inputs, "request": request}, out


FIT_RECORDS_MAX = 120


def fit_fixture(model, now: int) -> list[dict]:
    """The calibration layer's records at `now` (each kind's, cut to at most
    FIT_RECORDS_MAX by whole forecast origins, values rounded to 4 decimals)
    and the map each method fits from exactly those rounded records: a port
    checks its fitting code on them, independently of its forecaster."""
    from kit import calib as C
    out = []
    for kind, (q, y, lead, origin, floor, whole) in sorted(model.store.records(model.meters, now).items()):
        keep = np.zeros(len(y), dtype=bool)
        for o in np.unique(origin)[::-1]:                     # the latest origins first
            m = origin == o
            if keep.sum() + m.sum() > FIT_RECORDS_MAX:
                break
            keep |= m
        q, y, lead, origin = (np.round(q[keep], 4), np.round(y[keep], 4), np.round(lead[keep], 3), origin[keep])
        floor, whole = np.round(floor[keep], 4), whole[keep]
        s_max = float(model.cfg.get("s_max", C.S_MAX))
        fits = {meth: C.fit_kind(kind, q, y, lead, origin, meth, float(model.cfg["n0"]), float(model.cfg["n0_bin"]),
                                 int(model.cfg["min_origins"]), floor, whole, s_max).to_json()
                for meth in C.METHODS}
        out.append({"kind": kind, "n0": float(model.cfg["n0"]), "n0_bin": float(model.cfg["n0_bin"]),
                    "min_origins": int(model.cfg["min_origins"]), "s_max": s_max, "m_levels": C.M_LEVELS,
                    "records": {"q": _arr(q, 4), "y": _arr(y, 4), "lead_s": _arr(lead, 3),
                                "origin": [int(o) for o in origin], "floor": _arr(floor, 4),
                                "whole": [bool(x) for x in whole]},
                    "fits": _full(fits)})
    return out


def run(a: argparse.Namespace) -> int:
    sid = resolve_snapshot(a.snapshot)
    if not is_synthetic(sid):
        print(f"arena port-fixtures: {sid} is not a synthetic snapshot (its manifest must say `synthetic` "
              f"and it must have a truth/ folder); fixtures are published, so real data is refused",
              file=sys.stderr)
        return 2
    names = [m.strip() for m in a.model.split(",") if m.strip()]
    reg = Registry([MODELS_DIR] + [Path(p) for p in (a.models_root or [])])
    infos = [reg.load(n) for n in names]
    data = SnapshotData.load(sid, "synthetic")
    cases = pick_cases(TierIndex(data), int(a.cases), int(a.seed))
    out_dir = Path(a.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    shared: dict[str, dict] = {}
    from kit.calib import CalibModel
    for info in infos:
        rows, fits = [], []
        for case in cases:
            io, res, model = make_case(data, info, case, include_raw=case["target"] is Target.METER_5H,
                                       keep_model=True)
            shared.setdefault(case["id"], io)
            rows.append({"case": case["id"], **res})
            if isinstance(model, CalibModel) and len(fits) < 2 and not any(
                    f["kind"] == WINDOW[case["target"]] for f in fits):
                fits += [dict(f, case=case["id"]) for f in fit_fixture(model, case["now"])
                         if f["kind"] == WINDOW[case["target"]]]
            print(f"{info.name} {case['id']} {io['request']['key']}: exact={res['exact']}", file=sys.stderr)
        doc = {"format": FORMAT, "spec": "docs/port-spec.md#parity", "model": info.name,
               "snapshot": sid, "seed": int(a.seed), "outputs": rows}
        if fits:
            doc["fit_parity"] = fits
        (out_dir / f"{info.name}.json").write_text(json.dumps(doc, separators=(",", ":")) + "\n")
    cases_doc = {"format": FORMAT, "spec": "docs/port-spec.md#parity", "snapshot": sid, "seed": int(a.seed),
                 "keepalive_min": KEEPALIVE_MIN, "weekly_grid_step_ms": WEEKLY_FIXTURE_STEP,
                 "cases": [{"id": cid, **io} for cid, io in shared.items()]}
    (out_dir / "cases.json").write_text(json.dumps(cases_doc, separators=(",", ":")) + "\n")
    print(f"{len(cases)} cases, {len(infos)} models -> {out_dir}")
    return 0


def register(subparsers) -> None:
    p = subparsers.add_parser("port-fixtures", help="JSON fixtures for a port of a model (synthetic snapshots only)")
    p.add_argument("--model", required=True, help="model name(s), comma-separated")
    p.add_argument("--snapshot", required=True, help="a SYNTHETIC snapshot id (real ones are refused)")
    p.add_argument("--cases", type=int, default=20)
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--out", required=True)
    p.add_argument("--models-root", action="append", help="another folder of models")
    p.set_defaults(func=run)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="arena")
    register(ap.add_subparsers(dest="cmd", required=True))
    a = ap.parse_args(argv)
    return int(a.func(a) or 0)


if __name__ == "__main__":
    raise SystemExit(main())
