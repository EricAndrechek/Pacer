"""A routed, weighted ensemble over every target, with structural overlays.

Per target kind, a recipe (model.toml `[config.recipes]`) names children and
their weights. At each forecast:

1. each child is asked once, for just the targets it is given in the
   recipes (a child that fails is left out and the others' weights are
   renormalised);
2. the children's paths are pooled per target key:
   - `vincent`: weighted average of the children's quantile curves at
     `m` levels per grid time (comonotone; right for cumulative meters);
   - `mixture`: a linear pool, round(w·n) of each child's own paths (keeps
     each child's path dependence; right for hourly series);
3. the pooled spread is scaled about the median by `spread` (per target),
   never below the meter's floor;
4. meters: the **re-base overlay**. A weekly allowance is sometimes re-based
   mid-cycle: the meter falls to ~0 under the same reset and climbs again.
   The model counts those drops in the history it is given (any account in
   view, recency weighted, with a weak prior) for a hazard per hour; each
   path independently re-bases at a uniform time before the reset with the
   probability that hazard gives over the time left, then climbs from ~1 %
   at the account's own recent burn rate. With no re-base in the history the
   hazard is the prior's (tiny); the five-hour meter never had one.
5. meter paths are clipped to [0, 100]; paths that did not re-base are kept
   at or above the latest reading of the cycle.

cycle.next_start and split.accounts come from this agent's own component
models, which already give calibrated samples.

**As-of adaptation (backtests in process).** At fit, every meter component
forecasts from past origins (a lattice over the last days; each origin sees
the history filtered to what was known then). At every forecast those past
forecasts are scored on the readings known now, and per target kind:
- the weights move from the recipe's prior by exponentially weighted
  averaging of relative CRPS (`adapt_eta`), each origin counted by how much
  of its span the truth already covers;
- the pooled forecast's spread about its median is rescaled by the factor
  (from `adapt_spreads`) that minimizes the pooled CRPS on those origins,
  shrunk toward the recipe's own `spread` when evidence is thin.
So a calm stretch (forecasts too wide, burn too high) or a busy one is
answered from the account's own recent record, not from a fixed setting.

**Every component runs in this model's own process** (no child workers):
under the scorer each child is its own container, re-spawned and re-fitted
at every checkpoint, and that overhead (not the forecasters' compute) made
an ensemble of children time out. The components are the same code as the
standalone models (kit.fm meter/spend/struct models, copies of
spend-decay-30m and example-linear, this agent's split, next-start and
analog-spend models), built here with their own configs from
`[config.components]` and sharing one History.
"""
from __future__ import annotations

import math

import numpy as np
import polars as pl

from arena.types import Forecast, Request, Target, TargetForecast, TargetRequest

HOUR_MS = 3_600_000
DAY_MS = 24 * HOUR_MS
MIN_MS = 60_000
WINDOW_OF = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day", Target.METER_SCOPED: "weekly_scoped"}
WINDOW_MS = {"five_hour": 5 * HOUR_MS, "seven_day": 7 * DAY_MS, "weekly_scoped": 7 * DAY_MS}


def qmat(P: np.ndarray, m: int) -> np.ndarray:
    """[m, G] quantile curves of a path set at m mid-levels."""
    P = np.sort(np.asarray(P, np.float64), axis=0)
    n = P.shape[0]
    if n == m:
        return P
    pos = (np.arange(m) + 0.5) / m * n - 0.5
    lo = np.clip(np.floor(pos).astype(int), 0, n - 1)
    hi = np.clip(lo + 1, 0, n - 1)
    f = np.clip(pos - lo, 0.0, 1.0)[:, None]
    return P[lo] * (1 - f) + P[hi] * f


def crps_sorted(Q: np.ndarray, y: np.ndarray) -> float:
    """Mean over times of the CRPS of sorted samples Q [m, T] at y [T]."""
    m = Q.shape[0]
    a = np.abs(Q - y[None, :]).mean(axis=0)
    w = (2 * np.arange(1, m + 1) - m - 1)[:, None]
    return float((a - (w * Q).sum(axis=0) / (m * m)).mean())


def pool_vincent(Ps, w, m) -> np.ndarray:
    w = np.asarray(w, np.float64)
    w = w / w.sum()
    return sum(wi * qmat(P, m) for wi, P in zip(w, Ps))


def pool_mixture(Ps, w, n, rng) -> np.ndarray:
    w = np.asarray(w, np.float64)
    w = w / w.sum()
    raw = w * n
    cnt = np.floor(raw).astype(int)
    rest = n - cnt.sum()
    if rest > 0:
        cnt[np.argsort(-(raw - cnt), kind="stable")[:rest]] += 1
    out = [P[rng.choice(len(P), size=c, replace=c > len(P))] for P, c in zip(Ps, cnt) if c > 0]
    return np.vstack(out)


def kind_of(tr) -> str:
    return str(tr.target)


class _SubCtx:
    """What a component sees as its ctx: its own config and rng, and (for a
    structural model) its in-process spend source as `model(name)`."""

    def __init__(self, parent, name, config, rng, sources):
        self._parent, self._name = parent, name
        self.config = dict(config)
        self.rng = rng
        self.seed = int(rng.integers(2 ** 31))
        self.scratch = getattr(parent, "scratch", None)
        self._sources = sources
        self.children = tuple(sources)

    def model(self, name):
        return self._sources[name]

    def log(self, message):
        self._parent.log(f"[{self._name}] {message}")

    def backtest(self, *a, **k):
        raise RuntimeError("no backtests for in-process components")


def build_component(kind: str):
    """The component classes, imported lazily (torch only when an FM is used)."""
    if kind == "fm_meter":
        from kit.fm.meter_model import MeterModel
        return MeterModel
    if kind == "fm_spend":
        from kit.fm.spend_model import SpendModel
        return SpendModel
    if kind == "struct":
        from kit.fm.struct_model import StructModel
        return StructModel
    if kind == "analog_spend":
        from ens_analog import Model
        return Model
    if kind == "split":
        from ens_split import Model
        return Model
    if kind == "nextstart":
        from ens_nextstart import Model
        return Model
    if kind == "spend_decay":
        from ens_sd_decay import Model
        return Model
    if kind == "linear":
        from ens_linear import Model
        return Model
    if kind == "flat":
        return FlatMeter
    raise ValueError(f"unknown component kind {kind!r}")


class FlatMeter:
    """Persistence: the latest reading of the cycle, flat to reset (naive-flat)."""

    def __init__(self, ctx):
        self.history = None

    def fit(self, history):
        self.history = history

    def forecast(self, request):
        from kit import baselines as B
        return Forecast({tr.key: B.meter_flat(self.history, tr) for tr in request.targets
                         if tr.target in WINDOW_OF})


class Model:
    def __init__(self, ctx):
        self.ctx = ctx
        self.cfg = dict(ctx.config)
        self.rng = ctx.rng
        self.recipes = {k: dict(v) for k, v in dict(self.cfg.get("recipes", {})).items()}
        self.history = None
        self._meters = None
        self.components = {}
        specs = dict(self.cfg.get("components", {}))
        # Spend sources first: a structural component names one as its child.
        order = sorted(specs, key=lambda n: 0 if specs[n].get("kind") in ("analog_spend", "fm_spend") else 1)
        for name in order:
            spec = dict(specs[name])
            kind = spec.pop("kind")
            sources = {c: self.components[c] for c in spec.get("children", []) if c in self.components}
            sub = _SubCtx(ctx, name, spec.get("config", {}), np.random.default_rng(self.rng.integers(2 ** 63)), sources)
            self.components[name] = build_component(kind)(sub)

    # contract ------------------------------------------------------------
    def fit(self, history):
        self.history = history
        self._meters = None
        for c in self.components.values():
            c.fit(history)
        self._bt = []
        if self.cfg.get("adapt", True):
            try:
                self._backtest()
            except Exception as e:  # noqa: BLE001 - adaptation is optional
                self.ctx.log(f"backtest failed: {type(e).__name__}: {str(e)[:300]}")
            for c in self.components.values():
                c.fit(history)

    # backtests ---------------------------------------------------------------
    def _past(self, origin: int):
        from arena.snapshot.views import HistoryView
        h = self.history
        tabs = {}
        for n in h.tables:
            df = h.table(n)
            if df.height and "t_known" in df.columns:
                df = df.filter(pl.col("t_known").dt.epoch("ms") <= origin)
            tabs[n] = df
        tz = None
        t = tabs.get("turns")
        if t is not None and t.height and "tz_offset_min" in t.columns:
            v = t.filter(pl.col("tz_offset_min").is_not_null()).sort("t_event").tail(1)
            tz = int(v["tz_offset_min"][0]) if v.height else None
        return HistoryView(tabs, int(origin), h.scope, h.mode, getattr(h, "start", None),
                           tz if tz is not None else h.tz_offset_min)

    def _meter_targets_at(self, origin: int):
        """The meter targets a request at `origin` would have held: each
        (account, window, cap) in view whose latest reading known then is of a
        cycle still running (reset after origin + 10 min)."""
        out = []
        for (a, wk, cap), (t, u, rs) in self._meter_frames().items():
            if a not in self.history.scope.accounts:
                continue
            i = int(np.searchsorted(t, origin, side="right")) - 1
            if i < 0 or origin - int(t[i]) > 2 * HOUR_MS:
                continue
            reset = int(rs[i])
            if reset <= origin + 10 * MIN_MS:
                continue
            target = {v: k for k, v in WINDOW_OF.items()}[wk]
            step = 5 * MIN_MS if wk == "five_hour" else 30 * MIN_MS
            g = np.arange(origin + step, reset, step, dtype=np.int64)
            g = np.append(g, np.int64(reset))
            key = f"{target}:{a}" + (f":{cap}" if cap else "")
            out.append(TargetRequest(key=key, target=target, accounts=(a,), grid=g, units="pct",
                                     n_paths=100, cap=cap, reset_at=reset))
        return out

    def _backtest(self):
        cfg = self.cfg
        now = self.history.now
        every = float(cfg.get("adapt_every_h", 3.0)) * HOUR_MS
        span = float(cfg.get("adapt_span_h", 72.0)) * HOUR_MS
        origins = np.arange(now - every, now - span - 1, -every, dtype=np.int64)[::-1]
        m = int(cfg.get("adapt_m", 40))
        for o in origins:
            trs = self._meter_targets_at(int(o))
            if not trs:
                continue
            past = self._past(int(o))
            for c in self.components.values():
                c.fit(past)
            asks = {}
            for tr in trs:
                for c in self.recipes.get(kind_of(tr), {}).get("children", {}):
                    asks.setdefault(c, []).append(tr)
            req = Request(int(o), self.history.scope, tuple(trs))
            got = {}
            for c, ts in asks.items():
                comp = self.components.get(c)
                if comp is None:
                    continue
                try:
                    got[c] = comp.forecast(Request(int(o), self.history.scope, tuple(ts)))
                except Exception as e:  # noqa: BLE001
                    self.ctx.log(f"backtest {c} @{int(o)} failed: {type(e).__name__}: {str(e)[:200]}")
            for tr in trs:
                qs = {}
                for c, f in got.items():
                    tf = f.by_key.get(tr.key)
                    if tf is None:
                        continue
                    P = np.asarray(tf.paths, np.float64)
                    if P.ndim == 2 and P.shape[1] == len(tr.grid) and np.isfinite(P).all():
                        qs[c] = qmat(np.clip(P, 0.0, 100.0), m)
                if qs:
                    self._bt.append({"origin": int(o), "tr": tr, "kind": kind_of(tr), "q": qs,
                                     "used": self._used_at(tr, int(o))})
        self.ctx.log(f"backtest: {len(origins)} origins, {len(self._bt)} forecasts")

    def _used_at(self, tr, at: int) -> float:
        s = self._series(tr)
        if s is None:
            return 0.0
        t, u, rs = s
        m = (np.abs(rs - int(tr.reset_at)) < 60_000) & (t <= at)
        return float(u[m][-1]) if m.any() else 0.0

    def _adapt(self, kind, rec, names, w0):
        """(weights, spread) for this kind from the backtests scored on the
        readings known now."""
        cfg = self.cfg
        now = self.history.now
        groups = []
        for b in self._bt:
            if b["kind"] != kind or not all(c in b["q"] for c in names):
                continue
            tr = b["tr"]
            s = self._series(tr)
            if s is None:
                continue
            t, u, rs = s
            sel = (np.abs(rs - int(tr.reset_at)) < 60_000) & (t > b["origin"]) & (t <= now)
            if sel.sum() < 2:
                continue
            tt, yy = t[sel], u[sel]
            idx = np.unique(np.linspace(0, len(tt) - 1, min(16, len(tt))).round().astype(int))
            tt, yy = tt[idx].astype(np.float64), yy[idx]
            g = tr.grid.astype(np.float64)
            X = [np.stack([np.interp(tt, g, row) for row in b["q"][c]]) for c in names]
            cov = float(np.clip((min(now, tr.reset_at) - b["origin"]) / (tr.reset_at - b["origin"]), 0, 1))
            groups.append((X, yy, cov, b["used"]))
        s0 = float(rec.get("spread", 1.0))
        w0 = np.asarray(w0, np.float64) / np.sum(w0)
        if not groups:
            return w0, s0
        d = np.array([gr[2] for gr in groups])
        L = np.array([[crps_sorted(np.sort(x, axis=0), gr[1]) for x in gr[0]] for gr in groups])
        R = L / np.maximum(L.mean(axis=1, keepdims=True), float(cfg.get("adapt_floor", 0.25)))
        eta = float(cfg.get("adapt_eta", 1.0))
        S = (d[:, None] * R).sum(axis=0)
        w = w0 * np.exp(-eta * (S - S.min()))
        w = w / w.sum()
        # Spread: the pooled forecast's CRPS on the backtests for each factor.
        spreads = [float(x) for x in cfg.get("adapt_spreads", [0.5, 0.65, 0.8, 1.0, 1.25, 1.5])]
        pool_kind = rec.get("pool", "vincent")
        tot = np.zeros(len(spreads))
        for (X, yy, cov, used) in groups:
            if pool_kind == "vincent":
                Q = sum(wi * np.sort(x, axis=0) for wi, x in zip(w, X))
            else:
                cnt = np.maximum(np.round(w * 120).astype(int), 0)
                Q = np.vstack([x[np.linspace(0, x.shape[0] - 1, k).round().astype(int)] for x, k in zip(X, cnt) if k > 0])
            med = np.median(Q, axis=0, keepdims=True)
            for j, sp in enumerate(spreads):
                Z = np.sort(np.maximum(med + sp * (Q - med), used), axis=0)
                tot[j] += cov * crps_sorted(Z, yy)
        best = spreads[int(np.argmin(tot))]
        n_eff = float(d.sum())
        k = float(cfg.get("adapt_spread_prior", 2.0))
        s = math.exp((n_eff * math.log(best) + k * math.log(s0)) / (n_eff + k))
        return w, s

    def update(self, events):
        # One History for every component (kit.spend memoizes per History).
        self.history = self.history.extend(events)
        self._meters = None
        for c in self.components.values():
            c.fit(self.history)

    def forecast(self, request: Request) -> Forecast:
        # Which child is asked for which targets.
        asks: dict[str, list] = {}
        for tr in request.targets:
            rec = self.recipes.get(kind_of(tr))
            if not rec:
                continue
            for c in rec.get("children", {}):
                asks.setdefault(c, []).append(tr)
        got: dict[str, Forecast] = {}
        for c, trs in asks.items():
            try:
                comp = self.components.get(c)
                sub = Request(request.now, request.scope, tuple(trs))
                got[c] = comp.forecast(sub) if comp is not None else self.ctx.model(c).forecast(sub)
            except Exception as e:  # noqa: BLE001 - a failing component is left out
                self.ctx.log(f"component {c} failed: {type(e).__name__}: {str(e)[:300]}")
        out = {}
        for tr in request.targets:
            rec = self.recipes.get(kind_of(tr))
            if not rec:
                continue
            tf = self._combine(request, tr, rec, got)
            if tf is not None:
                out[tr.key] = tf
        return Forecast(out)

    # combination -----------------------------------------------------------
    def _combine(self, request, tr, rec, got) -> TargetForecast | None:
        ws = {c: float(w) for c, w in rec.get("children", {}).items()}
        Ps, w = [], []
        for c, wc in ws.items():
            f = got.get(c)
            if f is None or tr.key not in f.by_key or wc <= 0:
                continue
            P = np.asarray(f.by_key[tr.key].paths, np.float64)
            if P.ndim != 2 or P.shape[1] != len(tr.grid):
                continue
            if tr.target is not Target.CYCLE_NEXT_START and not np.isfinite(P).all():
                continue
            Ps.append(P)
            w.append(wc)
        n = int(tr.n_paths)
        if not Ps:
            return self._fallback(request, tr)
        if tr.target is Target.CYCLE_NEXT_START or len(Ps) == 1 and rec.get("pool") != "vincent":
            P = Ps[0] if len(Ps) == 1 else pool_mixture(Ps, w, n, self.rng)
            return TargetForecast(P)
        s = float(rec.get("spread", 1.0))
        if tr.target in WINDOW_OF and getattr(self, "_bt", None):
            names = [c for c, wc in ws.items() if wc > 0 and got.get(c) is not None and tr.key in got[c].by_key]
            if len(names) == len(Ps):
                w, s = self._adapt(kind_of(tr), rec, names, w)
                self.ctx.log(f"adapt {tr.key}: " + ", ".join(f"{c}={x:.2f}" for c, x in zip(names, w)) + f" spread={s:.2f}")
        if rec.get("pool", "vincent") == "vincent":
            P = pool_vincent(Ps, w, int(rec.get("m", n)))
            P = P[self.rng.permutation(P.shape[0])]
        else:
            P = pool_mixture(Ps, w, n, self.rng)
        if s != 1.0:
            med = np.median(P, axis=0, keepdims=True)
            P = med + s * (P - med)
        if tr.target in WINDOW_OF:
            P = self._meter_post(request, tr, rec, P)
        elif tr.target is Target.SPLIT:
            P = np.clip(P, 0.0, 1.0)
        else:
            P = np.maximum(P, 0.0)
        return TargetForecast(P)

    def _fallback(self, request, tr) -> TargetForecast:
        n = int(tr.n_paths)
        G = len(tr.grid)
        if tr.target in WINDOW_OF:
            used = self._used_now(tr)
            return TargetForecast.point(np.full(G, used), n)
        if tr.target is Target.CYCLE_NEXT_START:
            return TargetForecast(np.full((1, G), np.nan))
        if tr.target is Target.SPLIT:
            return TargetForecast.point(np.full(G, 1.0 / max(len(request.scope.accounts), 1)), n)
        return TargetForecast.point(np.zeros(G), n)

    # meters ------------------------------------------------------------------
    def _meter_frames(self):
        if self._meters is None:
            r = self.history.table("meter_readings")
            out = {}
            if r.height:
                r = r.filter(pl.col("state") == "active").select(
                    "account", "window_kind", "scope_model",
                    pl.col("t_event").dt.epoch("ms").alias("t"), "util_pct",
                    pl.col("resets_at").dt.epoch("ms").alias("rs"))
                for (a, wk, cap), g in r.group_by(["account", "window_kind", "scope_model"]):
                    if wk not in WINDOW_MS:
                        continue
                    g = g.sort(["t", "util_pct"])
                    out[(str(a), str(wk), cap if wk == "weekly_scoped" else None)] = (
                        g["t"].to_numpy().astype(np.int64), g["util_pct"].to_numpy().astype(np.float64),
                        g["rs"].to_numpy().astype(np.int64))
            self._meters = out
        return self._meters

    def _series(self, tr):
        wk = WINDOW_OF[tr.target]
        cap = tr.cap if tr.target is Target.METER_SCOPED else None
        return self._meter_frames().get((tr.accounts[0], wk, cap))

    def _used_now(self, tr) -> float:
        s = self._series(tr)
        if s is None or tr.reset_at is None:
            return 0.0
        t, u, rs = s
        m = np.abs(rs - int(tr.reset_at)) < 60_000
        return float(u[m][-1]) if m.any() else 0.0

    def _rebase_rate(self, wk: str) -> float:
        """Re-bases per hour for this window kind: drops of more than
        `rebase_drop` points under the same reset, counted over every
        account in view (events within an hour of each other count once),
        recency weighted, with a weak prior."""
        cfg = self.cfg
        hl = float(cfg.get("rebase_half_life_days", 30.0)) * DAY_MS
        a0 = float(cfg.get("rebase_prior_events", 0.5))
        b0 = float(cfg.get("rebase_prior_days", 30.0)) * DAY_MS
        drop = float(cfg.get("rebase_drop", 5.0))
        now = self.history.now
        ev, lo = [], now
        for (a, w, cap), (t, u, rs) in self._meter_frames().items():
            if w != wk or len(t) < 2:
                continue
            lo = min(lo, int(t[0]))
            same = np.abs(np.diff(rs)) < 120_000
            idx = np.flatnonzero((np.diff(u) < -drop) & same)
            ev += [int(t[i + 1]) for i in idx]
        ev = np.sort(np.asarray(ev, np.int64))
        if len(ev):
            keep = np.concatenate(([True], np.diff(ev) > HOUR_MS))
            ev = ev[keep]
        k = math.log(2) / hl
        w_ev = float(np.sum(np.exp(-k * (now - ev)))) if len(ev) else 0.0
        expo = (1 - math.exp(-k * max(now - lo, 0))) / k
        return (w_ev + a0) / (expo + b0) * HOUR_MS

    def _burn_rate(self, tr) -> float:
        """The account's recent rise per hour on this meter (points/h): the
        sum of its rises over the last window length (re-bases and resets
        excluded)."""
        s = self._series(tr)
        wk = WINDOW_OF[tr.target]
        if s is None:
            return 100.0 / (WINDOW_MS[wk] / HOUR_MS) * 0.5
        t, u, rs = s
        now = self.history.now
        span = WINDOW_MS[wk]
        m = t > now - span
        if m.sum() < 2:
            return 100.0 / (span / HOUR_MS) * 0.5
        du = np.diff(u[m])
        same = np.abs(np.diff(rs[m])) < 120_000
        rise = float(du[(du > 0) & same].sum())
        return max(rise / (min(span, now - int(t[m][0])) / HOUR_MS), 0.05)

    def _meter_post(self, request, tr, rec, P) -> np.ndarray:
        used = self._used_now(tr)
        P = np.clip(np.maximum(P, used), 0.0, 100.0)
        P = np.maximum.accumulate(P, axis=1)
        if not rec.get("rebase", False) or tr.reset_at is None:
            return P
        wk = WINDOW_OF[tr.target]
        lam = self._rebase_rate(wk) * float(self.cfg.get("rebase_scale", 1.0))
        g = np.asarray(tr.grid, np.float64)
        now = float(request.now)
        H = (g[-1] - now) / HOUR_MS
        p = 1.0 - math.exp(-lam * max(H, 0.0))
        if p <= 1e-4:
            return P
        n = P.shape[0]
        hit = self.rng.random(n) < p
        if not hit.any():
            return P
        rate = self._burn_rate(tr)
        sig = float(self.cfg.get("rebase_rate_sigma", 0.7))
        r0_hi = float(self.cfg.get("rebase_floor_hi", 2.0))
        P = P.copy()
        for i in np.flatnonzero(hit):
            # Uniform time before the reset (the hazard is small over the window).
            tau = now + self.rng.uniform(0.0, 1.0) * (g[-1] - now)
            r0 = self.rng.uniform(0.0, r0_hi)
            ri = rate * math.exp(self.rng.normal(-0.5 * sig * sig, sig))
            after = g >= tau
            P[i, after] = np.minimum(r0 + ri * (g[after] - tau) / HOUR_MS, 100.0)
        return P
