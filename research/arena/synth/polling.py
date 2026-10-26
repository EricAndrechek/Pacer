"""The client side of the meters: when Pacer was polling, and what each poll
read.

One Pacer install polls every account (the real setup is one Mac with
several accounts; here it also hosts the synthetic users' accounts), so
`app_alive` is one machine-wide set of intervals. Pacer is off some nights,
for some daytime gaps and for one multi-day outage; gaps under 15 minutes
only drop polls and don't close an interval.

Cadence comes in eras (5 min → 60 s → 15 s by default) and adapts: an account
with a turn in the last `hot_window_s` is polled at the era's active cadence,
otherwise at its idle cadence. A reading reports the server's meter as of
`t - server_lag`, floored to an integer and capped at 100; an idle window
reports util 0 and a null `resets_at`. `resets_at` jitters by milliseconds,
and a small share of readings come back a point or more below the last one.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import polars as pl

from .config import DAY_MS, HOUR_MS, MIN_MS, SynthConfig, UserSpec
from .meters import Account, MeterResult

BIG = np.iinfo(np.int64).max // 4


@dataclass
class Alive:
    """When Pacer was polling (`starts`/`ends`, the app_alive intervals), the
    short gaps inside them that only drop polls (`blips`), and when the
    machine was awake at all (`awake`, for the account switcher's polls)."""

    starts: np.ndarray
    ends: np.ndarray
    blips: np.ndarray            # [n, 2]
    awake: np.ndarray            # [n, 2]

    def inside(self, t: np.ndarray) -> np.ndarray:
        return _inside(self.starts, self.ends, t)

    def is_awake(self, t: np.ndarray) -> np.ndarray:
        return _inside(self.awake[:, 0], self.awake[:, 1], t)

    def after(self, t: np.ndarray, delay_ms: np.ndarray | int = 0) -> np.ndarray:
        """t if Pacer was polling then, else the next interval's start plus
        the scan's catch-up delay; BIG if Pacer never polled again."""
        t = np.asarray(t, dtype=np.int64)
        ins = self.inside(t)
        j = np.searchsorted(self.starts, t, side="right")
        nxt = np.where(j < len(self.starts), self.starts[np.minimum(j, len(self.starts) - 1)], BIG)
        nxt = np.where(nxt < BIG, nxt + delay_ms, BIG)
        return np.where(ins, t, nxt)


def _inside(starts: np.ndarray, ends: np.ndarray, t: np.ndarray) -> np.ndarray:
    t = np.asarray(t, dtype=np.int64)
    i = np.searchsorted(starts, t, side="right") - 1
    ok = i >= 0
    out = np.zeros(len(t), dtype=bool)
    out[ok] = t[ok] < ends[i[ok]]
    return out


def _merge(iv: list[tuple[int, int]]) -> list[tuple[int, int]]:
    out: list[list[int]] = []
    for s, e in sorted(iv):
        if out and s <= out[-1][1]:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return [(s, e) for s, e in out]


def _complement(off: list[tuple[int, int]], t0: int, t1: int, min_len: int) -> list[tuple[int, int]]:
    out, cur = [], t0
    for s, e in _merge(off):
        s, e = max(s, t0), min(e, t1)
        if e <= s:
            continue
        if s - cur >= min_len:
            out.append((cur, s))
        cur = max(cur, e)
    if t1 - cur >= min_len:
        out.append((cur, t1))
    return out


def build_alive(cfg: SynthConfig, host: UserSpec, rng: np.random.Generator, turn_t: np.ndarray) -> Alive:
    """Two kinds of gap:
    - the machine sleeping (nights): it only falls asleep after
      `sleep_idle_min` without a turn and wakes at the next one, so no turn
      happens while it sleeps, and the account switcher stops too;
    - Pacer not polling while the machine is up (daytime gaps: network,
      relaunches, expired tokens; and the long outages): turns go on, and
      Pacer learns of them only when it polls again.
    A gap shorter than `interval_close_gap_min` drops polls without closing
    an app_alive interval."""
    p = cfg.polling
    t0, t1 = cfg.start_ms, cfg.end_ms
    close_ms = int(p.interval_close_gap_min * MIN_MS)
    idle_ms = int(p.sleep_idle_min * MIN_MS)
    turn_t = np.sort(np.asarray(turn_t, np.int64))
    sleeps: list[tuple[int, int]] = []
    day0 = t0 - t0 % DAY_MS
    for d in range(cfg.days + 1):
        if rng.uniform() < p.night_off_prob:
            local_start = p.night_off_start_h + rng.normal(0, 0.75)
            s = day0 + d * DAY_MS + int(local_start * HOUR_MS) - host.tz_offset_min * MIN_MS
            dur = max(1.0, p.night_off_hours + rng.normal(0, 1.0))
            e = s + int(dur * HOUR_MS)
            # Fall asleep only once nobody has used the machine for a while.
            while True:
                j = np.searchsorted(turn_t, s, side="right") - 1
                if j >= 0 and turn_t[j] > s - idle_ms:
                    s = int(turn_t[j]) + idle_ms
                    continue
                break
            j = np.searchsorted(turn_t, s, side="right")
            if j < turn_t.size and turn_t[j] < e:
                e = int(turn_t[j]) - 30_000          # woken by its next use
            if e - s >= MIN_MS:
                sleeps.append((s, e))
    pacer_off: list[tuple[int, int]] = []
    n_gaps = rng.poisson(p.day_gaps_per_day * cfg.days)
    for _ in range(n_gaps):
        s = int(rng.uniform(t0, t1))
        dur = max(p.interval_close_gap_min + 1, rng.lognormal(np.log(p.day_gap_min_median), 0.6))
        pacer_off.append((s, s + int(dur * MIN_MS)))
    for frac, hours in p.outages:
        s = cfg.at(frac)
        pacer_off.append((s, s + int(hours * HOUR_MS)))
    short = [(s, e) for s, e in sleeps if e - s < close_ms]
    closing = [(s, e) for s, e in sleeps if e - s >= close_ms] + pacer_off
    alive = _complement(closing, t0, t1, 2 * MIN_MS)
    awake = _complement([(s, e) for s, e in sleeps if e - s >= close_ms], t0, t1, 0)
    n_blips = rng.poisson(p.blips_per_day * cfg.days)
    bs = rng.uniform(t0, t1, n_blips).astype(np.int64)
    blips = [(int(a), int(a + rng.uniform(2, 12) * MIN_MS)) for a in bs] + short
    blips_np = np.array(sorted(blips), np.int64).reshape(-1, 2)
    return Alive(np.array([a for a, _ in alive], np.int64), np.array([b for _, b in alive], np.int64),
                 blips_np, np.array(awake, np.int64).reshape(-1, 2))


def poll_times(cfg: SynthConfig, start: int, turn_t: np.ndarray, alive: Alive,
               rng: np.random.Generator) -> np.ndarray:
    """Adaptive oauth poll times for one account from `start`."""
    p = cfg.polling
    eras = sorted(p.cadence_eras)
    hot = int(p.hot_window_s * 1000)
    out = []
    for k, (frac, act_s, idle_s) in enumerate(eras):
        e0 = max(cfg.at(frac), start)
        e1 = cfg.at(eras[k + 1][0]) if k + 1 < len(eras) else cfg.end_ms
        if e1 <= e0:
            continue
        for cad, want_hot in ((act_s, True), (idle_s, False)):
            g = np.arange(e0 - e0 % int(cad * 1000), e1, int(cad * 1000), dtype=np.int64)
            g = g[g >= e0]
            if turn_t.size:
                j = np.searchsorted(turn_t, g, side="right")
                is_hot = (j > 0) & (g - turn_t[np.maximum(j - 1, 0)] < hot)
            else:
                is_hot = np.zeros(g.size, bool)
            out.append(g[is_hot] if want_hot else g[~is_hot])
    t = np.unique(np.concatenate(out)) if out else np.zeros(0, np.int64)
    t = t + rng.integers(0, int(p.poll_jitter_s * 1000) + 1, size=t.size)
    t = t[alive.inside(t)]
    if len(alive.blips):
        b = np.array(_merge([tuple(x) for x in alive.blips.tolist()]), np.int64).reshape(-1, 2)
        t = t[~_inside(b[:, 0], b[:, 1], t)]
    t = t[rng.uniform(size=t.size) >= p.missed_poll_prob]
    return np.unique(t)


def cswap_times(cfg: SynthConfig, start: int, alive: Alive, rng: np.random.Generator) -> np.ndarray:
    """The account switcher polls on its own schedule whenever the machine is
    awake, Pacer running or not."""
    p = cfg.polling
    s = max(start, cfg.at(p.cswap_from_frac))
    step = int(p.cswap_every_s * 1000)
    g = np.arange(s, cfg.end_ms, step, dtype=np.int64)
    g = np.unique(g + rng.integers(0, step // 3, size=g.size))
    return g[alive.is_awake(g)]


def meter_at(cyc_first: np.ndarray, cyc_reset: np.ndarray, cyc_id: np.ndarray,
             inc_t: np.ndarray, inc_act: np.ndarray, inc_cyc: np.ndarray,
             p: np.ndarray, lag: int):
    """Server state seen by polls at p: (active, util, reset, cycle id)."""
    q = p - lag
    ci = np.searchsorted(cyc_first, q, side="right") - 1
    ok = ci >= 0
    ci0 = np.maximum(ci, 0)
    active = ok & (p < cyc_reset[ci0]) if len(cyc_first) else np.zeros(len(p), bool)
    util = np.zeros(len(p), dtype=np.float64)
    if len(inc_t):
        j = np.searchsorted(inc_t, q, side="right") - 1
        jj = np.maximum(j, 0)
        same = (j >= 0) & active & (inc_cyc[jj] == (cyc_id[ci0] if len(cyc_id) else -1))
        util[same] = inc_act[jj[same]]
    reset = np.where(active, cyc_reset[ci0] if len(cyc_reset) else 0, 0)
    cid = np.where(active, cyc_id[ci0] if len(cyc_id) else -1, -1)
    return active, util, reset, cid


def _report(util: np.ndarray, rounding: str) -> np.ndarray:
    v = np.floor(util + 1e-9) if rounding == "floor" else np.round(util)
    return np.minimum(v, 100.0)


def build_readings(cfg: SynthConfig, accounts: list[Account], users: list[UserSpec], mr: MeterResult,
                   alive: Alive, scoped_from: int, rng: np.random.Generator) -> pl.DataFrame:
    """Every reading, before t_known filtering, as a polars frame (times in ms)."""
    m, p, lags = cfg.meter, cfg.polling, cfg.lags
    lag_ms = int(m.server_lag_s * 1000)
    hist_from = cfg.at(cfg.eras.history_from_frac)
    archive_before = cfg.at(p.archive_before_frac)
    user_names = [u.name for u in users]
    cyc_np = {}
    for wk in ("five_hour", "seven_day", "weekly_scoped"):
        c = mr.cycles[wk]
        cyc_np[wk] = (np.array([x["acc"] for x in c], np.int32), np.array([x["first_use"] for x in c], np.int64),
                      np.array([x["reset"] for x in c], np.int64))
    frames = []
    dup_next = 1
    for a in accounts:
        # Turns on this account (the meter's increments carry the kept turns).
        inc5 = mr.inc["five_hour"]
        turn_t = np.sort(inc5["t"][(inc5["acc"] == a.gid) & (inc5["src"] == 0)])
        # Each account draws from its own stream (keyed by user and the
        # account's place in that user's list, not by its label).
        arng = np.random.default_rng(np.random.SeedSequence(cfg.seed, spawn_key=(12, a.user, a.local)))
        sources = [("oauth", poll_times(cfg, a.added, turn_t, alive, arng))]
        if user_names[a.user] in p.cswap_users:
            sources.append(("cswap", cswap_times(cfg, a.added, alive, arng)))
        for src, polls in sources:
            if polls.size == 0:
                continue
            kinds = ["five_hour", "seven_day"]
            if src == "oauth":
                kinds.append("weekly_scoped")
            twin = np.zeros(polls.size, np.int64)
            if src == "oauth" and p.twin_every_n > 0:
                in_era = polls >= scoped_from
                idx = np.flatnonzero(in_era)[:: p.twin_every_n]
                twin[idx] = dup_next + np.arange(idx.size)
                dup_next += idx.size
            for wk in kinds:
                pp = polls if wk != "weekly_scoped" else polls[polls >= scoped_from]
                if pp.size == 0:
                    continue
                cw = "seven_day" if wk == "weekly_scoped" else wk
                cacc, cfirst, creset = cyc_np[cw]
                cm = cacc == a.gid
                cid = np.flatnonzero(cm)
                inc = mr.inc[wk]
                im = inc["acc"] == a.gid
                active, util, reset, cyc = meter_at(cfirst[cm], creset[cm], cid, inc["t"][im],
                                                    inc["act"][im], inc["cyc"][im], pp, lag_ms)
                rep = np.where(active, _report(util, m.rounding), 0.0)
                # Occasional readings below the last one (rounding flaps,
                # replica lag); a rare few by several points. Only where the
                # meter hadn't moved since the previous poll of the same cycle,
                # and never twice in a row, so every injected drop is visible
                # as a drop (backwards_pp > 0) and every other reading is exact.
                r = arng.uniform(size=pp.size)
                flat = np.zeros(pp.size, bool)
                flat[1:] = active[1:] & (cyc[1:] == cyc[:-1]) & (rep[1:] == rep[:-1])
                cand = flat & (r < p.backwards_prob + p.backwards_big_prob)
                cand[1:] &= ~cand[:-1]
                k = np.where(r < p.backwards_prob, 1, arng.integers(2, 6, size=pp.size))
                k = np.minimum(k, rep)
                rep = np.where(cand & (k > 0), rep - k, rep)
                jit = arng.normal(0, p.reset_jitter_ms_sd, size=pp.size)
                jb = arng.uniform(size=pp.size) < p.reset_jitter_big_prob
                jit = np.where(jb, arng.uniform(-2400, 2400, size=pp.size), np.clip(jit, -1500, 1500))
                resets = np.where(active, reset + jit.astype(np.int64), -1)
                tw = twin[np.searchsorted(polls, pp)] if src == "oauth" else np.zeros(pp.size, np.int64)
                frames.append(pl.DataFrame({
                    "t_event": pp, "acc": np.full(pp.size, a.gid, np.int32), "window_kind": wk,
                    "source": src, "util_pct": rep, "util_true": util, "resets_at": resets,
                    "active": active, "cyc": cyc.astype(np.int64),
                    "dup_group": np.where(tw > 0, tw, -1) if wk in ("five_hour", "seven_day") else np.full(pp.size, -1),
                }))
                if src == "oauth" and wk in ("five_hour", "seven_day"):
                    tm = tw > 0
                    if tm.any():
                        frames.append(pl.DataFrame({
                            "t_event": pp[tm], "acc": np.full(int(tm.sum()), a.gid, np.int32),
                            "window_kind": "session" if wk == "five_hour" else "weekly_all",
                            "source": src, "util_pct": rep[tm], "util_true": util[tm], "resets_at": resets[tm],
                            "active": active[tm], "cyc": cyc[tm].astype(np.int64), "dup_group": tw[tm],
                        }))
    df = pl.concat(frames).sort([pl.col("acc"), pl.col("window_kind"), pl.col("t_event"),
                                 pl.col("source") == "cswap"])
    # Real snapshots dedupe on (account, window, t_event); oauth wins over cswap.
    df = df.unique(subset=["acc", "window_kind", "t_event"], keep="first", maintain_order=True)
    # backwards_pp: how far a reading fell below the highest earlier one in
    # its cycle. Twins are the same poll as their canonical row, so they carry
    # its flag rather than one computed over their own sparse series.
    twin_of = {"session": "five_hour", "weekly_all": "seven_day"}
    is_twin = pl.col("window_kind").is_in(list(twin_of))
    canon = df.filter(~is_twin).with_columns(
        pl.col("util_pct").cum_max().shift(1).over(["acc", "window_kind", "source", "cyc"]).alias("_prev"))
    canon = canon.with_columns(
        pl.when(pl.col("active") & (pl.col("_prev") > pl.col("util_pct")))
        .then(pl.col("_prev") - pl.col("util_pct")).otherwise(0.0).alias("backwards_pp")).drop("_prev")
    twins = df.filter(is_twin).with_columns(pl.col("window_kind").replace_strict(twin_of).alias("_canon"))
    twins = twins.join(canon.select("acc", "dup_group", pl.col("window_kind").alias("_canon"), "backwards_pp"),
                       on=["acc", "dup_group", "_canon"], how="left").drop("_canon")
    df = pl.concat([canon, twins.select(canon.columns)]).sort(["acc", "window_kind", "t_event"])
    # Clocks.
    n = df.height
    t_ev = df["t_event"].to_numpy()
    is_cswap = (df["source"] == "cswap").to_numpy()
    lag_o = rng.lognormal(np.log(lags.reading_median_s), lags.reading_sigma, n)
    tail = rng.uniform(size=n) < lags.reading_tail_prob
    lag_o = np.where(tail, rng.uniform(4, lags.reading_tail_max_s, n), lag_o)
    lag_c = np.minimum(rng.lognormal(np.log(lags.cswap_median_s), lags.cswap_sigma, n), 6 * 60.0)
    in_hist = t_ev >= hist_from
    t_known_o = np.where(in_hist, t_ev + (lag_o * 1000).astype(np.int64), t_ev)
    t_known_c = alive.after(t_ev + (lag_c * 1000).astype(np.int64), int(lags.scan_delay_s * 1000))
    t_known = np.where(is_cswap, t_known_c, t_known_o)
    src = np.where(in_hist, "history", np.where(is_cswap, "modeled", "observed"))
    df = df.with_columns(
        pl.Series("t_known", t_known), pl.Series("t_known_src", src),
        pl.when(pl.col("t_event") < archive_before).then(pl.lit("archive")).otherwise(pl.lit("live")).alias("origin"),
    )
    return df
