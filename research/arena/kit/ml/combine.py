"""Combining children's meter forecasts.

**The ledger.** Every child forecast a combiner sees, from `ctx.backtest`
(made over the parent's past without hindsight) or from its own calls during
the episode, is kept as m sorted samples per grid time. At each forecast the
ledger scores every kept forecast on the readings known *now* that came after
its origin, in its cycle, up to the reset (the scorer's truth, thinned to at
most `max_evals` readings per forecast): so the weights only ever use truth
that has arrived, and they move as more of it does (`update` brings it).

**Weights**, per target kind (five-hour, seven-day, each scoped cap):
- `ewa_weights`: exponentially weighted averaging, w ∝ exp(-η Σ discounted
  relative losses), forgetting old forecasts as newer ones are scored;
- `stack_weights`: the simplex weights minimizing the combination's own
  CRPS over the scored forecasts (exact for a mixture: a convex quadratic;
  for a quantile average: the CRPS of the averaged samples);
- `FformaWeights`: a softmax-linear map from as-of features (and the
  children's disagreement) to weights, trained on the scored forecasts with
  FFORMA's loss (the weights' expected relative loss);
- the median combiner has no weights.

**Pools** turn weights and children's paths into paths: `mixture` (draw paths
from each child in proportion to its weight: a linear pool) or `quantile`
(average the children's sorted samples level by level: Vincentization).

A relative loss is a child's CRPS on a forecast divided by the mean over the
children present on it, so forecasts with very different scales (a quiet
hour, a burst) count alike. A child that failed on a forecast others answered
takes the worst loss there.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from arena.types import Forecast, Target, TargetForecast
from kit.ml.data import HOUR_MS, AsOfData
from kit.ml.features import F, FeatureBuilder
from kit.ml.paths import crps_sorted, sorted_samples

METER = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day", Target.METER_SCOPED: "weekly_scoped"}
METER_TARGETS = tuple(METER)


def kind_of(target: Target, cap: str | None) -> str:
    w = METER[target]
    return f"{w}:{cap}" if w == "weekly_scoped" else w


@dataclass
class Entry:
    child: str
    origin: int
    key: str
    kind: str
    target: Target
    account: str
    cap: str | None
    reset: int
    grid: np.ndarray
    q: np.ndarray           # [m, G] float32, sorted per grid time


@dataclass
class Group:
    """Every child's forecast of one target key from one origin, and its
    truth so far."""

    origin: int
    key: str
    kind: str
    target: Target
    account: str
    cap: str | None
    reset: int
    entries: dict[str, Entry] = field(default_factory=dict)
    times: np.ndarray = field(default_factory=lambda: np.zeros(0, np.int64))
    y: np.ndarray = field(default_factory=lambda: np.zeros(0))
    scored_at: int | None = None
    final: bool = False
    _x: dict = field(default_factory=dict)

    def x(self, child: str) -> np.ndarray:
        """[m, E]: the child's sorted samples read at the truth times."""
        if child not in self._x:
            e = self.entries[child]
            g = e.grid.astype(np.float64)
            t = self.times.astype(np.float64)
            self._x[child] = np.stack([np.interp(t, g, row) for row in e.q.astype(np.float64)])
        return self._x[child]

    def coverage(self) -> float:
        """How much of the forecast's span (origin to reset) the truth so far
        covers: a forecast scored only on its first hour says little about
        how it reads a whole cycle, so learners weight groups by this."""
        if self.final:
            return 1.0
        if self.scored_at is None or self.reset <= self.origin:
            return 0.0
        return float(np.clip((min(self.scored_at, self.reset) - self.origin) / (self.reset - self.origin), 0.0, 1.0))

    def losses(self, children: list[str]) -> np.ndarray:
        """Mean CRPS per child (NaN when the child has no forecast here)."""
        out = np.full(len(children), np.nan)
        for i, c in enumerate(children):
            if c in self.entries:
                out[i] = float(crps_sorted(self.x(c), self.y).mean())
        return out


class Ledger:
    def __init__(self, m: int = 40, max_evals: int = 16):
        self.m, self.max_evals = m, max_evals
        self.groups: dict[tuple[int, str], Group] = {}

    def add(self, child: str, request, forecast: Forecast) -> int:
        n = 0
        for tr in request.targets:
            if tr.target not in METER:
                continue
            tf = forecast.by_key.get(tr.key)
            if tf is None or tr.reset_at is None:
                continue
            p = np.asarray(tf.paths, dtype=np.float64)
            if p.ndim != 2 or p.shape[1] != len(tr.grid) or not np.isfinite(p).all():
                continue
            k = (int(request.now), tr.key)
            g = self.groups.get(k)
            if g is None:
                g = self.groups[k] = Group(int(request.now), tr.key, kind_of(tr.target, tr.cap), tr.target,
                                           tr.accounts[0], tr.cap, int(tr.reset_at))
            g.entries[child] = Entry(child, int(request.now), tr.key, g.kind, tr.target, tr.accounts[0], tr.cap,
                                     int(tr.reset_at), np.asarray(tr.grid, np.int64),
                                     sorted_samples(p, self.m).astype(np.float32))
            g._x.pop(child, None)
            g.scored_at = None
            n += 1
        return n

    def score(self, data: AsOfData) -> None:
        """Truth for every group from the readings known at data.now."""
        now = data.now
        for g in self.groups.values():
            if g.final or g.scored_at == now:
                continue
            s = data.meter(g.account, METER[g.target], g.cap)
            if s is None:
                continue
            idx = s.cycle_readings(g.reset, now, upto=min(g.reset, now))
            idx = idx[s.te[idx] > g.origin]
            if len(idx) > self.max_evals:
                idx = idx[np.unique(np.linspace(0, len(idx) - 1, self.max_evals).round().astype(int))]
            g.times, g.y = s.te[idx].astype(np.int64), s.util[idx].astype(np.float64)
            g._x = {}
            g.scored_at = now
            g.final = g.reset <= now - 10 * 60_000

    def scored(self, kind: str, before: int) -> list[Group]:
        return [g for g in self.groups.values() if g.kind == kind and len(g.y) and g.origin < before]


def relative_losses(groups: list[Group], children: list[str], floor: float = 0.25) -> np.ndarray:
    """[groups, children] CRPS / the mean over the children present (at
    least `floor` points, so a quiet hour where every child is within a
    hair of the truth doesn't count as a decisive win); a missing child
    takes the worst present loss. Rows with no child present are NaN."""
    L = np.stack([g.losses(children) for g in groups]) if groups else np.zeros((0, len(children)))
    out = np.full_like(L, np.nan)
    for i, row in enumerate(L):
        ok = np.isfinite(row)
        if not ok.any():
            continue
        r = row / max(float(row[ok].mean()), floor)
        out[i] = np.where(ok, r, np.nanmax(r[ok]))
    return out


def discount(groups: list[Group], now: int, half_life: float) -> np.ndarray:
    """Each group's weight in learning: halves every `half_life` newer
    forecasts of its kind (forgetting by evidence, not by the clock: with
    nothing new to learn from, old evidence keeps its say), times the share
    of its span the truth covers."""
    if not groups:
        return np.zeros(0)
    origins = np.array([g.origin for g in groups], dtype=np.int64)
    newer = (origins[None, :] > origins[:, None]).sum(axis=1).astype(np.float64)
    cov = np.array([g.coverage() for g in groups], dtype=np.float64)
    return 0.5 ** (newer / max(half_life, 1e-6)) * cov


# ---------------------------------------------------------------------------
# Weights
# ---------------------------------------------------------------------------

def ewa_weights(groups: list[Group], children: list[str], now: int, *, eta: float = 0.5,
                half_life: float = 24.0) -> np.ndarray:
    k = len(children)
    if not groups:
        return np.full(k, 1.0 / k)
    R = relative_losses(groups, children)
    ok = np.isfinite(R).all(axis=1)
    if not ok.any():
        return np.full(k, 1.0 / k)
    d = discount(groups, now, half_life)[ok]
    S = (d[:, None] * R[ok]).sum(axis=0)
    z = -eta * (S - S.min())
    w = np.exp(z)
    return w / w.sum()


def _simplex_min(fun, k: int, x0: np.ndarray | None = None) -> np.ndarray:
    from scipy.optimize import minimize
    x0 = np.full(k, 1.0 / k) if x0 is None else x0
    if k == 1:
        return np.ones(1)
    res = minimize(fun, x0, method="SLSQP", bounds=[(0.0, 1.0)] * k,
                   constraints=[{"type": "eq", "fun": lambda w: w.sum() - 1.0}],
                   options={"maxiter": 200, "ftol": 1e-10})
    w = np.clip(res.x if res.success or np.isfinite(res.x).all() else x0, 0.0, None)
    return w / w.sum() if w.sum() > 0 else np.full(k, 1.0 / k)


def stack_weights(groups: list[Group], children: list[str], now: int, *, pool: str = "mixture",
                  half_life: float = 48.0, shrink: float = 0.05) -> np.ndarray:
    """Simplex weights minimizing the discounted mean CRPS of the pooled
    forecast over the scored groups where every child answered, plus
    `shrink` × mean loss × ||w - 1/k||² toward equal weights."""
    k = len(children)
    full = [g for g in groups if all(c in g.entries for c in children)]
    if not full or k == 1:
        return np.full(k, 1.0 / k)
    d = discount(full, now, half_life)
    if d.sum() <= 0:
        return np.full(k, 1.0 / k)
    d = d / d.sum()
    eq = np.full(k, 1.0 / k)
    if pool == "mixture":
        a = np.zeros(k)
        D = np.zeros((k, k))
        for wg, g in zip(d, full):
            X = [g.x(c) for c in children]
            a += wg * np.array([np.abs(x - g.y[None, :]).mean() for x in X])
            for i in range(k):
                for j in range(i + 1, k):
                    v = np.abs(X[i][:, None, :] - X[j][None, :, :]).mean()
                    D[i, j] += wg * v
                    D[j, i] += wg * v
                D[i, i] += wg * float((2 * _half_gini(X[i])).mean())      # E|X_i - X_i'|
        scale = max(float(a.mean()), 1e-6)
        return _simplex_min(lambda w: (a @ w - 0.5 * w @ D @ w) / scale + shrink * ((w - eq) ** 2).sum(), k)
    Xs = [(wg, np.stack([g.x(c) for c in children]), g.y) for wg, g in zip(d, full)]   # [k, m, E]
    scale = max(float(np.mean([np.abs(X - y).mean() for _, X, y in Xs])), 1e-6)

    def fun(w):
        return sum(wg * crps_sorted(np.tensordot(w, X, axes=1), y).mean() for wg, X, y in Xs) / scale \
            + shrink * ((w - eq) ** 2).sum()
    return _simplex_min(fun, k)


def _half_gini(x: np.ndarray) -> np.ndarray:
    """E|X - X'| / 2 per column of sorted samples [m, E]."""
    m = x.shape[0]
    w = (2 * np.arange(1, m + 1) - m - 1)[:, None]
    return (w * x).sum(axis=0) / (m * m)


FFORMA_FEATURES = ("elapsed_frac", "remaining_h", "used_now", "rate_1", "conv_rate_1", "nowcast_gap",
                   "act_frac_left", "hod_sin", "hod_cos", "idle_h", "past_phase_rise", "since_last_h")


def _transform(row: np.ndarray) -> np.ndarray:
    v = np.array([row[F[n]] for n in FFORMA_FEATURES], dtype=np.float64)
    v[1] = np.log1p(v[1])        # remaining hours
    v[3] = np.log1p(max(v[3], 0))
    v[4] = np.log1p(max(v[4], 0))
    v[9] = v[9] / 48.0
    v[11] = np.log1p(max(v[11], 0))
    return v


class FformaWeights:
    """Softmax-linear weights from as-of features (FFORMA's meta-learner,
    with a linear map instead of boosted trees: there are tens of scored
    forecasts per episode, not thousands of series)."""

    def __init__(self, children: list[str], kinds: list[str], *, lam: float = 1.0, half_life: float = 48.0):
        self.children, self.kinds = children, kinds
        self.lam, self.half_life = lam, half_life
        self.W = None
        self.mu = self.sd = None

    def features(self, data: AsOfData, builders: dict, kind: str, target: Target, account: str,
                 cap: str | None, at: int, reset: int, spread: float) -> np.ndarray | None:
        w = METER[target]
        s = data.meter(account, w, cap)
        if s is None:
            return None
        b = builders.setdefault(w, FeatureBuilder(data, w))
        row = b.row(s, at, reset)
        if row is None:
            return None
        onehot = [1.0 if kind == k else 0.0 for k in self.kinds]
        return np.concatenate([_transform(row), [np.log1p(max(spread, 0.0))], onehot])

    @staticmethod
    def spread(qs: list[np.ndarray]) -> float:
        """The children's disagreement: std of their medians at the end."""
        if len(qs) < 2:
            return 0.0
        med = [q[q.shape[0] // 2, -1] for q in qs]
        return float(np.std(med))

    def fit(self, X: np.ndarray, R: np.ndarray, d: np.ndarray) -> None:
        from scipy.optimize import minimize
        k = len(self.children)
        self.mu = X.mean(axis=0)
        self.sd = np.where(X.std(axis=0) > 1e-9, X.std(axis=0), 1.0)
        Z = np.hstack([(X - self.mu) / self.sd, np.ones((len(X), 1))])
        p = Z.shape[1]
        d = d / d.sum() if d.sum() > 0 else np.full(len(X), 1.0 / len(X))

        def fun(theta):
            W = theta.reshape(k, p)
            s = Z @ W.T
            s = s - s.max(axis=1, keepdims=True)
            P = np.exp(s)
            P /= P.sum(axis=1, keepdims=True)
            Lrow = (P * R).sum(axis=1)
            loss = (d * Lrow).sum() + self.lam * (W ** 2).sum() / len(X)
            G = d[:, None] * P * (R - Lrow[:, None])                    # dL/ds
            grad = G.T @ Z + 2 * self.lam * W / len(X)
            return loss, grad.ravel()
        res = minimize(fun, np.zeros(k * p), jac=True, method="L-BFGS-B", options={"maxiter": 300})
        self.W = res.x.reshape(k, p)

    def weights(self, x: np.ndarray | None) -> np.ndarray:
        k = len(self.children)
        if self.W is None or x is None:
            return np.full(k, 1.0 / k)
        z = np.concatenate([(x - self.mu) / self.sd, [1.0]])
        s = self.W @ z
        s = np.exp(s - s.max())
        return s / s.sum()


# ---------------------------------------------------------------------------
# Pools
# ---------------------------------------------------------------------------

def pool_mixture(paths: list[np.ndarray], w: np.ndarray, n: int, rng: np.random.Generator) -> np.ndarray:
    """A linear pool: round(w_i n) of child i's own paths (largest remainder)."""
    w = np.asarray(w, dtype=np.float64)
    raw = w * n
    cnt = np.floor(raw).astype(int)
    rest = n - cnt.sum()
    if rest > 0:
        cnt[np.argsort(-(raw - cnt), kind="stable")[:rest]] += 1
    out = []
    for P, c in zip(paths, cnt):
        if c <= 0:
            continue
        idx = rng.choice(len(P), size=c, replace=c > len(P))
        out.append(P[idx])
    return np.vstack(out)


def pool_quantile(paths: list[np.ndarray], w: np.ndarray, n: int) -> np.ndarray:
    """Vincentization: the weighted average of the children's quantiles at
    n levels per grid time; row j is the j-th quantile curve (comonotone)."""
    return np.tensordot(np.asarray(w, dtype=np.float64), np.stack([sorted_samples(P, n) for P in paths]), axes=1)


def pool_median(paths: list[np.ndarray], n: int) -> np.ndarray:
    """Per grid time and level, the median of the children's quantiles."""
    return np.median(np.stack([sorted_samples(P, n) for P in paths]), axis=0)


def pool(kind: str, paths: list[np.ndarray], w: np.ndarray, n: int, rng: np.random.Generator) -> np.ndarray:
    if kind == "quantile":
        return pool_quantile(paths, w, n)
    if kind == "median":
        return pool_median(paths, n)
    return pool_mixture(paths, w, n, rng)


# ---------------------------------------------------------------------------
# The combiner model
# ---------------------------------------------------------------------------

class Combiner:
    """Duck-typed arena model over children named in config `children` (else
    every declared child). Subclasses set `rule` and may override
    `weights_for`. Config: `pool` (mixture | quantile | median),
    `backtest_every_h`, `backtest_n`, `backtest` (bool), `m`, `max_evals`, `half_life_n`
    (forgetting in forecasts of a kind: {window: n} or a number)."""

    rule = "equal"
    default_pool = "mixture"
    uses_backtest = True

    def __init__(self, ctx):
        self.ctx = ctx
        self.cfg = dict(ctx.config)
        self.children = [str(c) for c in (self.cfg.get("children") or getattr(ctx, "children", ()) or ())]
        if not self.children:
            raise ValueError("a combiner needs children (model.toml `children`, config `children`)")
        self.rng = ctx.rng
        self.pool_kind = str(self.cfg.get("pool", self.default_pool))
        self.ledger = Ledger(int(self.cfg.get("m", 40)), int(self.cfg.get("max_evals", 16)))
        self.data: AsOfData | None = None
        self.last_weights: dict[str, dict[str, float]] = {}

    def half_life(self, kind: str) -> float:
        """Forgetting, in forecasts of the kind (config `half_life_n`: a
        number, or {window: n})."""
        v = self.cfg.get("half_life_n", 24.0)
        if isinstance(v, dict):
            return float(v.get(kind.split(":")[0], 24.0))
        return float(v)

    # contract ------------------------------------------------------------
    def fit(self, history):
        self.data = AsOfData.from_history(history)
        if not (self.uses_backtest and self.cfg.get("backtest", True)):
            return
        n = self.cfg.get("backtest_n")
        for every, targets in self.backtest_plan():
            # The latest `backtest_n` origins (the runner caps them at 48): each
            # one is a fresh fit of every child, which a heavy child pays for.
            # On a fixed lattice, so episodes share origins (and the child cache).
            since = (self.data.now - int(n) * every) // every * every if n else None
            for c in self.children:
                try:
                    items = self.ctx.backtest(c, every=every, targets=targets, since=since)
                except Exception as e:  # noqa: BLE001 - a child without a backtest just starts unweighted
                    self.ctx.log(f"backtest {c}: {type(e).__name__}: {str(e)[:200]}")
                    continue
                added = sum(self.ledger.add(c, req, fc) for req, fc in items)
                self.ctx.log(f"backtest {c} every {every / HOUR_MS:g}h: {len(items)} origins, {added} forecasts")

    def backtest_plan(self) -> list[tuple[int, tuple[Target, ...]]]:
        """(every, targets) per backtest call. Weekly meters need origins
        spread over more than a cycle, or none of their truth is complete
        (the runner keeps the latest 48 origins)."""
        v = self.cfg.get("backtest_every_h", {"five_hour": 2, "seven_day": 8, "weekly_scoped": 8})
        if not isinstance(v, dict):
            v = {w: v for w in METER.values()}
        by: dict[int, list[Target]] = {}
        for t, w in METER.items():
            if w in v:
                by.setdefault(int(float(v[w]) * HOUR_MS), []).append(t)
        return [(e, tuple(ts)) for e, ts in sorted(by.items())]

    def update(self, events):
        self.data = self.data.extend(events, events.until)

    def forecast(self, request):
        got: dict[str, Forecast] = {}
        for c in self.children:
            try:
                got[c] = self.ctx.model(c).forecast(request)
            except Exception as e:  # noqa: BLE001 - a failing child is left out of this forecast
                self.ctx.log(f"child {c} failed: {type(e).__name__}: {str(e)[:200]}")
                continue
            self.ledger.add(c, request, got[c])
        self.ledger.score(self.data)
        out = {}
        for tr in request.targets:
            if tr.target not in METER:
                continue
            avail = [c for c in self.children if c in got and tr.key in got[c].by_key]
            if not avail:
                out[tr.key] = self._flat(tr)
                continue
            paths = [np.asarray(got[c].by_key[tr.key].paths, dtype=np.float64) for c in avail]
            kind = kind_of(tr.target, tr.cap)
            w = self.weights_for(kind, tr, avail, paths, request.now)
            self.last_weights[tr.key] = dict(zip(avail, map(float, w)))
            self.ctx.log(f"weights {tr.key} @{request.now}: "
                         + ", ".join(f"{c}={x:.3f}" for c, x in zip(avail, w)))
            P = pool(self.pool_kind, paths, w, tr.n_paths, self.rng)
            out[tr.key] = TargetForecast(np.clip(P, 0.0, 100.0))
        return Forecast(out)

    def _flat(self, tr) -> TargetForecast:
        s = self.data.meter(tr.accounts[0], METER[tr.target], tr.cap) if self.data else None
        lvl = s.level_at(self.data.now)[0] if s is not None else 0.0
        return TargetForecast.point(np.full(len(tr.grid), lvl), tr.n_paths)

    def weights_for(self, kind, tr, children, paths, now) -> np.ndarray:
        return np.full(len(children), 1.0 / len(children))
