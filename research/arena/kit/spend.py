"""Spend and the live meter, as of a moment: the shared helpers behind the
app's live meter and every model that turns spend into meter points.

Pinned as signatures before the phase-2 build so several builders can code
against them at once; the P2-spend builder implements them. Every function
takes a `History` and uses only what it holds (rows known by `history.now`),
so nothing here can leak the future.

How each one maps onto the app (PacerCore/Sources/PacerCore/LiveMeter/):

- `fit_conversion` is SpendMeterFit (#317) in the per-family form of an
  earlier, unpublished lab: non-negative least squares of each
  pair of consecutive readings' rise on what each model family spent between
  them, no intercept, over the 14 local days before now's day began. The app
  fits per model per local hour with an intercept; the pinned contract is the
  lab's interval form, which needs no hour bucketing and keeps the fit a pure
  function of the history. The weak-fit gate's R² is the app's, though: per
  local hour over active hours (`hourly_r2`), because per interval a
  densely polled whole-point meter scores a low R² even when the fit is good.
- `live_value` is `LiveMeter.estimate` + `LiveMeterValue.shownPercent` (#318):
  the reading, the carry (where inside its whole point the meter sat), the
  held-tick guard, the reset restart, flooring, and the tenths shown.
- `current_cycle` is `RateLimitCycle.contains` through
  `arena.snapshot.cycles` (never `==` on resets: they jitter).

Spend is priced at the rates known at `now` (`arena.pricing`), with the best
output (an imputation where the recorded output is known to be unreliable,
and only once that imputation is known), because that is what the scorer's
truth counts. A turn with no known rate counts as no spend here (its cost is
null, never 0, in `price_turns`).

Everything expensive is computed once per `History` object (a `History` is
read-only), so calling these from a model's `forecast` many times is cheap.
"""
from __future__ import annotations

import math
import threading
import weakref
from dataclasses import dataclass, field

import numpy as np
import polars as pl
from scipy.optimize import nnls

from arena.pricing import SYNTHETIC_MODEL
from arena.pricing import price_turns as _price_turns
from arena.snapshot import cycles as _cycles
from arena.types import History, Millis

FAMILIES = ("fable", "opus", "sonnet", "haiku", "other")

HOUR_MS = 3_600_000
DAY_MS = 24 * HOUR_MS

# SpendMeterFit, as the earlier (unpublished) lab replayed it.
SPAN_DAYS = 14            # trailing whole days per fit
MIN_OWN = 100             # the account's own intervals needed to fit on them alone
MIN_RISE = 20.0           # LiveMeter.minFitRise: below this a fit is weak
MIN_R2 = 0.5              # LiveMeter.minFitR2
MIN_POOLED_SPEND = 1.0    # USD: below this there is nothing to fit
MIN_FAMILY_SPEND = 1.0    # USD: a family that spent less keeps the pooled rate
MAX_PAIR_GAP_MS = HOUR_MS  # SpendMeterFitter.maxPairGap

# LiveMeter (#318).
MAX_READING_AGE_MS = HOUR_MS        # LiveMeter.maxReadingAge
CARRY_LOOKBACK_MS = HOUR_MS         # LiveMeter.carryLookback
CARRY_POSITION = 0.25               # LiveMeter.carryPosition
CARRY_MOVED_WEIGHT = 0.5            # LiveMeter.carryMovedWeight
STALE_HELD_POINTS = 2.0             # LiveMeter.staleHeldPoints
MAX_SERVER_LAG_MS = 10 * 60_000     # LiveMeter.maxServerLag
FLOOR_TOLERANCE = 1e-9              # LiveMeter.floorTolerance


# ---------------------------------------------------------------------------
# Per-History memo
# ---------------------------------------------------------------------------

_MEMO: "weakref.WeakKeyDictionary" = weakref.WeakKeyDictionary()
_LOCK = threading.Lock()     # in-process workers are threads of one process


def _memo(history, key, make):
    """`make()` once per (history object, key). A History is read-only, so its
    derived values never go stale; objects that can't be weakly referenced
    (a test's stand-in) just recompute."""
    try:
        with _LOCK:
            store = _MEMO.get(history)
            if store is None:
                store = {}
                _MEMO[history] = store
            if key in store:
                return store[key]
    except TypeError:
        return make()
    value = make()
    with _LOCK:
        return store.setdefault(key, value)


def _family_index(col: pl.Series) -> np.ndarray:
    idx = {f: i for i, f in enumerate(FAMILIES)}
    other = idx["other"]
    return np.array([idx.get(f, other) if f is not None else other for f in col.to_list()], dtype=np.int64)


def _cap_family(scope_model: str | None) -> str | None:
    """The family a per-model cap counts (`SpendMeterFitter.capCounts`): the
    Fable weekly cap arrives as "Fable" and only Fable spend moves it. None
    when the cap names no family we know (every family counts)."""
    if not scope_model:
        return None
    s = scope_model.strip().lower()
    for f in FAMILIES[:-1]:
        if f in s:
            return f
    return None


def _counted(scope_model: str | None) -> np.ndarray:
    """Which family columns can move this meter."""
    fam = _cap_family(scope_model)
    if fam is None:
        return np.ones(len(FAMILIES), dtype=bool)
    return np.array([f == fam for f in FAMILIES], dtype=bool)


# ---------------------------------------------------------------------------
# Spend
# ---------------------------------------------------------------------------

def price_turns(history: History, accounts: tuple[str, ...] | None = None) -> pl.DataFrame:
    """Turns known by now (optionally for some accounts) with a `cost` column
    priced at the rates known by now (`arena.pricing`); null when no rate was
    known yet, never 0.

    `cost` uses the best output (the imputed value where the recorded one is
    unreliable and the imputation is already known), like the scorer's truth;
    `cost_usd` and `price_flag` from `arena.pricing` are kept alongside."""
    def make():
        t = history.table("turns")
        priced = _price_turns(t, history.table("prices"), as_of=history.now, output="best")
        return priced.with_columns(pl.col("cost_usd").alias("cost"))
    df = _memo(history, ("priced",), make)
    if accounts is not None:
        df = df.filter(pl.col("account").is_in(list(accounts)))
    return df


class PriceCache:
    """Turns priced across Histories: each turn priced once per model
    instance, not once per forecast. `price_turns` memoizes per History
    object, which is enough for a model that keeps one; a model that re-fits
    on a new History at every checkpoint (`extend`) would re-price two weeks
    of turns each time without this. A turn is re-priced when anything its
    cost depends on changes (a streamed output upgrade, a geo/speed patch),
    and everything is re-priced when the price table known at now changes.
    `price(turns, history)` adds `cost_usd` (rates known at history.now, best
    output; null when no rate was known)."""

    COST_COLS = ("call_id", "model", "input", "output", "output_reliable", "output_imputed", "cache_read",
                 "cache_write_5m", "cache_write_1h", "inference_geo", "speed")

    def __init__(self):
        self.version = None
        self.costs = pl.DataFrame(schema={"_k": pl.UInt64, "cost_usd": pl.Float64})

    def price(self, turns: pl.DataFrame, history) -> pl.DataFrame:
        prices = history.table("prices")
        # The rates in force as of `history.now`: what decides every cost.
        known = prices["t_known"].dt.epoch("ms") <= int(history.now) if prices.height else None
        version = (int(known.sum()), int(prices["t_known"].dt.epoch("ms").filter(known).max() or 0)) \
            if prices.height else (0, 0)
        if version != self.version:
            self.version = version
            self.costs = self.costs.clear()
        t = turns.with_columns(pl.struct(list(self.COST_COLS)).hash(seed=0).alias("_k"))
        t = t.join(self.costs, on="_k", how="left")
        todo = t.filter(pl.col("cost_usd").is_null()).drop("cost_usd")
        if todo.height:
            done = _price_turns(todo.drop("_k"), prices, as_of=history.now, output="best")
            done = done.with_columns(todo["_k"]).select("_k", "cost_usd")
            self.costs = pl.concat([self.costs, done.unique("_k")]).unique("_k", keep="last")
            t = t.drop("cost_usd").join(self.costs, on="_k", how="left")
        return t.drop("_k")


@dataclass(frozen=True)
class _Ledger:
    """One account's turns as cumulative sums by family, for O(log n) range
    sums over (t0, t1] by t_event. Synthetic turns are left out; unpriced
    turns add no spend (but their tokens count)."""

    t: np.ndarray            # int64 t_event, sorted
    cost: np.ndarray         # [n + 1, families] cumulative USD
    tokens: np.ndarray       # [n + 1, families] cumulative tokens
    fam: np.ndarray          # family index per turn
    unit_cost: np.ndarray    # USD per turn (0 when unpriced)

    def between(self, t0, t1, what: str = "spend") -> np.ndarray:
        """Per family over each (t0, t1]: [len, families]."""
        t0 = np.atleast_1d(np.asarray(t0, dtype=np.int64))
        t1 = np.atleast_1d(np.asarray(t1, dtype=np.int64))
        c = self.cost if what == "spend" else self.tokens
        return c[np.searchsorted(self.t, t1, "right")] - c[np.searchsorted(self.t, t0, "right")]


_EMPTY = _Ledger(np.zeros(0, np.int64), np.zeros((1, len(FAMILIES))), np.zeros((1, len(FAMILIES))),
                 np.zeros(0, np.int64), np.zeros(0))


def _ledger(history: History, account: str) -> _Ledger:
    def make():
        p = price_turns(history).filter((pl.col("account") == account) & (pl.col("model") != SYNTHETIC_MODEL))
        if p.height == 0:
            return _EMPTY
        p = p.sort("t_event", maintain_order=True)
        t = p["t_event"].dt.epoch("ms").to_numpy().astype(np.int64)
        fam = _family_index(p["model_family"])
        cost = p["cost"].fill_null(0.0).fill_nan(0.0).to_numpy().astype(np.float64)
        out_best = (pl.when((pl.col("output_reliable") == False) & pl.col("output_imputed").is_not_null())  # noqa: E712
                    .then(pl.col("output_imputed")).otherwise(pl.col("output").cast(pl.Float64)))
        tok = p.select((pl.col("input").cast(pl.Float64).fill_null(0) + out_best.fill_null(0)
                        + pl.col("cache_read").cast(pl.Float64).fill_null(0)
                        + pl.col("cache_write_5m").cast(pl.Float64).fill_null(0)
                        + pl.col("cache_write_1h").cast(pl.Float64).fill_null(0)).alias("x"))["x"]
        tok = tok.to_numpy().astype(np.float64)
        n = len(t)
        C = np.zeros((n + 1, len(FAMILIES)))
        K = np.zeros((n + 1, len(FAMILIES)))
        np.add.at(C[1:], (np.arange(n), fam), cost)
        np.add.at(K[1:], (np.arange(n), fam), tok)
        return _Ledger(t, np.cumsum(C, axis=0), np.cumsum(K, axis=0), fam, cost)
    return _memo(history, ("ledger", account), make)


def hourly_series(
    history: History, accounts: tuple[str, ...], hours: int,
    what: str = "spend", family: str | None = None,
) -> tuple[np.ndarray, np.ndarray]:
    """The last `hours` whole hours before now: (hour_end_ms int64, values
    float64), spend in USD (priced as of now) or tokens, optionally one model
    family. Hours with no turns are 0.

    The hours end at `now - k h` (k = hours-1 … 0), so the last one is
    (now - 1 h, now], aligned with the hourly targets' grid (`now + k h`): the
    value a seasonal model wants for grid time g is the hour ending g - 24 h.
    Turns are bucketed by t_event, like the truth; only turns known by now
    exist, so the latest hour may still be filling in. Tokens are input +
    output (best) + cache reads + both cache writes."""
    if what not in ("spend", "tokens"):
        raise ValueError(f"what must be 'spend' or 'tokens', not {what!r}")
    if family is not None and family not in FAMILIES:
        raise ValueError(f"unknown family {family!r}; one of {FAMILIES}")
    hours = int(hours)
    ends = history.now - HOUR_MS * np.arange(hours - 1, -1, -1, dtype=np.int64)
    vals = np.zeros(hours)
    cols = slice(None) if family is None else FAMILIES.index(family)
    for a in accounts:
        led = _ledger(history, a)
        if not len(led.t):
            continue
        per = led.between(ends - HOUR_MS, ends, what)
        vals += per.sum(axis=1) if family is None else per[:, cols]
    return ends, vals


def spent_between(history: History, account: str, t0, t1, what: str = "spend") -> np.ndarray:
    """USD (or tokens) per family over each (t0, t1], by t_event, priced as
    of now: [len, families] in FAMILIES order. O(log n) per range."""
    return _ledger(history, account).between(t0, t1, what)


# ---------------------------------------------------------------------------
# Meter readings
# ---------------------------------------------------------------------------

def _readings(history: History, account: str, window_kind: str, scope_model: str | None) -> dict:
    """One meter's readings known by now, sorted by (t_event, util) so two
    readings at one instant telescope upward (SpendMeterFitter.hourlyRise):
    t (int64), p (float), reset (int64, -1 when null), active (bool)."""
    def make():
        r = history.table("meter_readings").filter(
            (pl.col("account") == account) & (pl.col("window_kind") == window_kind))
        if scope_model is not None:
            r = r.filter(pl.col("scope_model") == scope_model)
        r = r.filter(pl.col("util_pct").is_not_null()).select(
            pl.col("t_event").dt.epoch("ms").alias("t"),
            pl.col("util_pct").cast(pl.Float64).alias("p"),
            pl.col("resets_at").dt.epoch("ms").alias("reset"),
            ((pl.col("state") == "active") & pl.col("resets_at").is_not_null()).fill_null(False).alias("active"),
        ).sort(["t", "p"], maintain_order=True)
        return {"t": r["t"].to_numpy().astype(np.int64), "p": r["p"].to_numpy().astype(np.float64),
                "reset": r["reset"].fill_null(-1).to_numpy().astype(np.int64),
                "active": r["active"].to_numpy().astype(bool)}
    return _memo(history, ("readings", account, window_kind, scope_model), make)


def meter_series(history: History, account: str, window_kind: str,
                 scope_model: str | None = None) -> dict[str, np.ndarray]:
    """One meter's readings known by now, sorted by (t_event, util): arrays
    `t` (int64 ms), `p` (util %), `reset` (int64 ms, -1 when idle), `active`."""
    return _readings(history, account, window_kind, scope_model)


@dataclass(frozen=True)
class PastCycle:
    """A cycle of one meter whose reset had passed by now."""

    reset: int               # the median of its readings' resets
    start: int               # reset - window
    t: np.ndarray            # its readings' t_event, ascending
    util: np.ndarray         # util as read (it can fall: an allowance reset mid-cycle)


def past_cycles(history: History, account: str, window_kind: str,
                scope_model: str | None = None) -> list[PastCycle]:
    """Every cycle of one meter that had reset by now, oldest first: active
    readings grouped by reset within half a window (`RateLimitCycle.contains`,
    never `==`)."""
    def make():
        r = _readings(history, account, window_kind, scope_model)
        act = r["active"]
        t, p, reset = r["t"][act], r["p"][act], r["reset"][act]
        if not len(t):
            return []
        dur = _cycles.window_ms(window_kind)
        o = np.argsort(reset, kind="stable")
        rs = reset[o]
        brk = np.flatnonzero(np.diff(rs) >= dur / 2) + 1
        out = []
        for g in np.split(o, brk):
            res = int(np.median(reset[g]))
            if res > history.now:
                continue
            g = g[np.argsort(t[g], kind="stable")]
            out.append(PastCycle(res, res - dur, t[g], p[g]))
        return sorted(out, key=lambda c: c.reset)
    return _memo(history, ("past_cycles", account, window_kind, scope_model), make)


@dataclass(frozen=True)
class Intervals:
    """Pairs of consecutive readings of one cycle (|Δreset| < half a window),
    under an hour apart, that did not fall, with what each family spent in
    between: the rows the conversion is fitted on."""

    account: np.ndarray      # str labels
    t0: np.ndarray           # int64
    t1: np.ndarray           # int64
    rise: np.ndarray         # float64 points
    spend: np.ndarray        # [n, families] USD over (t0, t1]

    def __len__(self) -> int:
        return len(self.t1)

    def take(self, m: np.ndarray) -> "Intervals":
        return Intervals(self.account[m], self.t0[m], self.t1[m], self.rise[m], self.spend[m])


def intervals(history: History, account: str, window_kind: str,
              scope_model: str | None = None) -> Intervals:
    """Every interval of one account's meter known by now (any time)."""
    def make():
        r = _readings(history, account, window_kind, scope_model)
        t, p, reset, act = r["t"], r["p"], r["reset"], r["active"]
        if len(t) < 2:
            z = np.zeros(0)
            return Intervals(np.zeros(0, dtype=object), z.astype(np.int64), z.astype(np.int64), z,
                             np.zeros((0, len(FAMILIES))))
        dur = _cycles.window_ms(window_kind)
        dt, rise = np.diff(t), np.diff(p)
        same = act[:-1] & act[1:] & (np.abs(np.diff(reset)) < dur / 2)
        ok = same & (dt > 0) & (dt < MAX_PAIR_GAP_MS) & (rise >= 0)
        t0, t1 = t[:-1][ok], t[1:][ok]
        sp = _ledger(history, account).between(t0, t1) if ok.any() else np.zeros((0, len(FAMILIES)))
        return Intervals(np.full(len(t1), account, dtype=object), t0, t1, rise[ok], sp)
    return _memo(history, ("intervals", account, window_kind, scope_model), make)


# ---------------------------------------------------------------------------
# The conversion (SpendMeterFit)
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Conversion:
    """Meter points per API-equivalent dollar, per model family, for one
    account and window: the port of the app's SpendMeterFit (#317)."""

    points_per_usd: dict[str, float]
    weak: bool          # rise < 20 points or R² < 0.5: the app shows no live value
    r2: float
    fitted_through: Millis

    def convert(self, spend_by_family: dict[str, float]) -> float:
        return sum(self.points_per_usd.get(f, 0.0) * v for f, v in spend_by_family.items())


@dataclass(frozen=True)
class FitDetails:
    """A conversion with the rows it was fitted on, for models that want its
    residuals or the pooled factor (e.g. a spread from the fit's own error)."""

    conversion: Conversion
    rates: np.ndarray        # points per USD per family, in FAMILIES order (as `points_per_usd`)
    pooled: float            # Σ rise ÷ Σ counted spend over the fit's rows
    own: bool                # fitted on the account's own intervals alone
    rows: Intervals          # the intervals fitted on
    fitted: np.ndarray       # rows.spend @ rates
    residuals: np.ndarray    # rows.rise - fitted
    rise: float              # Σ rise
    weak_reason: str | None = None
    extra: dict = field(default_factory=dict)


def tz_offset_ms(history: History, account: str | None = None) -> int:
    """The latest known `tz_offset_min` of the account's turns, in ms (any
    account's when it has none; 0, UTC, when nothing is known)."""
    def offset():
        t = history.table("turns")
        if not t.height:
            return 0
        for f in ((pl.col("account") == account), pl.lit(True)) if account else (pl.lit(True),):
            g = t.filter(f & pl.col("tz_offset_min").is_not_null())
            if g.height:
                return int(g.sort("t_event")["tz_offset_min"][-1]) * 60_000
        return 0
    return _memo(history, ("tz", account), offset)


def local_day_start(history: History, account: str | None = None, at: Millis | None = None) -> Millis:
    """The start of the local day containing `at` (default now), by
    `tz_offset_ms`. The app's fit runs per local calendar day
    (`SpendMeterFitter.span(endingAtStartOf:)`)."""
    off = tz_offset_ms(history, account)
    at = history.now if at is None else int(at)
    return int(math.floor((at + off) / DAY_MS) * DAY_MS - off)


def hourly_r2(rows: Intervals, X: np.ndarray, predicted: np.ndarray, offset_ms: int = 0) -> float:
    """The fit's R² the way the app scores it (`SpendMeterFitter.fit`): rise
    and prediction summed per account and local hour (an interval counts in
    the hour its later reading falls in, as the research harness credits
    it), over the active hours (any rise or any counted spend). Per interval
    the meter's whole-point steps make R² meaningless at a poll every few
    seconds: far below the hourly R² of the same fit, and under the 0.5 gate
    for a fit that explains most of every hour."""
    if not len(rows):
        return 0.0
    hour = (rows.t1 + offset_ms) // HOUR_MS
    _, acct = np.unique(rows.account.astype(str), return_inverse=True)
    _, inv = np.unique(np.stack([acct, hour]), axis=1, return_inverse=True)
    inv = inv.ravel()
    y = np.bincount(inv, rows.rise)
    p = np.bincount(inv, predicted)
    s = np.bincount(inv, X.sum(axis=1))
    act = (y > 0) | (s > 0)
    y, p = y[act], p[act]
    ss = float(((y - y.mean()) ** 2).sum()) if len(y) else 0.0
    return 1.0 - float(((y - p) ** 2).sum()) / ss if ss > 0 else 0.0


def _span_rows(history: History, account: str, window_kind: str, scope_model: str | None,
               day_start: Millis) -> tuple[Intervals, bool]:
    lo = day_start - SPAN_DAYS * DAY_MS

    def in_span(iv: Intervals) -> Intervals:
        return iv.take((iv.t1 <= day_start) & (iv.t1 > lo))
    own = in_span(intervals(history, account, window_kind, scope_model))
    if len(own) >= MIN_OWN:
        return own, True
    others = [in_span(intervals(history, a, window_kind, scope_model))
              for a in history.accounts if a != account]
    parts = [p for p in [own, *others] if len(p)]
    if not any(len(p) for p in others):
        return own, True                  # nobody else is visible: its own, however few
    return Intervals(np.concatenate([p.account for p in parts]), np.concatenate([p.t0 for p in parts]),
                     np.concatenate([p.t1 for p in parts]), np.concatenate([p.rise for p in parts]),
                     np.vstack([p.spend for p in parts])), False


def fit_on_day(history: History, account: str, window_kind: str, scope_model: str | None,
               day_start: Millis) -> FitDetails | None:
    """The fit the app would have made for the local day starting at
    `day_start`: intervals that ended in the 14 days before it. `day_start`
    may be any earlier day (walk-forward backtests); a day after now's day
    began is refused, since its span would end after now."""
    day_start = int(day_start)
    if day_start > local_day_start(history, account):
        raise ValueError("a fit's span must end by the start of now's day")

    def make():
        rows, own = _span_rows(history, account, window_kind, scope_model, day_start)
        if not len(rows):
            return None
        counted = _counted(scope_model)
        X = np.where(counted[None, :], rows.spend, 0.0)
        y = rows.rise
        total = float(X.sum())
        if total <= MIN_POOLED_SPEND:
            return None
        pooled = float(y.sum() / total)
        cols = np.flatnonzero(counted)
        coef = np.zeros(len(FAMILIES))
        coef[cols] = nnls(X[:, cols], y)[0] if len(y) else 0.0
        ss = float(((y - y.mean()) ** 2).sum())
        r2_interval = 1.0 - float(((y - X @ coef) ** 2).sum()) / ss if ss > 0 else 0.0
        r2 = hourly_r2(rows, X, X @ coef, tz_offset_ms(history, account))
        rise = float(y.sum())
        reason = None
        if rise < MIN_RISE:
            reason = f"rise {rise:.1f} < {MIN_RISE:.0f}"
        elif r2 < MIN_R2:
            reason = f"R² {r2:.2f} < {MIN_R2}"
        weak = reason is not None
        spent = X.sum(axis=0) > MIN_FAMILY_SPEND
        if weak:
            # The forecasters' fallback (the lab's tokc factor): one pooled
            # rate for every counted family. The live meter shows nothing.
            rates = np.where(counted, pooled, 0.0)
        else:
            rates = np.where(counted, np.where(spent, coef, pooled), 0.0)
        conv = Conversion({f: float(rates[i]) for i, f in enumerate(FAMILIES)}, weak, float(r2), day_start)
        fitted = X @ rates
        return FitDetails(conv, rates, pooled, own, rows, fitted, y - fitted, rise, reason,
                          {"nnls": coef, "spent": X.sum(axis=0), "r2_interval": r2_interval})
    return _memo(history, ("fit", account, window_kind, scope_model, day_start), make)


def fit_details(history: History, account: str, window_kind: str,
                scope_model: str | None = None) -> FitDetails | None:
    """`fit_conversion` with the rows behind it."""
    return fit_on_day(history, account, window_kind, scope_model, local_day_start(history, account))


def fit_conversion(
    history: History, account: str, window_kind: str, scope_model: str | None = None,
) -> Conversion | None:
    """NNLS of each reading interval's rise on what each family spent in it,
    no intercept, over the 14 days ending at the start of now's day (refit
    daily, no peeking); the account's own intervals when it has 100, else
    every visible account's. None when there is nothing to fit.

    R² is the app's: per local hour over the active hours (`hourly_r2`),
    not per interval, where the meter's whole-point steps keep it low even
    for a good fit (the per-interval value is in `fit_details().extra`).

    Weak (rise under 20 points or R² under 0.5) still comes back, with
    `weak=True` and one pooled rate for every family (Σ rise ÷ Σ spend): the
    fallback the lab's forecasters use; the live meter shows nothing then. A
    family that spent under $1 in the span keeps the pooled rate. For a
    per-model cap (`scope_model`, e.g. "Fable") only that family's spend is
    fitted and every other family's rate is 0 (`SpendMeterFitter.capCounts`)."""
    d = fit_details(history, account, window_kind, scope_model)
    return None if d is None else d.conversion


# ---------------------------------------------------------------------------
# The live meter (LiveMeter.estimate → LiveMeterValue.shownPercent)
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class _Reading:
    t: int
    p: float
    reset: int | None


def _same_cycle(a: _Reading, b: _Reading, duration: int) -> bool:
    """`LiveMeter.sameCycle`: never across a reset that had passed by the
    later reading; never from a null reset to an anchored one."""
    if a.reset is not None and a.reset <= b.t:
        return False
    if a.reset is not None and b.reset is not None:
        return bool(_cycles.same_cycle(b.reset, a.reset, duration))
    return a.reset is None and b.reset is None


@dataclass(frozen=True)
class LiveValue:
    """Everything `LiveMeter.value` computes; `shown` is what a surface shows."""

    shown: float
    percent: float           # whole points: reading + floor(carry + converted spend)
    exact: float             # before flooring
    reading: float
    reading_t: Millis
    anchor_t: Millis
    added: float             # converted spend since the anchor (Σ rate × $)
    spend_usd: float
    carry: float
    restarted: bool

    @property
    def is_estimate(self) -> bool:
        return self.restarted or self.added > 0


class _Spend:
    """Converted points and dollars per turn, cumulative, for range sums."""

    def __init__(self, led: _Ledger, rates: np.ndarray, counted: np.ndarray):
        ok = counted[led.fam] & (led.unit_cost > 0) if len(led.fam) else np.zeros(0, bool)
        pts = np.where(ok, rates[led.fam] * led.unit_cost, 0.0) if len(led.fam) else np.zeros(0)
        usd = np.where(ok, led.unit_cost, 0.0) if len(led.fam) else np.zeros(0)
        self.t = led.t
        self.pts = np.concatenate(([0.0], np.cumsum(pts)))
        self.usd = np.concatenate(([0.0], np.cumsum(usd)))

    def points(self, t0: int, t1: int) -> float:
        """Σ rate × $ over (t0, t1]."""
        return float(self.pts[np.searchsorted(self.t, t1, "right")] - self.pts[np.searchsorted(self.t, t0, "right")])

    def dollars(self, t0: int, t1: int) -> float:
        return float(self.usd[np.searchsorted(self.t, t1, "right")] - self.usd[np.searchsorted(self.t, t0, "right")])


def _held_tick(readings: list[_Reading], duration: int, spend: _Spend) -> tuple[_Reading, float] | None:
    """`LiveMeter.heldTick`: the latest reading held at the value of the
    reading that last moved while the spend since implies 2+ points, within
    ten minutes of it: that tick (the server has not recalculated)."""
    if not readings or readings[-1].p >= 100:
        return None
    last = readings[-1]
    tick = len(readings) - 1
    while tick > 0:
        prev, r = readings[tick - 1], readings[tick]
        if prev.p == last.p and _same_cycle(prev, r, duration) and r.t - prev.t <= MAX_PAIR_GAP_MS:
            tick -= 1
        else:
            break
    start = readings[tick]
    if tick >= len(readings) - 1 or last.t - start.t > MAX_SERVER_LAG_MS:
        return None
    implied = spend.points(start.t, last.t)
    return (start, implied) if implied + FLOOR_TOLERANCE >= STALE_HELD_POINTS else None


def _carry(readings: list[_Reading], duration: int, spend: _Spend,
           position: float = CARRY_POSITION, moved_weight: float = CARRY_MOVED_WEIGHT) -> float:
    """`LiveMeter.carry`: where inside its whole point the meter sat at the
    last reading, in [0, 1)."""
    if not readings:
        return 0.0
    lo, hi = 0.0, 1.0
    for i, r in enumerate(readings):
        p = r.p
        moved = None
        if i > 0:
            prev = readings[i - 1]
            s = spend.points(prev.t, r.t)
            if _same_cycle(prev, r, duration) and r.t - prev.t <= MAX_PAIR_GAP_MS and p >= prev.p:
                moved = s * moved_weight
        if moved is not None and lo + moved < p + 1 and hi + moved > p:
            lo, hi = max(lo + moved, p), min(hi + moved, p + 1)
        else:
            lo, hi = p, p + 1
    return min(max(0.0, lo + position * (hi - lo) - readings[-1].p), 1 - 1e-6)


def _tenths(v: float) -> float:
    """`PacerMeterFormat.tenths`: cut (never rounded up) to one decimal."""
    return math.floor(v * 10 + 1e-6) / 10


def live_detail(history: History, account: str, window_kind: str, scope_model: str | None = None,
                rates: np.ndarray | None = None) -> LiveValue | None:
    """`live_value` with its parts. `rates` (points per USD per family) skips
    the fit and its weak-fit gate: a model's own conversion, for research."""
    if rates is None:
        d = fit_details(history, account, window_kind, scope_model)
        if d is None or d.conversion.weak:
            return None
        rates = d.rates
    now = history.now
    r = _readings(history, account, window_kind, scope_model)
    known = r["t"] <= now
    if not known.any():
        return None
    t, p, reset = r["t"][known], r["p"][known], r["reset"][known]
    duration = _cycles.window_ms(window_kind)
    j = len(t) - 1
    latest_t = int(t[j])
    lo = int(np.searchsorted(t, latest_t - CARRY_LOOKBACK_MS, "left"))
    hist = [_Reading(int(t[i]), float(p[i]), None if reset[i] < 0 else int(reset[i])) for i in range(lo, j + 1)]
    latest = hist[-1]
    spend = _Spend(_ledger(history, account), np.asarray(rates, dtype=np.float64), _counted(scope_model))

    held = _held_tick(hist, duration, spend)
    anchor = held[0] if held else latest
    carry = _carry([h for h in hist if h.t <= anchor.t], duration, spend)

    # LiveMeter.value
    if now - anchor.t > MAX_READING_AGE_MS:
        return None
    if anchor.reset is None or anchor.reset > now:
        frm, base, restarted = anchor.t, anchor.p, False
    elif now >= anchor.reset + duration:
        return None
    else:
        frm, base, restarted = max(anchor.reset, anchor.t), 0.0, True
    exact = spend.points(frm, now)
    usd = spend.dollars(frm, now)
    carried = 0.0 if restarted else min(max(0.0, carry), 1 - 1e-6)
    points = math.floor(carried + exact + FLOOR_TOLERANCE)
    if restarted:
        percent = min(100.0, max(0.0, points))
        exact_pct = min(100.0, max(0.0, exact + FLOOR_TOLERANCE))
    else:
        percent = max(base, min(100.0, base + max(0, points)))
        exact_pct = max(base, min(100.0, base + carried + max(0.0, exact) + FLOOR_TOLERANCE))
    is_estimate = restarted or exact > 0
    shown = min(max(_tenths(exact_pct), percent), percent + 0.9) if is_estimate else percent
    return LiveValue(float(shown), float(percent), float(exact_pct), latest.p, latest.t, anchor.t,
                     float(exact), usd, float(carried), restarted)


def live_value(
    history: History, account: str, window_kind: str, scope_model: str | None = None,
) -> float | None:
    """The live meter: the latest reading plus the converted spend since it,
    to a tenth, never a full point above the whole points moved
    (LiveMeterValue.shownPercent). None when the fit is weak or missing.

    Also None, as in the app, when there is no reading, the reading (or the
    held tick it is built on) is over an hour old, or more than one cycle has
    passed since its reset. After a reset the value restarts at 0 plus the
    spend since the reset."""
    v = live_detail(history, account, window_kind, scope_model)
    return None if v is None else v.shown


# ---------------------------------------------------------------------------
# Cycles
# ---------------------------------------------------------------------------

def current_cycle(
    history: History, account: str, window_kind: str, scope_model: str | None = None,
) -> tuple[Millis, Millis, pl.DataFrame] | None:
    """(start_ms, reset_ms, this cycle's readings) for the cycle active at
    now, from readings known by now; None when the window is idle.

    The reset is the latest known reading's own reset (no median over later
    data) and the start is reset − window. The readings are the
    `meter_readings` rows of that cycle (active, reset within half a window of
    it: `RateLimitCycle.contains`, never `==`), sorted by t_event."""
    r = history.table("meter_readings")
    c = _cycles.current_cycle(r, history.now, account, window_kind, scope_model)
    if c is None:
        return None
    f = r.filter((pl.col("account") == account) & (pl.col("window_kind") == window_kind)
                 & (pl.col("state") == "active") & pl.col("resets_at").is_not_null()
                 & ((pl.col("resets_at").dt.epoch("ms") - c.reset_at).abs() < c.duration / 2)
                 & (pl.col("t_event").dt.epoch("ms") <= history.now))
    if scope_model is not None:
        f = f.filter(pl.col("scope_model") == scope_model)
    return int(c.start), int(c.reset_at), f.sort(["t_event", "util_pct"], maintain_order=True)
