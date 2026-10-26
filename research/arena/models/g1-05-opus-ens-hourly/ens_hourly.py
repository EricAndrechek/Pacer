"""A self-scoring ensemble of hourly spend / token children.

The combiners in `kit.ml.combine` only keep a ledger of meter forecasts. The
hourly targets can be scored by a model itself, because the truth is its own
data: the spend (or tokens) of the turns in each past hour. So this keeps the
same kind of ledger for `spend.hourly` and `tokens.hourly`:

- every child forecast (from `ctx.backtest` origins and from this episode's
  own checkpoints) is kept as sorted samples per grid hour;
- as soon as an hour has passed it is scored against the realised hour,
  priced at the rates known then;
- per (target, family) the weights on the simplex that minimise the pooled
  CRPS are refitted, together with a factor on the pooled spread.

The truth here is priced as of now, while the scorer prices with final rates;
a late price correction moves both the children and this ledger the same way,
so the weights are unaffected to first order.
"""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, Target, TargetForecast
from kit.fm.series import HOUR_MS, TurnFrame
from kit.spend import PriceCache
from kit.ml.paths import sorted_samples
from robust_child import ChildCaller

HOURLY = (Target.SPEND_HOURLY, Target.TOKENS_HOURLY)


def _half_gini(x: np.ndarray) -> np.ndarray:
    m = x.shape[0]
    w = (2 * np.arange(1, m + 1) - m - 1)[:, None]
    return (np.sort(x, axis=0) * w).sum(axis=0) / (m * m)


def _shape(q: np.ndarray, s: float, z: float) -> np.ndarray:
    """Rescale sorted samples around their median and zero-inflate them.

    An idle hour is exactly 0, and on the visible tier half of the truth sits
    below the children's lowest sample (`pit_b0` ≈ 0.5): they put far too
    little mass on "nothing happened". Replacing the lowest share `z` of the
    samples with 0 is a mixture of the pool with a point mass at zero, and
    `z` is fitted on the same past hours as the spread factor, so a child set
    that already handles idle hours drives it to 0."""
    med = np.median(q, axis=0, keepdims=True)
    out = np.maximum(med + s * (q - med), 0.0)
    k = int(round(z * out.shape[0]))
    if k > 0:
        out = np.sort(out, axis=0)
        out[:k] = 0.0
    return out


def _wcrps(q: np.ndarray, y: np.ndarray, pw: np.ndarray) -> float:
    """Weighted fair CRPS of sorted samples [m, E] against y [E]."""
    a = np.abs(q - y[None, :]).mean(axis=0) - _half_gini(q)
    return float((a * pw).sum())


def _simplex_min(fun, k, x0=None):
    from scipy.optimize import minimize
    if k == 1:
        return np.ones(1)
    x0 = np.full(k, 1.0 / k) if x0 is None else x0
    res = minimize(fun, x0, method="SLSQP", bounds=[(0.0, 1.0)] * k,
                   constraints=[{"type": "eq", "fun": lambda w: w.sum() - 1.0}],
                   options={"maxiter": 200, "ftol": 1e-10})
    w = np.clip(res.x if np.isfinite(res.x).all() else x0, 0.0, None)
    return w / w.sum() if w.sum() > 0 else np.full(k, 1.0 / k)


class Entry:
    __slots__ = ("grid", "q")

    def __init__(self, grid, q):
        self.grid, self.q = grid, q


class Group:
    """Every child's forecast of one hourly key from one origin."""

    __slots__ = ("origin", "key", "kind", "accounts", "what", "family", "entries", "times", "y")

    def __init__(self, origin, key, kind, accounts, what, family):
        self.origin, self.key, self.kind = origin, key, kind
        self.accounts, self.what, self.family = accounts, what, family
        self.entries: dict[str, Entry] = {}
        self.times = np.zeros(0, np.int64)
        self.y = np.zeros(0)

    def x(self, child: str) -> np.ndarray:
        e = self.entries[child]
        g = e.grid.astype(np.float64)
        t = self.times.astype(np.float64)
        return np.stack([np.interp(t, g, row) for row in e.q.astype(np.float64)])


class Turns:
    """Turn times, cost and tokens as of now, with per-hour sums at any time."""

    def __init__(self, history, hours: int, accounts, cache=None):
        tf = TurnFrame(history, hours, accounts=accounts, cache=cache)
        self.t = tf.t_ms
        self.account = tf.account
        self.family = tf.family
        self.cost = tf.cost
        self.tokens = tf.tokens
        self.now = tf.now

    def hour_sums(self, grid: np.ndarray, accounts, what: str, family: str | None) -> np.ndarray:
        m = np.isin(self.account, list(accounts))
        if family is not None:
            m &= self.family == family
        v = (self.cost if what == "spend" else self.tokens)[m]
        t = self.t[m]
        order = np.argsort(t, kind="stable")
        t, v = t[order], v[order]
        cs = np.concatenate(([0.0], np.cumsum(v)))
        hi = np.searchsorted(t, grid, side="right")
        lo = np.searchsorted(t, grid - HOUR_MS, side="right")
        return cs[hi] - cs[lo]


class Model:
    """Config: `children`, `backtest_every_h`, `backtest_n`, `shrink`,
    `scales`, `scale_shrink`, `half_life_n`, `min_points`, `m_fit`,
    `lookback_h` (turn history kept for self-scoring)."""

    def __init__(self, ctx):
        self.ctx = ctx
        self.cfg = dict(ctx.config)
        self.children = [str(c) for c in (self.cfg.get("children") or getattr(ctx, "children", ()) or ())]
        self.rng = ctx.rng
        self.m_fit = int(self.cfg.get("m_fit", 40))
        self.shrink = float(self.cfg.get("shrink", 0.05))
        self.scales = np.asarray(self.cfg.get("scales", [0.5, 0.65, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5]), np.float64)
        self.scale_shrink = float(self.cfg.get("scale_shrink", 0.25))
        self.half_life = float(self.cfg.get("half_life_n", 24))
        self.min_points = int(self.cfg.get("min_points", 24))
        self.lookback_h = int(self.cfg.get("lookback_h", 336))
        self.prices = PriceCache()   # price each turn once per episode, not once per checkpoint
        self.zeros = np.asarray(self.cfg.get("zero_inflate", [0.0, 0.05, 0.1, 0.2, 0.3, 0.4]), np.float64)
        self.caller = ChildCaller(ctx)
        self.groups: dict[tuple[int, str], Group] = {}
        self.turns: Turns | None = None
        self.history = None

    # ---- contract --------------------------------------------------------
    def fit(self, history):
        self.history = history
        self.turns = Turns(history, self.lookback_h, history.scope.accounts or None, self.prices)
        if not self.cfg.get("backtest", True):
            return
        every = int(float(self.cfg.get("backtest_every_h", 6)) * HOUR_MS)
        n = int(self.cfg.get("backtest_n", 8))
        since = (int(history.now) - n * every) // every * every
        for c in self.children:
            try:
                items = self.ctx.backtest(c, every=every, targets=HOURLY, since=since)
            except Exception as e:  # noqa: BLE001 - a child without a backtest starts unweighted
                self.ctx.log(f"backtest {c}: {type(e).__name__}: {str(e)[:160]}")
                continue
            added = sum(self._add(c, req, fc) for req, fc in items)
            self.ctx.log(f"backtest {c}: {len(items)} origins, {added} forecasts")

    def update(self, events):
        self.history = self.history.extend(events)
        self.turns = Turns(self.history, self.lookback_h, self.history.scope.accounts or None, self.prices)

    def forecast(self, request):
        got = {}
        for c in self.children:
            fc = self.caller.ask(c, request)
            if fc is None:
                continue
            got[c] = fc
            self._add(c, request, fc)
        self._score()
        out = {}
        for tr in request.targets:
            if tr.target not in HOURLY:
                continue
            avail = tuple(c for c in self.children if c in got and tr.key in got[c].by_key)
            if not avail:
                continue
            kind = self._kind(tr)
            w, s, z = self._weights(kind, avail, int(request.now))
            self.ctx.log(f"hourly {tr.key}: scale={s:.2f} zero={z:.2f} "
                         + ", ".join(f"{c}={x:.3f}" for c, x in zip(avail, w)))
            S = np.stack([sorted_samples(np.asarray(got[c].by_key[tr.key].paths, np.float64), tr.n_paths)
                          for c in avail])
            out[tr.key] = TargetForecast(_shape(np.tensordot(w, S, axes=1), s, z))
        return Forecast(out)

    # ---- ledger ----------------------------------------------------------
    @staticmethod
    def _kind(tr) -> str:
        return f"{tr.target.value}:{tr.family or 'all'}"

    def _add(self, child, request, forecast) -> int:
        n = 0
        for tr in request.targets:
            if tr.target not in HOURLY:
                continue
            tf = forecast.by_key.get(tr.key)
            if tf is None:
                continue
            p = np.asarray(tf.paths, dtype=np.float64)
            if p.ndim != 2 or p.shape[1] != len(tr.grid) or not np.isfinite(p).all():
                continue
            k = (int(request.now), tr.key)
            g = self.groups.get(k)
            if g is None:
                what = "spend" if tr.target is Target.SPEND_HOURLY else "tokens"
                g = self.groups[k] = Group(int(request.now), tr.key, self._kind(tr), tuple(tr.accounts),
                                           what, tr.family)
            g.entries[child] = Entry(np.asarray(tr.grid, np.int64),
                                     sorted_samples(p, self.m_fit).astype(np.float32))
            n += 1
        return n

    def _score(self) -> None:
        if self.turns is None:
            return
        now = int(self.turns.now)
        for g in self.groups.values():
            if not g.entries:
                continue
            grid = next(iter(g.entries.values())).grid
            done = grid[(grid <= now) & (grid > g.origin)]
            if len(done) == len(g.times):
                continue
            g.times = done.astype(np.int64)
            g.y = self.turns.hour_sums(g.times, g.accounts, g.what, g.family)

    def _weights(self, kind, children, now):
        groups = [g for g in self.groups.values()
                  if g.kind == kind and len(g.y) and g.origin < now and all(c in g.entries for c in children)]
        k = len(children)
        eq = np.full(k, 1.0 / k)
        npts = int(sum(len(g.y) for g in groups))
        if npts < self.min_points:
            return eq, 1.0, 0.0
        origins = np.array([g.origin for g in groups], dtype=np.float64)
        newer = (origins[None, :] > origins[:, None]).sum(axis=1).astype(np.float64)
        disc = 0.5 ** (newer / max(self.half_life, 1e-6))
        # One array over every scored hour: everything below is vectorised.
        X = np.concatenate([np.stack([g.x(c) for c in children]) for g in groups], axis=2)   # [k, m, E]
        y = np.concatenate([g.y for g in groups])
        pw = np.concatenate([np.full(len(g.y), d) for g, d in zip(groups, disc)])
        pw = pw / pw.sum()
        a = (np.abs(X - y[None, None, :]).mean(axis=1) * pw[None, :]).sum(axis=1)
        D = np.zeros((k, k))
        for i in range(k):
            D[i, i] = 2.0 * float((_half_gini(X[i]) * pw).sum())
            for j in range(i + 1, k):
                v = float((np.abs(X[i][:, None, :] - X[j][None, :, :]).mean(axis=(0, 1)) * pw).sum())
                D[i, j] = D[j, i] = v
        scale0 = max(float(a.mean()), 1e-9)

        def fun(w):
            return (a @ w - 0.5 * w @ D @ w) / scale0 + self.shrink * ((w - eq) ** 2).sum()
        w = _simplex_min(fun, k)
        q = np.tensordot(w, X, axes=1)
        best, best_s, best_z = None, 1.0, 0.0
        for s in self.scales:
            pen = 1.0 + self.scale_shrink * (np.log(s) ** 2)
            for z in self.zeros:
                loss = _wcrps(_shape(q, s, z), y, pw) * pen
                if best is None or loss < best:
                    best, best_s, best_z = loss, float(s), float(z)
        return w, best_s, best_z
