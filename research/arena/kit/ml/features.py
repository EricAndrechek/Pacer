"""As-of features for a meter forecast at a moment `asof`.

`FeatureBuilder.row(series, asof, reset)` describes one meter (account ×
window × cap) at `asof` from rows known at `asof` only (`AsOfData` lookups all
take the explicit `asof`). Slow-moving aggregates (the hour-of-week activity
profile, the spend-to-meter ratio, pooled outcomes, the account count) are
computed as of the start of `asof`'s UTC day or hour and cached there: that is
earlier than `asof`, so it can only know less, never more.

The groups, after the case features of an earlier, unpublished lab, each
rebuilt from `History` alone
(the lab built its activity prior from the whole store):

- cycle phase: elapsed fraction, hours left;
- the meter now: used, headroom, readings so far, age of the latest reading;
- recent burn from readings (pp/h over several lookbacks), the cycle's
  average, acceleration, trajectory shape, projections to the reset;
- recent spend (API-equivalent USD/h, priced at known time; for a per-model
  cap, that family's spend only) and its
  conversion to meter points with a ratio fitted on the account's own recent
  cycles (points per dollar), including the nowcast (spend since the latest
  reading, converted);
- the account's hour-of-week activity profile (spend and active hours over
  the trailing four weeks): expected spend and activity left in the cycle;
- previous cycles' outcomes known by now: finals, hit rate, and what happened
  from the same phase onward, for the account and pooled over every account;
- cross-window state (the other meter of the same account);
- session and prompt activity, subagent share, idle time;
- how many accounts are in use, and the other accounts' spend;
- the model-family mix of recent spend.

Every value is finite (missing → a neutral fill), so any learner can use it.
"""
from __future__ import annotations

import math

import numpy as np

from kit.ml.data import (
    DAY_MS, FAMILIES, HOUR_MS, MIN_MS, PHASE_U, AsOfData, CycleState, MeterSeries, cap_family, step_value,
)

WEEK_H = 168
# 1970-01-01 was a Thursday: shifting by 72 hours puts Monday 00:00 at slot 0.
_MONDAY_SHIFT_H = 72

LOOKBACKS = {
    "five_hour": (15 * MIN_MS, 30 * MIN_MS, HOUR_MS, 2 * HOUR_MS),
    "seven_day": (3 * HOUR_MS, 12 * HOUR_MS, DAY_MS, 3 * DAY_MS),
    "weekly_scoped": (3 * HOUR_MS, 12 * HOUR_MS, DAY_MS, 3 * DAY_MS),
}
SPEND_LOOKBACKS = {
    "five_hour": (15 * MIN_MS, HOUR_MS, 3 * HOUR_MS),
    "seven_day": (3 * HOUR_MS, 12 * HOUR_MS, 2 * DAY_MS),
    "weekly_scoped": (3 * HOUR_MS, 12 * HOUR_MS, 2 * DAY_MS),
}
OTHER = {"five_hour": "seven_day", "seven_day": "five_hour", "weekly_scoped": "seven_day"}
CONV_CYCLES = {"five_hour": 12, "seven_day": 3, "weekly_scoped": 3}
CONV_MAX_AGE = 28 * DAY_MS
PROFILE_DAYS = 28
PAST_N = 8
POOL_N = 40

FEATURE_NAMES: tuple[str, ...] = (
    # phase and the meter now
    "elapsed_frac", "remaining_h", "used_now", "headroom", "n_read", "since_last_h",
    # burn from readings
    "rate_0", "rate_1", "rate_2", "rate_3", "rate_cycle", "accel", "proj_cycle", "proj_rate1",
    "traj_25", "traj_50", "traj_75", "flat_share",
    # spend and its conversion
    "spend_0", "spend_1", "spend_2", "spend_cycle", "spend_since_read",
    "conv", "conv_rate_0", "conv_rate_1", "nowcast_gap", "conv_resid", "conv_proj",
    # hour-of-week profile
    "exp_spend_rem", "exp_active_rem", "exp_pts_rem", "act_frac_left", "active_now", "exp_spend_next_h",
    "hod_sin", "hod_cos", "dow_sin", "dow_cos",
    # previous cycles
    "n_past", "past_final_mean", "past_final_last", "past_hit", "past_phase_rise", "past_phase_rise_max",
    "pool_final_mean", "pool_phase_rise", "pool_hit",
    # cross-window
    "x_level", "x_elapsed", "x_rate",
    # activity
    "sess_15m", "sess_60m", "turns_15m", "sub_share_60m", "prompts_15m", "prompts_60m", "idle_h",
    # accounts
    "n_acct_7d", "n_acct_1h", "others_spend_1h",
    # family mix of the last 6 hours' spend
    "mix_fable", "mix_opus", "mix_sonnet", "mix_haiku",
)
F = {n: i for i, n in enumerate(FEATURE_NAMES)}

# Features of one lead (a fraction f of the time left to reset), appended
# to a row's features when a model is trained on (row, lead) pairs.
LEAD_NAMES: tuple[str, ...] = ("lead_frac", "lead_h", "lead_rate_proj", "lead_conv_proj", "lead_exp_pts",
                               "lead_exp_active")


def _fin(v: float, fill: float = 0.0) -> float:
    return float(v) if v is not None and math.isfinite(v) else fill


class Profile:
    """An account's hour-of-week profile as of a moment: mean USD per local
    hour slot, and the share of weeks with any turn in it. Integrates over
    real time spans with fractional hours."""

    def __init__(self, usd: np.ndarray, active: np.ndarray, tz_min: float):
        self.usd, self.active = usd, active
        self.tz_ms = int(round(_fin(tz_min) * MIN_MS))
        self._cu = np.concatenate(([0.0], np.cumsum(usd)))
        self._ca = np.concatenate(([0.0], np.cumsum(active)))

    def _hours(self, t: float) -> float:
        return (t + self.tz_ms) / HOUR_MS - _MONDAY_SHIFT_H

    def _F(self, x: float, p: np.ndarray, c: np.ndarray) -> float:
        w, r = divmod(x, WEEK_H)
        k = int(r)
        return w * c[-1] + c[k] + (r - k) * p[k]

    def integral(self, t0: float, t1: float) -> tuple[float, float]:
        """(expected USD, expected active hours) over [t0, t1]."""
        if t1 <= t0:
            return 0.0, 0.0
        a, b = self._hours(t0), self._hours(t1)
        return (self._F(b, self.usd, self._cu) - self._F(a, self.usd, self._cu),
                self._F(b, self.active, self._ca) - self._F(a, self.active, self._ca))

    def slot(self, t: float) -> int:
        return int(self._hours(t) % WEEK_H)


class FeatureBuilder:
    """Features for one window kind over an `AsOfData`. Holds caches keyed by
    as-of buckets, so one builder serves many rows (walk-forward training
    and the live row) cheaply."""

    def __init__(self, data: AsOfData, window_kind: str):
        self.data = data
        self.kind = window_kind
        self._profile: dict = {}
        self._conv: dict = {}
        self._pool: dict = {}
        self._acct: dict = {}

    # slow aggregates (as of a bucket start <= asof) -------------------------
    def profile(self, account: str, asof: int, fam: int | None = None) -> Profile:
        """The hour-of-week profile of the account's spend (one family's,
        for a per-model cap) over the trailing weeks, as of asof's day."""
        day = asof - asof % DAY_MS
        key = (account, day, fam)
        if key not in self._profile:
            T = self.data.turns.get(account)
            usd = np.zeros(WEEK_H)
            act = np.zeros(WEEK_H)
            tz = float("nan")
            if T is not None:
                tz = T.latest_tz(day)
                idx = T.window(day - PROFILE_DAYS * DAY_MS, day, day)
                if fam is not None:
                    idx = idx[T.fam[idx] == fam]
                if len(idx):
                    tzm = int(round(_fin(tz) * MIN_MS))
                    hours = (T.te[idx] + tzm) // HOUR_MS
                    slot = ((hours - _MONDAY_SHIFT_H) % WEEK_H).astype(np.int64)
                    weeks = PROFILE_DAYS / 7.0
                    usd = np.bincount(slot, weights=np.nan_to_num(T.cost[idx]), minlength=WEEK_H) / weeks
                    uh, first = np.unique(hours, return_index=True)
                    act = np.bincount(slot[first], minlength=WEEK_H) / weeks
            self._profile[key] = Profile(usd, np.minimum(act, 1.0), tz)
        return self._profile[key]

    def conversion(self, series: MeterSeries, asof: int) -> float:
        """Meter points per USD from the series' last completed cycles known
        at the start of asof's day (pooled over every series of the kind
        when the account's own spend is too thin). NaN when nothing fits."""
        day = asof - asof % DAY_MS
        key = (series.account, series.window_kind, series.cap, day)
        if key not in self._conv:
            pts, usd = self._conv_sums(series, day)
            if usd < 1.0 or pts <= 0:
                pts, usd = 0.0, 0.0
                for s in self.data.series_of(self.kind, series.cap):
                    p, u = self._conv_sums(s, day)
                    pts, usd = pts + p, usd + u
            self._conv[key] = pts / usd if usd >= 1.0 and pts > 0 else float("nan")
        return self._conv[key]

    def _conv_sums(self, s: MeterSeries, day: int) -> tuple[float, float]:
        k = ("sums", s.account, s.window_kind, s.cap, day)
        if k not in self._conv:
            T = self.data.turns.get(s.account)
            pts = usd = 0.0
            if T is not None:
                for c in s.outcomes(day, last=CONV_CYCLES[s.window_kind]):
                    if c.reset < day - CONV_MAX_AGE:
                        continue
                    pts += c.final
                    usd += T.spend(c.start, c.reset, day, cap_family(s.cap))
            self._conv[k] = (pts, usd)
        return self._conv[k]

    def pool(self, asof: int, cap: str | None) -> tuple[np.ndarray, np.ndarray]:
        """(finals, phase matrix) of the last POOL_N completed cycles over every
        account of this kind, as of the start of asof's hour."""
        hour = asof - asof % HOUR_MS
        key = (hour, cap)
        if key not in self._pool:
            cyc = []
            for s in self.data.series_of(self.kind, cap):
                cyc += s.outcomes(hour, last=POOL_N)
            cyc.sort(key=lambda c: c.reset)
            cyc = cyc[-POOL_N:]
            fin = np.array([c.final for c in cyc], dtype=np.float64)
            ph = np.stack([c.phase for c in cyc]) if cyc else np.zeros((0, len(PHASE_U)))
            self._pool[key] = (fin, ph)
        return self._pool[key]

    def accounts_in_use(self, asof: int) -> float:
        day = asof - asof % DAY_MS
        if day not in self._acct:
            self._acct[day] = float(sum(1 for T in self.data.turns.values()
                                        if len(T.window(day - 7 * DAY_MS, day, day))))
        return self._acct[day]

    # one row ---------------------------------------------------------------
    def state(self, series: MeterSeries, asof: int, reset: int | None = None) -> CycleState | None:
        return series.state_at(asof, reset)

    def row(self, series: MeterSeries, asof: int, reset: int | None = None,
            st: CycleState | None = None) -> np.ndarray | None:
        st = st or series.state_at(asof, reset)
        if st is None:
            return None
        acct, kind = series.account, self.kind
        D, R, S = st.duration, st.reset, st.start
        rem, el = max(R - asof, 0), max(asof - S, 1)
        rem_h, el_h = rem / HOUR_MS, el / HOUR_MS
        used = st.used
        head = max(100.0 - used, 0.0)
        v = np.zeros(len(FEATURE_NAMES))
        v[F["elapsed_frac"]] = min(el / D, 1.0)
        v[F["remaining_h"]] = rem_h
        v[F["used_now"]] = used
        v[F["headroom"]] = head
        v[F["n_read"]] = math.log1p(len(st.te))
        v[F["since_last_h"]] = (asof - st.last_te) / HOUR_MS
        rates = []
        for i, L in enumerate(LOOKBACKS[kind]):
            v0 = step_value(st.te, st.util, asof - L, S)
            rates.append(max(used - v0, 0.0) / (L / HOUR_MS))
            v[F[f"rate_{i}"]] = rates[-1]
        v[F["rate_cycle"]] = used / max(el_h, 1 / 60)
        v[F["accel"]] = rates[0] - rates[2]
        v[F["proj_cycle"]] = min(v[F["rate_cycle"]] * rem_h, head)
        v[F["proj_rate1"]] = min(rates[1] * rem_h, head)
        for name, q in (("traj_25", 0.25), ("traj_50", 0.5), ("traj_75", 0.75)):
            v[F[name]] = step_value(st.te, st.util, S + q * el, S)
        span = st.te >= asof - LOOKBACKS[kind][2]
        if span.sum() > 2:
            v[F["flat_share"]] = float(np.mean(np.diff(st.util[span]) <= 0))

        T = self.data.turns.get(acct)
        fam = cap_family(series.cap)              # a per-model cap counts that family's spend only
        spends = []
        for i, L in enumerate(SPEND_LOOKBACKS[kind]):
            spends.append(T.spend(asof - L, asof, asof, fam) / (L / HOUR_MS) if T is not None else 0.0)
            v[F[f"spend_{i}"]] = spends[-1]
        sc = T.spend(S, asof, asof, fam) if T is not None else 0.0
        ss = T.spend(st.last_te, asof, asof, fam) if T is not None else 0.0
        v[F["spend_cycle"]] = sc
        v[F["spend_since_read"]] = ss
        rho = self.conversion(series, asof)
        rho0 = _fin(rho)
        v[F["conv"]] = rho0
        v[F["conv_rate_0"]] = spends[0] * rho0
        v[F["conv_rate_1"]] = spends[1] * rho0
        v[F["nowcast_gap"]] = min(ss * rho0, head)
        v[F["conv_resid"]] = used - sc * rho0 if math.isfinite(rho) else 0.0
        v[F["conv_proj"]] = min(spends[1] * rho0 * rem_h, head)

        prof = self.profile(acct, asof, fam)
        er_usd, er_act = prof.integral(asof, R)
        ee_usd, ee_act = prof.integral(S, asof)
        v[F["exp_spend_rem"]] = er_usd
        v[F["exp_active_rem"]] = er_act
        v[F["exp_pts_rem"]] = min(er_usd * rho0, 100.0)
        v[F["act_frac_left"]] = er_act / (er_act + ee_act) if er_act + ee_act > 1e-9 else rem / D
        slot = prof.slot(asof)
        v[F["active_now"]] = prof.active[slot]
        v[F["exp_spend_next_h"]] = prof.integral(asof, asof + HOUR_MS)[0]
        hod = (slot % 24) + ((asof + prof.tz_ms) % HOUR_MS) / HOUR_MS
        dow = slot // 24
        v[F["hod_sin"]], v[F["hod_cos"]] = math.sin(2 * math.pi * hod / 24), math.cos(2 * math.pi * hod / 24)
        v[F["dow_sin"]], v[F["dow_cos"]] = math.sin(2 * math.pi * dow / 7), math.cos(2 * math.pi * dow / 7)

        u = min(el / D, 1.0)
        v[F["n_past"]] = math.log1p(series.n_outcomes(asof))
        last = series.outcomes(asof, last=PAST_N)
        if last:
            fin = np.array([c.final for c in last])
            ph = np.array([np.interp(u, PHASE_U, c.phase) for c in last])
            v[F["past_final_mean"]] = fin.mean()
            v[F["past_final_last"]] = fin[-1]
            v[F["past_hit"]] = float((fin >= 99).mean())
            v[F["past_phase_rise"]] = float(np.mean(np.maximum(fin - ph, 0)))
            v[F["past_phase_rise_max"]] = float(np.max(np.maximum(fin - ph, 0)))
        pfin, pph = self.pool(asof, series.cap)
        if len(pfin):
            col = np.array([np.interp(u, PHASE_U, r) for r in pph])
            v[F["pool_final_mean"]] = pfin.mean()
            v[F["pool_phase_rise"]] = float(np.mean(np.maximum(pfin - col, 0)))
            v[F["pool_hit"]] = float((pfin >= 99).mean())

        other = self.data.meter(acct, OTHER[kind])
        if other is not None:
            lvl, efrac, _ = other.level_at(asof)
            v[F["x_level"]] = lvl
            v[F["x_elapsed"]] = _fin(efrac, -1.0)
            ost = other.state_at(asof)
            if ost is not None:
                L = LOOKBACKS[OTHER[kind]][1]
                v[F["x_rate"]] = max(ost.used - step_value(ost.te, ost.util, asof - L, ost.start), 0) / (L / HOUR_MS)

        if T is not None:
            i15 = T.window(asof - 15 * MIN_MS, asof, asof)
            i60 = T.window(asof - HOUR_MS, asof, asof)
            v[F["sess_15m"]] = len(np.unique(T.session[i15]))
            v[F["sess_60m"]] = len(np.unique(T.session[i60]))
            v[F["turns_15m"]] = math.log1p(len(i15))
            v[F["sub_share_60m"]] = float(T.sub[i60].mean()) if len(i60) else 0.0
            b = int(np.searchsorted(T.te, asof, side="right"))
            known = np.flatnonzero(T.tk[max(0, b - 2000):b] <= asof)
            v[F["idle_h"]] = min((asof - T.te[max(0, b - 2000) + known[-1]]) / HOUR_MS, 48.0) if len(known) else 48.0
            i6 = T.window(asof - 6 * HOUR_MS, asof, asof)
            if len(i6):
                c6 = np.nan_to_num(T.cost[i6])
                tot = c6.sum()
                if tot > 0:
                    for fname in ("fable", "opus", "sonnet", "haiku"):
                        v[F[f"mix_{fname}"]] = float(c6[T.fam[i6] == FAMILIES.index(fname)].sum() / tot)
        else:
            v[F["idle_h"]] = 48.0
        v[F["prompts_15m"]] = self.data.human_prompts(acct, asof - 15 * MIN_MS, asof, asof)
        v[F["prompts_60m"]] = self.data.human_prompts(acct, asof - HOUR_MS, asof, asof)

        v[F["n_acct_7d"]] = self.accounts_in_use(asof)
        n1, others = 0, 0.0
        for a, Ta in self.data.turns.items():
            i = Ta.window(asof - HOUR_MS, asof, asof)
            if len(i):
                n1 += 1
                if a != acct:
                    others += float(np.nansum(Ta.cost[i]))
        v[F["n_acct_1h"]] = n1
        v[F["others_spend_1h"]] = others
        return np.nan_to_num(v, nan=0.0, posinf=0.0, neginf=0.0)

    def lead_rows(self, row: np.ndarray, series: MeterSeries, asof: int, reset: int,
                  fracs: np.ndarray) -> np.ndarray:
        """Per-lead features for leads `fracs` of the time left to `reset`."""
        prof = self.profile(series.account, asof, cap_family(series.cap))
        rem_h = max(reset - asof, 0) / HOUR_MS
        rho = row[F["conv"]]
        out = np.zeros((len(fracs), len(LEAD_NAMES)))
        for j, f in enumerate(fracs):
            lead_h = f * rem_h
            usd, act = prof.integral(asof, asof + lead_h * HOUR_MS)
            out[j] = (f, lead_h, row[F["rate_1"]] * lead_h, row[F["conv_rate_1"]] * lead_h,
                      min(usd * rho, 100.0), act)
        return out
