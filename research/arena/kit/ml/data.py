"""As-of arrays for learned models: built once from a `History`, and every
lookup takes an explicit `asof` and reads only rows with `t_known <= asof`.

Why the explicit `asof` when a `History` is already cut at `now`: a learned
model trains on *past* moments inside its history (walk-forward rows), and a
feature at a past moment `t` must be what was known at `t`, not at `now`. So
nothing here trusts the history's own cut: every function filters by
`t_known <= asof` itself, and `tests/ml` checks that handing a function a
LATER history with the same `asof` changes nothing.

Turns are priced once each, **with the rates known when the turn became
known** (`arena.pricing.price_turns(..., as_of=<the newest price t_known <=
the turn's t_known>)`). A turn is in a feature only once it is known, so its
price is always one that was known by then too; a model at `now` prices the
same way, so training rows and the live row agree. Output is the raw recorded
value: the imputed one is a late column with its own clock, and pricing with
it would put news from after `t` into a feature at `t`.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
import polars as pl

from arena.pricing import SYNTHETIC_MODEL, price_turns
from arena.snapshot.cycles import MeterIndex, meter_frame
from arena.types import History, Millis

MIN_MS = 60_000
HOUR_MS = 60 * MIN_MS
DAY_MS = 24 * HOUR_MS
WEEK_MS = 7 * DAY_MS

WINDOW_MS = {"five_hour": 5 * HOUR_MS, "seven_day": WEEK_MS, "weekly_scoped": WEEK_MS}
FAMILIES = ("fable", "opus", "sonnet", "haiku", "other")
_FAM_IDX = {f: i for i, f in enumerate(FAMILIES)}

TURN_COLS = ("t_event", "t_known", "call_id", "account", "model", "model_family", "input", "output",
             "cache_read", "cache_write_5m", "cache_write_1h", "inference_geo", "speed", "session_h",
             "tz_offset_min", "is_subagent", "output_reliable", "output_imputed")


def _ms(col: str) -> pl.Expr:
    return pl.col(col).dt.epoch("ms")


# ---------------------------------------------------------------------------
# Turns
# ---------------------------------------------------------------------------

def price_at_known_time(turns: pl.DataFrame, prices: pl.DataFrame) -> pl.DataFrame:
    """`turns` with `cost_usd`: each row priced with the rates whose t_known is
    at or before the turn's own t_known. Null when no rate was known yet."""
    if turns.height == 0:
        return turns.with_columns(pl.lit(None, pl.Float64).alias("cost_usd"))
    ptk = np.unique(prices["t_known"].dt.epoch("ms").drop_nulls().to_numpy().astype(np.int64)) \
        if prices.height else np.zeros(0, np.int64)
    tk = turns["t_known"].dt.epoch("ms").to_numpy().astype(np.int64)
    epoch = np.searchsorted(ptk, tk, side="right") - 1
    turns = turns.with_row_index("_r").with_columns(pl.Series("_e", epoch))
    parts = []
    for e in np.unique(epoch):
        sub = turns.filter(pl.col("_e") == int(e))
        if e < 0:
            parts.append(sub.with_columns(pl.lit(None, pl.Float64).alias("cost_usd")))
            continue
        priced = price_turns(sub, prices, as_of=int(ptk[e]), output="raw")
        parts.append(priced.drop("price_flag"))
    return pl.concat(parts, how="vertical_relaxed").sort("_r").drop("_r", "_e")


def slim_turns(turns: pl.DataFrame, prices: pl.DataFrame) -> pl.DataFrame:
    """The columns the kit uses, priced at known time, without `<synthetic>`
    rows (never usage)."""
    if turns.height == 0:
        return pl.DataFrame(schema={"te": pl.Int64, "tk": pl.Int64, "call_id": pl.UInt64, "account": pl.String,
                                    "fam": pl.Int8, "cost": pl.Float64, "tokens": pl.Float64,
                                    "session": pl.UInt64, "tz": pl.Int16, "sub": pl.Boolean})
    t = turns.filter(pl.col("model") != SYNTHETIC_MODEL)
    t = price_at_known_time(t, prices)
    return t.select(
        _ms("t_event").alias("te"), _ms("t_known").alias("tk"), pl.col("call_id"), pl.col("account"),
        pl.col("model_family").fill_null("other").replace_strict(_FAM_IDX, default=_FAM_IDX["other"],
                                                                  return_dtype=pl.Int8).alias("fam"),
        pl.col("cost_usd").alias("cost"),
        (pl.col("input").fill_null(0) + pl.col("output").fill_null(0) + pl.col("cache_read").fill_null(0)
         + pl.col("cache_write_5m").fill_null(0) + pl.col("cache_write_1h").fill_null(0)
         ).cast(pl.Float64).alias("tokens"),
        pl.col("session_h").alias("session"),
        pl.col("tz_offset_min").alias("tz"),
        pl.col("is_subagent").fill_null(False).alias("sub"),
    )


@dataclass
class TurnArrays:
    """One account's turns, sorted by t_event."""

    te: np.ndarray
    tk: np.ndarray
    cost: np.ndarray        # NaN when unpriced
    tokens: np.ndarray
    fam: np.ndarray
    session: np.ndarray
    tz: np.ndarray          # minutes; NaN when unknown
    sub: np.ndarray

    @classmethod
    def from_frame(cls, f: pl.DataFrame) -> "TurnArrays":
        f = f.sort(["te", "tk"])
        return cls(f["te"].to_numpy().astype(np.int64), f["tk"].to_numpy().astype(np.int64),
                   f["cost"].fill_null(np.nan).to_numpy().astype(np.float64),
                   f["tokens"].fill_null(0.0).to_numpy().astype(np.float64),
                   f["fam"].to_numpy().astype(np.int8),
                   f["session"].fill_null(0).to_numpy().astype(np.uint64),
                   f["tz"].cast(pl.Float64).fill_null(np.nan).to_numpy(),
                   f["sub"].to_numpy().astype(bool))

    def window(self, lo: Millis, hi: Millis, asof: Millis) -> np.ndarray:
        """Indices of turns with t_event in (lo, hi] known at asof."""
        a = int(np.searchsorted(self.te, lo, side="right"))
        b = int(np.searchsorted(self.te, hi, side="right"))
        idx = np.arange(a, b)
        return idx[self.tk[a:b] <= asof]

    def spend(self, lo: Millis, hi: Millis, asof: Millis, fam: int | None = None) -> float:
        """USD of turns with t_event in (lo, hi] known at asof (one model
        family's only, given `fam`)."""
        i = self.window(lo, hi, asof)
        if fam is not None and len(i):
            i = i[self.fam[i] == fam]
        return float(np.nansum(self.cost[i])) if len(i) else 0.0

    def latest_tz(self, asof: Millis) -> float:
        b = int(np.searchsorted(self.te, asof, side="right"))
        lo = max(0, b - 500)
        k = np.flatnonzero((self.tk[lo:b] <= asof) & np.isfinite(self.tz[lo:b]))
        return float(self.tz[lo + k[-1]]) if len(k) else float("nan")


def cap_family(cap: str | None) -> int | None:
    """The model family a per-model cap counts (the Fable weekly counts
    Fable turns), as a FAMILIES index; None for an all-model meter."""
    if cap is None:
        return None
    return _FAM_IDX.get(str(cap).strip().lower())


# ---------------------------------------------------------------------------
# Meters
# ---------------------------------------------------------------------------

@dataclass
class CycleState:
    """The cycle in progress at `asof` as known at `asof`."""

    reset: Millis
    start: Millis
    duration: int
    used: float
    last_te: Millis
    te: np.ndarray          # this cycle's readings known at asof (t_event order)
    util: np.ndarray


@dataclass
class PastCycle:
    reset: Millis
    start: Millis
    idx: np.ndarray          # reading indices (t_event order) in the series
    tk_max: Millis
    final: float             # last reading's util, from every reading in the history
    phase: np.ndarray        # meter at PHASE_U of the cycle (step), from every reading


PHASE_U = np.linspace(0.0, 1.0, 41)


class MeterSeries:
    """One meter (account × window × cap) from a history's readings. As-of
    lookups by `asof`; the cycle rule is the harness's (`MeterIndex`)."""

    def __init__(self, frame: pl.DataFrame, account: str, window_kind: str, cap: str | None):
        self.account, self.window_kind, self.cap = account, window_kind, cap
        self.duration = WINDOW_MS[window_kind]
        self.index = MeterIndex(frame, account, window_kind, cap, self.duration)
        ix = self.index
        self.te, self.tk, self.reset, self.util, self.active = ix.te, ix.tk, ix.reset, ix.util, ix.active
        self._past: list[PastCycle] | None = None

    def __len__(self) -> int:
        return len(self.te)

    # the cycle in progress ------------------------------------------------
    def cycle_readings(self, reset: Millis, asof: Millis, upto: Millis | None = None) -> np.ndarray:
        """Indices of readings of the cycle resetting at `reset` known at
        asof with t_event <= upto (default asof)."""
        upto = asof if upto is None else upto
        lo = int(np.searchsorted(self.te, reset - self.duration - HOUR_MS, side="left"))
        hi = int(np.searchsorted(self.te, min(upto, reset), side="right"))
        idx = np.arange(lo, hi)
        m = (self.active[lo:hi] & (self.tk[lo:hi] <= asof)
             & (np.abs(self.reset[lo:hi] - reset) < self.duration / 2) & np.isfinite(self.util[lo:hi]))
        return idx[m]

    def state_at(self, asof: Millis, reset: Millis | None = None) -> CycleState | None:
        """The active cycle at asof (`reset` given: that cycle, as a request
        names it), from readings known at asof."""
        if reset is None:
            c = self.index.cycle_at(asof)
            if c is None:
                return None
            reset = c.reset_at
        idx = self.cycle_readings(reset, asof)
        if len(idx) == 0:
            return None
        return CycleState(int(reset), int(reset - self.duration), self.duration, float(self.util[idx[-1]]),
                          int(self.te[idx[-1]]), self.te[idx], self.util[idx])

    # completed cycles -----------------------------------------------------
    def past_cycles(self) -> list[PastCycle]:
        """Every cycle in the history, segmented by the half-window rule
        anchored on the earliest reset (later readings only append cycles).
        `final`/`phase` use every reading here; `outcomes(asof)` re-derives
        them from what was known at asof when a reading is younger."""
        if self._past is not None:
            return self._past
        act = np.flatnonzero(self.active & np.isfinite(self.util))
        out: list[PastCycle] = []
        if len(act):
            order = act[np.argsort(self.reset[act], kind="stable")]
            groups, cur, anchor = [], [order[0]], self.reset[order[0]]
            for j in order[1:]:
                if self.reset[j] - anchor >= self.duration / 2:
                    groups.append(cur)
                    cur, anchor = [j], self.reset[j]
                else:
                    cur.append(j)
            groups.append(cur)
            for g in groups:
                idx = np.sort(np.asarray(g))
                r = int(self.reset[idx[0]])        # the anchor's own reset: stable as readings arrive
                out.append(self._past_cycle(r, idx))
        self._past = out
        return out

    def _past_cycle(self, r: int, idx: np.ndarray) -> PastCycle:
        s = r - self.duration
        te, ut = self.te[idx], self.util[idx]
        return PastCycle(r, s, idx, int(self.tk[idx].max()), float(ut[-1]), _step_at(te, ut, s + PHASE_U * self.duration, s))

    def _arrays(self):
        if not hasattr(self, "_resets"):
            cyc = self.past_cycles()
            self._resets = np.array([c.reset for c in cyc], dtype=np.int64)
            self._tk_max = np.array([c.tk_max for c in cyc], dtype=np.int64)
            self._tk_min = np.array([int(self.tk[c.idx].min()) for c in cyc], dtype=np.int64)
        return self._resets, self._tk_max, self._tk_min

    def outcomes(self, asof: Millis, margin: int = 10 * MIN_MS, last: int | None = None) -> list[PastCycle]:
        """Cycles that had reset by asof - margin, as known at asof (a
        reading still unknown at asof is left out of final and phase); the
        `last` most recent ones when given. Chronological."""
        cyc = self.past_cycles()
        resets, tk_max, tk_min = self._arrays()
        k = int(np.searchsorted(resets, asof - margin, side="right"))
        sel = np.flatnonzero(tk_min[:k] <= asof)
        if last is not None:
            sel = sel[-last:]
        out = []
        for j in sel:
            c = cyc[j]
            if tk_max[j] <= asof:
                out.append(c)
            else:
                out.append(self._past_cycle(c.reset, c.idx[self.tk[c.idx] <= asof]))
        return out

    def n_outcomes(self, asof: Millis, margin: int = 10 * MIN_MS) -> int:
        resets, _, tk_min = self._arrays()
        k = int(np.searchsorted(resets, asof - margin, side="right"))
        return int((tk_min[:k] <= asof).sum())

    def level_at(self, asof: Millis) -> tuple[float, float, Millis | None]:
        """(util, elapsed fraction, t_event) of the newest reading known at
        asof when its cycle is still active; (0, nan, None) otherwise."""
        c = self.index.cycle_at(asof)
        if c is None:
            return 0.0, float("nan"), None
        return c.util, (asof - c.start) / c.duration, c.last_t


def _step_at(te: np.ndarray, util: np.ndarray, at: np.ndarray, start: Millis) -> np.ndarray:
    """The meter as a step function of its readings (0 before the first one
    after the cycle start), read at `at`."""
    i = np.searchsorted(te, at, side="right") - 1
    out = np.where(i >= 0, util[np.maximum(i, 0)], 0.0)
    return np.where(at < start, 0.0, out)


def step_value(te: np.ndarray, util: np.ndarray, at: float, start: Millis) -> float:
    if at < start:
        return 0.0
    i = int(np.searchsorted(te, at, side="right")) - 1
    return float(util[i]) if i >= 0 else 0.0


# ---------------------------------------------------------------------------
# Everything together
# ---------------------------------------------------------------------------

@dataclass
class AsOfData:
    """A history's rows as arrays. `now` is the history's cut; every lookup
    still takes its own `asof <= now`."""

    now: Millis
    accounts: tuple[str, ...]
    turns: dict[str, TurnArrays]
    meters: dict[tuple[str, str, str | None], MeterSeries]
    prompts: dict[str, tuple[np.ndarray, np.ndarray]]      # account -> (te, tk) of human prompts, sorted
    _slim: pl.DataFrame = field(repr=False, default=None)
    _readings: pl.DataFrame = field(repr=False, default=None)
    _prompts: pl.DataFrame = field(repr=False, default=None)
    _sess: pl.DataFrame = field(repr=False, default=None)
    _prices: pl.DataFrame = field(repr=False, default=None)

    @classmethod
    def from_history(cls, history: History) -> "AsOfData":
        prices = history.table("prices")
        slim = slim_turns(history.table("turns").select([c for c in TURN_COLS
                                                          if c in history.table("turns").columns]), prices)
        return cls._build(history.now, tuple(history.accounts), slim, history.table("meter_readings"),
                          history.table("prompts"), _session_accounts(history.table("sessions"), slim), prices)

    @classmethod
    def _build(cls, now, accounts, slim, readings, prompts, sess, prices) -> "AsOfData":
        # Sorted, so every sum over accounts runs in one order (float sums
        # must not depend on how a group_by happened to come out).
        turns = {}
        for (acct,), g in sorted(slim.group_by(["account"]), key=lambda kv: str(kv[0][0])):
            if acct is not None:
                turns[str(acct)] = TurnArrays.from_frame(g)
        meters = {}
        if readings.height:
            r = readings.filter(pl.col("window_kind").is_in(list(WINDOW_MS)))
            groups = sorted(r.group_by(["account", "window_kind", "scope_model"]),
                            key=lambda kv: tuple(str(x) for x in kv[0]))
            for (acct, kind, cap), g in groups:
                if acct is None:
                    continue
                cap = cap if kind == "weekly_scoped" else None
                if kind == "weekly_scoped" and cap is None:
                    continue
                meters[(str(acct), str(kind), cap)] = MeterSeries(meter_frame(g, acct, kind, cap), acct, kind, cap)
        accts = tuple(sorted(set(accounts) | set(turns) | {k[0] for k in meters}))
        return cls(int(now), accts, turns, meters, _human_prompts(prompts, sess),
                   slim, readings, prompts, sess, prices)

    def extend(self, events, until: Millis) -> "AsOfData":
        """This data plus the rows that became known up to `until`. A turn
        re-delivered in a newer form replaces the old one (by call_id)."""
        prices = pl.concat([self._prices, events.table("prices")], how="vertical_relaxed") \
            if events.table("prices").height else self._prices
        new_t = events.table("turns")
        slim = self._slim
        if new_t.height:
            ns = slim_turns(new_t.select([c for c in TURN_COLS if c in new_t.columns]), prices)
            slim = pl.concat([slim.join(ns.select("call_id"), on="call_id", how="anti"), ns], how="vertical_relaxed")
        readings = _concat(self._readings, events.table("meter_readings"))
        prompts = _concat(self._prompts, events.table("prompts"))
        sess = self._sess
        if new_t.height or events.table("sessions").height:
            sess = (pl.concat([self._sess, _session_accounts(events.table("sessions"), slim)], how="vertical_relaxed")
                    .group_by(["session", "account"]).agg(pl.col("tk").min()))
        return AsOfData._build(until, self.accounts, slim, readings, prompts, sess, prices)

    # convenience ---------------------------------------------------------------
    def meter(self, account: str, window_kind: str, cap: str | None = None) -> MeterSeries | None:
        return self.meters.get((account, window_kind, cap if window_kind == "weekly_scoped" else None))

    def series_of(self, window_kind: str, cap: str | None = None) -> list[MeterSeries]:
        return [m for (a, k, c), m in sorted(self.meters.items(), key=lambda kv: (kv[0][0], kv[0][1], kv[0][2] or ""))
                if k == window_kind and (window_kind != "weekly_scoped" or cap is None or c == cap)]

    def human_prompts(self, account: str, lo: Millis, hi: Millis, asof: Millis) -> int:
        te, tk = self.prompts.get(account, (np.zeros(0, np.int64), np.zeros(0, np.int64)))
        a = int(np.searchsorted(te, lo, side="right"))
        b = int(np.searchsorted(te, hi, side="right"))
        return int((tk[a:b] <= asof).sum())


def _concat(a: pl.DataFrame, b: pl.DataFrame) -> pl.DataFrame:
    if b is None or b.height == 0:
        return a
    if a is None or a.height == 0:
        return b
    return pl.concat([a, b], how="vertical_relaxed")


def _session_accounts(sessions: pl.DataFrame, slim: pl.DataFrame) -> pl.DataFrame:
    """session -> (account, when that was first known): from the session's
    turns (earliest t_known) and its sessions row, whichever came first."""
    parts = []
    if slim.height:
        parts.append(slim.filter(pl.col("account").is_not_null())
                     .group_by(["session", "account"]).agg(pl.col("tk").min()))
    if sessions is not None and sessions.height:
        parts.append(sessions.filter(pl.col("account").is_not_null()).select(
            pl.col("session_h").alias("session"), pl.col("account"), _ms("t_known").alias("tk")))
    if not parts:
        return pl.DataFrame(schema={"session": pl.UInt64, "account": pl.String, "tk": pl.Int64})
    return (pl.concat(parts, how="vertical_relaxed").group_by(["session", "account"]).agg(pl.col("tk").min()))


def _human_prompts(prompts: pl.DataFrame, sess: pl.DataFrame) -> dict[str, tuple[np.ndarray, np.ndarray]]:
    """A human prompt counts for an account from when both the prompt and
    its session's account are known."""
    if prompts is None or prompts.height == 0 or sess.height == 0:
        return {}
    p = prompts.filter(pl.col("origin").is_in(["human", "unknown"])).select(
        _ms("t_event").alias("te"), _ms("t_known").alias("ptk"), pl.col("session_h").alias("session"))
    j = p.join(sess, on="session", how="inner").with_columns(pl.max_horizontal("ptk", "tk").alias("k"))
    out = {}
    for (acct,), g in j.group_by(["account"]):
        g = g.sort("te")
        out[str(acct)] = (g["te"].to_numpy().astype(np.int64), g["k"].to_numpy().astype(np.int64))
    return out
