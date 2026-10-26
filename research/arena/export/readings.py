"""`meter_readings`, `cycles` (labels) and `app_alive` (spec §2.1).

Readings are the live tables ∪ the archive (the live tables are a 35-day
cache; older rows move to the archive and are deleted from live), deduped on
(account, window, scope, t_event) with the live copy preferred because only
it has an insert in history. A null `resets_at` is kept as an explicit
`idle` row: it means no 5-hour window is running, which is information.

Cycles are segmented with the `RateLimitCycle.contains` rule — a reading
belongs to a cycle when its reset is within half a window of the cycle's —
never with `resets_at ==` (resets jitter by milliseconds; correctness rule 9).
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd

from . import clocks

WINDOW_MS = {"five_hour": 5 * clocks.HOUR, "seven_day": 7 * clocks.DAY, "session": 5 * clocks.HOUR,
             "weekly_all": 7 * clocks.DAY, "weekly_scoped": 7 * clocks.DAY}
TWIN = {"session": "five_hour", "weekly_all": "seven_day"}
STREAM_CSWAP_LAG = 2


def _scope_model(identity: str | None, display: str | None) -> str | None:
    if isinstance(display, str) and display:
        return display
    if isinstance(identity, str):
        parts = identity.split("|")
        if len(parts) >= 2 and parts[0] == "weekly_scoped" and parts[1]:
            return parts[1]
    return None


def unify(inp) -> pd.DataFrame:
    """Every reading as one frame with raw account ids."""
    frames = []
    rl = inp.rl
    if len(rl):
        frames.append(pd.DataFrame({
            "pk": rl["pk"], "entity": "RateLimitSample", "origin": "live", "t_event": rl["t"],
            "account_id": rl["account_id"], "window_kind": rl["window"], "scope_model": None,
            "identity": rl["window"], "util_pct": rl["util"], "resets_at": rl["resets_at"],
            "severity": None, "source": rl["source"]}))
    ul = inp.ul
    if len(ul):
        frames.append(pd.DataFrame({
            "pk": ul["pk"], "entity": "UsageLimitSample", "origin": "live", "t_event": ul["t"],
            "account_id": ul["account_id"], "window_kind": ul["kind"],
            "scope_model": [_scope_model(i, d) if k == "weekly_scoped" else None
                            for i, d, k in zip(ul["identity"], ul["model_display"], ul["kind"])],
            "identity": ul["identity"], "util_pct": ul["util"], "resets_at": ul["resets_at"],
            "severity": ul["severity"], "source": ul["source"]}))
    ar = inp.archive
    if len(ar):
        rla = ar[ar["kind"] == "rate_limit"]
        frames.append(pd.DataFrame({
            "pk": rla["pk"], "entity": "AccountUsageArchive", "origin": "archive", "t_event": rla["t"],
            "account_id": rla["account_id"], "window_kind": rla["window"], "scope_model": None,
            "identity": rla["window"], "util_pct": rla["util"], "resets_at": rla["resets_at"],
            "severity": rla["severity"], "source": rla["source"]}))
        ula = ar[ar["kind"] == "usage_limit"]
        frames.append(pd.DataFrame({
            "pk": ula["pk"], "entity": "AccountUsageArchive", "origin": "archive", "t_event": ula["t"],
            "account_id": ula["account_id"], "window_kind": ula["limit_kind"],
            "scope_model": [_scope_model(i, d) if k == "weekly_scoped" else None
                            for i, d, k in zip(ula["identity"], ula["model_display"], ula["limit_kind"])],
            "identity": ula["identity"], "util_pct": ula["util"], "resets_at": ula["resets_at"],
            "severity": ula["severity"], "source": ula["source"]}))
    df = pd.concat(frames, ignore_index=True) if frames else pd.DataFrame(
        columns=["pk", "entity", "origin", "t_event", "account_id", "window_kind", "scope_model", "identity",
                 "util_pct", "resets_at", "severity", "source"])
    df = df[df["t_event"].notna() & df["window_kind"].notna()].copy()
    df["t_event"] = df["t_event"].astype("int64")
    df["resets_at"] = df["resets_at"].astype("Int64")
    df["util_pct"] = df["util_pct"].astype("float64")
    df["scope_key"] = df["scope_model"].fillna("")
    df["acct_key"] = df["account_id"].fillna("")
    df["_live"] = (df["origin"] == "live").astype(int)
    df = df.sort_values(["acct_key", "window_kind", "scope_key", "t_event", "_live", "pk"],
                        ascending=[True, True, True, True, False, True], kind="stable")
    before = len(df)
    df = df.drop_duplicates(["acct_key", "window_kind", "scope_key", "t_event"], keep="first")
    df.attrs["dedup_dropped"] = before - len(df)
    return df.reset_index(drop=True)


def app_alive(readings: pd.DataFrame) -> clocks.Alive:
    oauth = readings[(readings["source"] == "oauth") & readings["window_kind"].isin(["five_hour", "seven_day"])]
    return clocks.Alive.from_polls(oauth["t_event"].to_numpy(dtype=np.int64))


def assign_t_known(df: pd.DataFrame, inp, alive: clocks.Alive, hasher) -> tuple[pd.DataFrame, clocks.LagModel]:
    """oauth: the live row's insert, else t_event (recorded at the poll).
    cswap: the insert, else t_event + a seeded draw from the cswap insert
    lag. An archived row's own insert is its archival, 35 days on, and is
    never used. An insert long after the reading is a backfill and ignored."""
    ri = inp.reading_inserts
    ins = ri.groupby(["entity", "pk"])["t"].min()
    key = list(zip(df["entity"], df["pk"]))
    t_ins = np.array([ins.get(k, np.nan) if df_origin == "live" else np.nan
                      for k, df_origin in zip(key, df["origin"])], dtype="float64")
    t_ev = df["t_event"].to_numpy(dtype=np.int64)
    has = ~np.isnan(t_ins) & (t_ins <= t_ev + clocks.BACKFILL_SLACK_MS)
    cswap = (df["source"] == "cswap").to_numpy()
    fit = has & cswap & alive.is_alive(t_ev)
    lag = clocks.LagModel.fit("cswap_ingest", (t_ins - t_ev)[fit])
    ids = np.fromiter((hasher.h("reading", f"{e}|{p}") for e, p in key), dtype=np.uint64, count=len(df))
    modeled = clocks.modeled_t_known(t_ev, ids, lag, alive, STREAM_CSWAP_LAG)
    tk = np.where(has, np.nan_to_num(t_ins, nan=0).astype(np.int64), np.where(cswap, modeled, t_ev))
    df["t_known"] = np.maximum(tk, t_ev)
    df["t_known_src"] = np.where(has, "history", np.where(cswap, "modeled", "observed"))
    return df, lag


def segment_cycles(df: pd.DataFrame) -> pd.Series:
    """Cycle key per active reading (NaN for idle): per (account, window,
    scope), resets clustered so that consecutive distinct resets more than
    half a window apart start a new cycle. Order-independent."""
    cyc = pd.Series(np.nan, index=df.index)
    active = df[df["resets_at"].notna()]
    next_id = 0
    for (a, w, s), g in active.groupby(["acct_key", "window_kind", "scope_key"], sort=True):
        half = WINDOW_MS.get(w, 5 * clocks.HOUR) / 2
        r = g["resets_at"].to_numpy(dtype=np.int64)
        u = np.unique(r)
        brk = np.concatenate([[True], np.diff(u) > half])
        cid = np.cumsum(brk) - 1 + next_id
        next_id = int(cid[-1]) + 1
        cyc.loc[g.index] = cid[np.searchsorted(u, r)]
    return cyc


@dataclass
class ReadingsResult:
    readings: pd.DataFrame      # snapshot columns + helpers (account_id, cycle, t_event…)
    cycles: pd.DataFrame
    alive: clocks.Alive
    lag: clocks.LagModel
    stats: dict


def build_readings(df: pd.DataFrame, labels: dict[str, str], data_end_ms: int) -> tuple[pd.DataFrame, pd.DataFrame]:
    df = df.copy()
    df["account"] = [labels.get(a) if isinstance(a, str) else None for a in df["account_id"]]
    df["state"] = np.where(df["resets_at"].notna(), "active", "idle")
    df["cycle"] = segment_cycles(df)

    # backwards_pp: how far a reading fell below the previous one in its cycle.
    df = df.sort_values(["acct_key", "window_kind", "scope_key", "t_event", "pk"], kind="stable")
    prev = df.groupby("cycle")["util_pct"].shift(1)
    back = (prev - df["util_pct"]).clip(lower=0)
    df["backwards_pp"] = back.where(df["cycle"].notna(), np.nan)
    df.loc[df["cycle"].notna() & df["backwards_pp"].isna(), "backwards_pp"] = 0.0

    # dup_group: a session / weekly_all row and its 5h / 7d twin from the same poll.
    df["dup_group"] = pd.array([pd.NA] * len(df), dtype="Int64")
    base = df[df["window_kind"].isin(["five_hour", "seven_day"])][["acct_key", "window_kind", "t_event"]]
    base_idx = {(a, w, t): i for i, a, w, t in zip(base.index, base["acct_key"], base["window_kind"], base["t_event"])}
    pairs = []
    for i, a, w, t in zip(df.index, df["acct_key"], df["window_kind"], df["t_event"]):
        tw = TWIN.get(w)
        if tw is None:
            continue
        j = base_idx.get((a, tw, t))
        if j is not None:
            pairs.append((a, t, tw, i, j))
    pairs.sort(key=lambda p: (labels.get(p[0], ""), p[1], p[2]))
    for g, (_, _, _, i, j) in enumerate(pairs, start=1):
        df.at[i, "dup_group"] = g
        df.at[j, "dup_group"] = g

    cycles = _cycles(df, data_end_ms)
    df = df.sort_values(["t_known", "t_event", "acct_key", "window_kind", "scope_key", "pk"], kind="stable")
    return df.reset_index(drop=True), cycles


def _cycles(df: pd.DataFrame, data_end_ms: int) -> pd.DataFrame:
    rows = []
    act = df[df["cycle"].notna()]
    for cid, g in act.groupby("cycle", sort=True):
        g = g.sort_values(["t_event", "pk"])
        w = g["window_kind"].iloc[0]
        reset = int(np.median(g["resets_at"].to_numpy(dtype=np.int64)))
        win = WINDOW_MS.get(w, 5 * clocks.HOUR)
        first_t, last_t = int(g["t_event"].iloc[0]), int(g["t_event"].iloc[-1])
        acct = g["account"].iloc[0]
        scope = g["scope_model"].iloc[0]
        rows.append({
            "cycle_id": f"{acct}|{w}|{scope or ''}|{pd.Timestamp(reset, unit='ms', tz='UTC').strftime('%Y-%m-%dT%H:%M:%SZ')}",
            "account": acct, "window_kind": w, "scope_model": scope,
            "reset_at": reset, "start": reset - win, "first_t": first_t, "last_t": last_t,
            "n": len(g), "max_util": float(g["util_pct"].max()), "final_util": float(g["util_pct"].iloc[-1]),
            "first_util": float(g["util_pct"].iloc[0]),
            "censored": bool(reset > data_end_ms),
            "t_event": reset - win, "t_known": max(reset, last_t), "t_known_src": "unknown",
            "resets_spread_ms": int(g["resets_at"].max() - g["resets_at"].min()),
        })
    cols = ["cycle_id", "account", "window_kind", "scope_model", "reset_at", "start", "first_t", "last_t", "n",
            "max_util", "final_util", "first_util", "censored", "t_event", "t_known", "t_known_src", "resets_spread_ms"]
    c = pd.DataFrame(rows, columns=cols)
    return c.sort_values(["account", "window_kind", "scope_model", "reset_at"], na_position="first",
                         kind="stable").reset_index(drop=True)
