"""Walk-forward training sets: past cutoffs inside a history, each described
as it was known then and labelled only with what was already known at `now`.

A row is (meter, cutoff `t`): the features at `t` (`FeatureBuilder.row`, as of
`t`) and, for each lead fraction `f` of the time then left to the cycle's
reset `R`, the meter's rise from `t` to `tau = t + f (R - t)`.

**A label is used only when it was known at `now`:**
- `tau <= now`, read from readings with `t_known <= now` (the meter as a step
  function of its readings, the scorer's own view of the truth);
- the step value at `tau` counts only once a reading at or after `tau` is
  known (otherwise the meter could have moved unseen in between); at the reset
  itself (`f = 1`) only once the cycle has reset by `now - margin`.

Otherwise the label is NaN (a model trains each lead on the rows that have
it). Cutoffs sit on a fixed UTC lattice (every `step`), so which cutoffs exist
is a function of the lattice and of what was known at each one, never of
later rows. `tests/ml` builds the set at `now`, then from a later history with
the same `now`, and requires identical output.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass

import numpy as np

from kit.ml.data import DAY_MS, HOUR_MS, MIN_MS, AsOfData, MeterSeries, step_value
from kit.ml.features import FEATURE_NAMES, F, FeatureBuilder

LEADS = np.array([0.03, 0.08, 0.15, 0.25, 0.4, 0.6, 0.8, 1.0])
STEP = {"five_hour": 30 * MIN_MS, "seven_day": 3 * HOUR_MS, "weekly_scoped": 3 * HOUR_MS}
MAX_DAYS = {"five_hour": 45, "seven_day": 150, "weekly_scoped": 150}
MIN_LEAD = 10 * MIN_MS
RESET_MARGIN = 10 * MIN_MS


@dataclass
class TrainSet:
    X: np.ndarray            # [n, len(FEATURE_NAMES)]
    Y: np.ndarray            # [n, len(leads)] rise in pp; NaN = not known at now
    tau: np.ndarray          # [n, len(leads)] label times (epoch ms)
    t: np.ndarray            # cutoffs
    reset: np.ndarray
    account: np.ndarray      # object
    leads: np.ndarray
    now: int
    lead_X: np.ndarray       # [n, len(leads), len(LEAD_NAMES)]
    cycle: np.ndarray = None  # [n] int: rows of one meter cycle share an id (folds must not split one)

    def __len__(self) -> int:
        return len(self.t)

    @property
    def used(self) -> np.ndarray:
        return self.X[:, F["used_now"]]

    @property
    def headroom(self) -> np.ndarray:
        return self.X[:, F["headroom"]]

    def complete(self) -> np.ndarray:
        return np.isfinite(self.Y).all(axis=1)

    def stacked(self) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        """(X, y, row) over every (row, lead) with a known label: the row's
        features followed by the lead's."""
        r, j = np.nonzero(np.isfinite(self.Y))
        X = np.concatenate([self.X[r], self.lead_X[r, j]], axis=1)
        return X, self.Y[r, j], r


def lattice(lo: int, hi: int, step: int) -> np.ndarray:
    first = lo + (-lo) % step
    return np.arange(first, hi + 1, step, dtype=np.int64)


def _keep(account: str, t: int, salt: str) -> float:
    """A deterministic per-row draw in [0, 1): subsampling by it depends on
    the row alone, never on which other rows exist."""
    h = hashlib.blake2b(f"{salt}|{account}|{t}".encode(), digest_size=8).digest()
    return int.from_bytes(h, "big") / 2 ** 64


def label_row(series: MeterSeries, t: int, reset: int, used: float, now: int,
              leads: np.ndarray = LEADS) -> tuple[np.ndarray, np.ndarray]:
    """(rise at each lead, label time) for a cutoff at t in the cycle
    resetting at `reset`, from readings known at `now` only."""
    idx = series.cycle_readings(reset, now, upto=reset)
    te, ut = series.te[idx], series.util[idx]
    tau = t + leads * (reset - t)
    y = np.full(len(leads), np.nan)
    if len(te) == 0:
        return y, tau
    start = reset - series.duration
    last_te = te[-1]
    for j, (f, tj) in enumerate(zip(leads, tau)):
        if tj > now:
            continue
        if f >= 1.0:
            if reset <= now - RESET_MARGIN:
                y[j] = max(float(ut[-1]) - used, 0.0)
        elif last_te >= tj:
            y[j] = max(step_value(te, ut, tj, start) - used, 0.0)
    return y, tau


def build_trainset(data: AsOfData, builder: FeatureBuilder, window_kind: str, cap: str | None, now: int, *,
                   start: int | None = None, step: int | None = None, max_days: int | None = None,
                   max_rows: int = 4000, leads: np.ndarray = LEADS, salt: str = "wf") -> TrainSet:
    """Every lattice cutoff in [max(start, now - max_days), now) where a cycle
    of this kind (and cap) was active as known then, on every account in the
    data, subsampled to `max_rows` by a per-row draw (recent rows favoured)."""
    step = step or STEP[window_kind]
    max_days = max_days or MAX_DAYS[window_kind]
    lo = now - max_days * DAY_MS
    if start is not None:
        lo = max(lo, start)
    times = lattice(lo, now - MIN_LEAD, step)
    cand = []
    for s in data.series_of(window_kind, cap):
        if len(s) == 0:
            continue
        for t in times:
            c = s.index.cycle_at(int(t))
            if c is None or c.reset_at - t < MIN_LEAD:
                continue
            cand.append((s, int(t), int(c.reset_at)))
    if len(cand) > max_rows:
        # Recent rows twice as likely as the oldest: priority = draw / weight.
        span = max(now - lo, 1)
        pri = np.array([_keep(s.account, t, salt) / (0.5 + 0.5 * (t - lo) / span) for s, t, _ in cand])
        keep = np.sort(np.argsort(pri, kind="stable")[:max_rows])
        cand = [cand[i] for i in keep]
    X, Y, TAU, T, RS, AC, LX = [], [], [], [], [], [], []
    for s, t, r in cand:
        st = s.state_at(t, r)
        if st is None:
            continue
        row = builder.row(s, t, r, st)
        if row is None:
            continue
        y, tau = label_row(s, t, r, st.used, now, leads)
        if not np.isfinite(y).any():
            continue
        X.append(row)
        Y.append(y)
        TAU.append(tau)
        T.append(t)
        RS.append(r)
        AC.append(s.account)
        LX.append(builder.lead_rows(row, s, t, r, leads))
    n = len(T)
    cycle = cycle_ids(np.asarray(AC, object), np.asarray(RS, np.int64), WINDOW_HALF[window_kind])
    if n == 0:
        z = np.zeros((0, len(leads)))
        return TrainSet(np.zeros((0, len(FEATURE_NAMES))), z, z.copy(), np.zeros(0, np.int64),
                        np.zeros(0, np.int64), np.zeros(0, object), leads, now,
                        np.zeros((0, len(leads), 6)))
    return TrainSet(np.asarray(X), np.asarray(Y), np.asarray(TAU), np.asarray(T, np.int64),
                    np.asarray(RS, np.int64), np.asarray(AC, object), leads, now, np.asarray(LX), cycle)


WINDOW_HALF = {"five_hour": 150 * MIN_MS, "seven_day": 84 * HOUR_MS, "weekly_scoped": 84 * HOUR_MS}


def cycle_ids(accounts: np.ndarray, resets: np.ndarray, half: int) -> np.ndarray:
    """One id per (account, cycle): resets jitter by milliseconds within a
    cycle and are at least a window apart between cycles (half-window rule)."""
    out = np.zeros(len(resets), dtype=np.int64)
    nxt = 0
    for a in sorted(set(accounts.tolist())):
        idx = np.flatnonzero(accounts == a)
        o = idx[np.argsort(resets[idx], kind="stable")]
        anchor = None
        for i in o:
            if anchor is None or resets[i] - anchor >= half:
                anchor, nxt = resets[i], nxt + 1
            out[i] = nxt - 1
    return out
