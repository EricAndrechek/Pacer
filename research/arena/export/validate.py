"""The nine validation gates (spec §2.5). Failing any one means no snapshot.

Each gate returns a dict: `gate`, `passed`, `details` (counts and rates
only; never an id, path or text). Where the spec's "never" meets known,
explained exceptions in the real data, the tolerance is a named constant
here and the count is always reported, so a tolerance can't hide a change.
"""
from __future__ import annotations

import hashlib
import re

import numpy as np
import pandas as pd
import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.dataset as ds

from arena.snapshot.schema import DATA_TABLES, LABEL_TABLES, TABLES

from . import clocks
from .prices import ledger_rate_lookup
from .util import canonical_model

# Rows written while the copies were taken can differ between copies taken
# seconds apart (a streamed message upgraded in one and not yet in another).
IN_FLIGHT_MS = 1 * clocks.HOUR
COVERAGE_MIN = 0.95
COST_STATE_TOLERANCE = 0.02
# Readings and cycles: known exceptions in the real data (replica lag makes a
# reading fall back; a handful of idle rows carry a value) are flagged in the
# data and counted here. A gate fails when they exceed these shares.
MAX_BACKWARDS_SHARE = 1e-4        # readings falling > 1 pp within their cycle
MAX_IDLE_NONZERO_SHARE = 1e-4     # idle readings with util > 0
RESET_JITTER_P999_MS = 5_000
MAX_POLL_GAP_MS = 30 * clocks.MINUTE
# Turns that fall inside a > 30 min gap in their account's readings while
# Pacer was polling, as a share of all turns. Secondary accounts' polls back
# off under HTTP 429 (cswap logs ~1.3k of them), which leaves real gaps.
MAX_UNEXPLAINED_GAP_SHARE = 0.01
CYCLE_SLACK_MS = 2 * clocks.MINUTE
# Adjacent cycles may touch within reset jitter (milliseconds).
CYCLE_JITTER_MS = 5 * clocks.SECOND
# Cycles whose readings fall outside [start, reset] (the server moved the
# reset within an active window) or that restart above the previous cycle's
# max right at a back-to-back rollover, as a share of cycles.
MAX_CYCLE_ANOMALY_SHARE = 0.02
ROLLOVER_FIRST_READING_MS = 10 * clocks.MINUTE
PIT_CUTOFFS = 200
PIT_SEED = 7
PIT_VIEW_CUTOFFS = 8          # cutoffs at which gate 7 also reads through core's views (each is a full slice)


def _ok(name: str, passed: bool, **details) -> dict:
    return {"gate": name, "passed": bool(passed), "details": details}


# 1 -------------------------------------------------------------------------
def gate_store_vs_transcripts(turns: pd.DataFrame, copy_ms: int) -> dict:
    t = turns[turns["t_event"] < copy_ms - IN_FLIGHT_MS]
    has = t["key"].notna()
    day = pd.to_datetime(t["t_event"], unit="ms", utc=True).dt.strftime("%Y-%m-%d")
    grp = pd.DataFrame({"day": day, "model": t["model"], "account": t["account"], "has": has})
    cov = grp.groupby(["day", "model", "account"], dropna=False)["has"].mean().rename("cov")
    grp = grp.join(cov, on=["day", "model", "account"])
    gated = (grp["cov"] >= COVERAGE_MIN) & grp["has"]
    g = t[gated.to_numpy()]
    parts = [("input", "tx_input"), ("output", "tx_output"), ("cache_read", "tx_cache_read"),
             ("cache_write_5m", "tx_cw5"), ("cache_write_1h", "tx_cw1")]
    mism = np.zeros(len(g), dtype=bool)
    by_part = {}
    for a, b in parts:
        m = g[a].to_numpy(dtype=np.int64) != g[b].to_numpy(dtype=np.int64)
        by_part[a] = int(m.sum())
        mism |= m
    per_day = grp.groupby("day")["has"].mean().round(4)
    return _ok("1_store_vs_transcripts", mism.sum() == 0,
               rows_compared=int(len(g)), rows_mismatched=int(mism.sum()), mismatched_by_part=by_part,
               rows_with_transcript=int(has.sum()), rows_total=int(len(t)),
               groups_gated=int((cov >= COVERAGE_MIN).sum()), groups_total=int(len(cov)),
               in_flight_excluded=int(len(turns) - len(t)),
               coverage_by_day=per_day.to_dict())


# 2 -------------------------------------------------------------------------
def gate_store_vs_archive(store_turns: pd.DataFrame, duck: dict | None) -> dict:
    if duck is None:
        return _ok("2_store_vs_archive", False, error="no DuckDB archive copy")
    a = duck["frame"]
    cutoff = min(int(store_turns["t"].max()), int(a["t"].max())) - IN_FLIGHT_MS
    s = store_turns[store_turns["t"] < cutoff]
    a = a[a["t"] < cutoff]
    sums = {}
    for sc, ac in (("input", "input_tokens"), ("output", "output_tokens"), ("cache_read", "cache_read"),
                   ("cache_write_5m", "cache_creation_5m"), ("cache_write_1h", "cache_creation_1h")):
        sums[sc] = (int(s[sc].sum()), int(a[ac].sum()))
    sums["distinct_keys"] = (int(s["dedup_key"].nunique()), int(a["dedup_key"].nunique()))
    sums["rows"] = (len(s), len(a))
    diff = {k: v[0] - v[1] for k, v in sums.items() if v[0] != v[1]}
    return _ok("2_store_vs_archive", not diff, rows=len(s), differences=diff,
               in_flight_excluded=int(len(store_turns) - len(s)))


# 3 -------------------------------------------------------------------------
def gate_cost_state(rec: pd.DataFrame) -> dict:
    ok = rec[rec["valid"] & rec["all_reliable"].astype(bool) & rec["tx_output"].gt(0)]
    defect = rec[rec["n_defect"] > 0]
    if ok.empty:
        return _ok("3_cost_state_vs_transcripts", True, skipped="no session with matched coverage",
                   defect_pairs=int(len(defect)))
    med = float(ok["ratio"].median())
    return _ok("3_cost_state_vs_transcripts", abs(med - 1.0) <= COST_STATE_TOLERANCE,
               matched_pairs=int(len(ok)), median_ratio=round(med, 4),
               ratio_p10_p90=[round(float(ok["ratio"].quantile(.1)), 4), round(float(ok["ratio"].quantile(.9)), 4)],
               pairs_total=int(len(rec)), pairs_matched_coverage=int(rec["valid"].sum()),
               defect_pairs=int(len(defect)), defect_sessions=int(defect["session_id"].nunique()),
               defect_pairs_matched=int(defect["valid"].sum()),
               defect_median_ratio=None if defect.empty else round(float(defect["ratio"].median()), 3))


# 4 -------------------------------------------------------------------------
def gate_readings(rd: pd.DataFrame, turns: pd.DataFrame, alive: pd.DataFrame) -> dict:
    act = rd[rd["state"] == "active"]
    back = int((act["backwards_pp"] > 1.0).sum())
    back_share = back / max(len(act), 1)
    med = act.groupby("cycle")["resets_at"].transform("median")
    jitter = (act["resets_at"].astype("float64") - med).abs()
    p999 = float(jitter.quantile(0.999)) if len(jitter) else 0.0
    idle = rd[rd["state"] == "idle"]
    idle_nz = int((idle["util_pct"] > 0).sum())
    idle_share = idle_nz / max(len(idle), 1)

    starts = alive["t_event"].to_numpy(dtype=np.int64)
    ends = alive["t_end"].to_numpy(dtype=np.int64)
    gaps_total, gaps_bad, by_acct, turns_in_bad = 0, 0, {}, 0
    for acct, g in rd[rd["window_kind"] == "five_hour"].groupby("account"):
        t = np.unique(g["t_event"].to_numpy(dtype=np.int64))
        if t.size < 2:
            continue
        d = np.diff(t)
        idx = np.flatnonzero(d > MAX_POLL_GAP_MS)
        tt = np.sort(turns.loc[turns["account"] == acct, "t_event"].to_numpy(dtype=np.int64))
        bad = 0
        for i in idx:
            a, b = t[i], t[i + 1]
            n_turns = np.searchsorted(tt, b, side="left") - np.searchsorted(tt, a, side="right")
            if n_turns == 0:
                continue
            gaps_total += 1
            j = np.searchsorted(starts, a, side="right") - 1
            polling_throughout = j >= 0 and ends[j] >= b
            if polling_throughout:
                bad += 1
                turns_in_bad += int(n_turns)
        gaps_bad += bad
        by_acct[acct] = bad
    gap_share = turns_in_bad / max(len(turns), 1)
    passed = (back_share <= MAX_BACKWARDS_SHARE and p999 <= RESET_JITTER_P999_MS
              and idle_share <= MAX_IDLE_NONZERO_SHARE and gap_share <= MAX_UNEXPLAINED_GAP_SHARE)
    return _ok("4_readings", passed,
               falls_over_1pp=back, falls_share=round(back_share, 6), falls_tolerance=MAX_BACKWARDS_SHARE,
               reset_jitter_p999_ms=round(p999, 1), reset_jitter_max_ms=round(float(jitter.max()) if len(jitter) else 0, 1),
               idle_rows=int(len(idle)), idle_nonzero=idle_nz, idle_nonzero_tolerance=MAX_IDLE_NONZERO_SHARE,
               gaps_over_30m_with_turns=gaps_total, gaps_while_polling=gaps_bad, gaps_while_polling_by_account=by_acct,
               turns_in_unexplained_gaps=turns_in_bad, turns_in_unexplained_gaps_share=round(gap_share, 5),
               gap_tolerance=MAX_UNEXPLAINED_GAP_SHARE)


# 5 -------------------------------------------------------------------------
def gate_cycles(cycles: pd.DataFrame) -> dict:
    """Cycles never interleave (an earlier cycle's readings never run past
    a later one's first) and resets strictly increase: both hard. A *nominal*
    overlap, where the server reset a window early and the next one started
    before the old reset time, is reported as `early_resets`. Readings
    outside [start, reset] (the server moved a reset within a window), and a
    cycle that starts above the previous one's max at a back-to-back rollover
    observed within minutes, are counted against a tolerance; the raw count
    of "first reading above the previous max" over all cycles is reported
    too (after an idle gap it is ordinary usage, not an anomaly)."""
    interleaved = nonincr = early = dur = first_hi = first_hi_raw = 0
    n = len(cycles)
    for _, g in cycles.groupby(["account", "window_kind", "scope_model"], dropna=False):
        g = g.sort_values("reset_at")
        r = g["reset_at"].to_numpy(dtype=np.int64)
        s = g["start"].to_numpy(dtype=np.int64)
        ft = g["first_t"].to_numpy(dtype=np.int64)
        lt = g["last_t"].to_numpy(dtype=np.int64)
        nonincr += int((np.diff(r) <= CYCLE_JITTER_MS).sum())
        interleaved += int((lt[:-1] > ft[1:] + CYCLE_JITTER_MS).sum())
        early += int((s[1:] < r[:-1] - CYCLE_SLACK_MS).sum())
        dur += int(((g["first_t"] < g["start"] - CYCLE_SLACK_MS) | (g["last_t"] > g["reset_at"] + CYCLE_SLACK_MS)).sum())
        above = g["first_util"].to_numpy()[1:] > g["max_util"].to_numpy()[:-1]
        first_hi_raw += int(above.sum())
        rollover = (np.abs(s[1:] - r[:-1]) <= CYCLE_SLACK_MS) & (ft[1:] - s[1:] <= ROLLOVER_FIRST_READING_MS)
        first_hi += int((above & rollover).sum())
    share = (dur + first_hi) / max(n, 1)
    passed = interleaved == 0 and nonincr == 0 and share <= MAX_CYCLE_ANOMALY_SHARE
    return _ok("5_cycles", passed, cycles=n, interleaved=interleaved, resets_not_increasing=nonincr,
               early_resets=early, outside_window=dur, rollover_first_above_previous_max=first_hi,
               first_reading_above_previous_max_any=first_hi_raw,
               anomaly_share=round(share, 5), anomaly_tolerance=MAX_CYCLE_ANOMALY_SHARE)


# 6 -------------------------------------------------------------------------
def gate_prices(turns: pd.DataFrame, prices: pd.DataFrame) -> dict:
    led = ledger_rate_lookup(prices)
    cat = prices[prices["source"].isin(["litellm", "models_dev"]) & (prices["part"] == "input")
                 & prices["tier_threshold"].isna()]
    cat_known = cat.groupby("model")["t_known"].min().to_dict()
    missing, lag_rows, lag_by_model = 0, 0, {}
    missing_by_model = {}
    for model, g in turns.groupby("model"):
        cm = canonical_model(model)
        t = g["t_event"].to_numpy(dtype=np.int64)
        periods = led.get(cm, [])
        cov = np.zeros(len(t), dtype=bool)
        for f, e in periods:
            cov |= (t >= f) & (t < e)
        miss = int((~cov).sum())
        if miss:
            missing += miss
            missing_by_model[model] = miss
        first = cat_known.get(cm)
        tk = g["t_known"].to_numpy(dtype=np.int64)
        late = int((tk < first).sum()) if first is not None else len(tk)
        if late:
            lag_rows += late
            lag_by_model[model] = late
    return _ok("6_prices", missing == 0, turns_without_ledger_rate=missing, missing_by_model=missing_by_model,
               turns_before_catalog_knew_rate=lag_rows, launch_lag_by_model=lag_by_model)


# 7 -------------------------------------------------------------------------
def _read_tier(root, tier: str, name: str, filt=None) -> pa.Table:
    """As a reader would: the table's directory (partitioned) or its single
    file, hive partitioning off (the key lives only in the path)."""
    path = root / tier / name
    if not path.exists():
        path = root / tier / f"{name}.parquet"
    if not path.exists():
        return TABLES[name].arrow_schema().empty_table()
    d = ds.dataset(str(path), format="parquet", partitioning=None)
    cols = [c for c, _ in TABLES[name].columns]
    return d.to_table(columns=cols, filter=filt)


def gate_point_in_time(root, tables: dict[str, pa.Table], t_train: int, t_end: int) -> dict:
    """At seeded random cutoffs, reading the written files with a pushed-down
    `t_known <= T` equals filtering the built table; train/ holds nothing
    after T_train and holdout/ nothing at or before it; no data row is known
    before it happened (prices excepted: a rate can be published ahead of its
    effective date)."""
    rng = np.random.default_rng(PIT_SEED)
    problems = []
    lo = min(int(pc.min(t["t_known"]).cast(pa.int64()).as_py()) for t in tables.values() if t.num_rows
             and pc.min(t["t_known"]).is_valid)
    cutoffs = np.sort(rng.integers(lo, t_end + 1, size=PIT_CUTOFFS))
    for name in DATA_TABLES:
        mem = tables[name]
        tk_mem = np.sort(mem["t_known"].cast(pa.int64()).to_numpy(zero_copy_only=False))
        train = _read_tier(root, "train", name)
        hold = _read_tier(root, "holdout", name)
        tr_tk = train["t_known"].cast(pa.int64()).to_numpy(zero_copy_only=False)
        ho_tk = hold["t_known"].cast(pa.int64()).to_numpy(zero_copy_only=False)
        if tr_tk.size and tr_tk.max() > t_train:
            problems.append(f"{name}: train row after T_train")
        if ho_tk.size and ho_tk.min() <= t_train:
            problems.append(f"{name}: holdout row at or before T_train")
        if train.num_rows + hold.num_rows != mem.num_rows:
            problems.append(f"{name}: written rows {train.num_rows + hold.num_rows} != built {mem.num_rows}")
        if name != "prices" and mem.num_rows:
            te = mem["t_event"].cast(pa.int64()).to_numpy(zero_copy_only=False)
            tk = mem["t_known"].cast(pa.int64()).to_numpy(zero_copy_only=False)
            if (tk < te).any():
                problems.append(f"{name}: {int((tk < te).sum())} rows known before they happened")
        if mem["t_known"].null_count:
            problems.append(f"{name}: null t_known")
        if name == "turns" and mem.num_rows:
            # The core dedups re-delivered rows by identity: one call_id per API call.
            if mem["call_id"].null_count or len(pc.unique(mem["call_id"])) != mem.num_rows:
                problems.append("turns: call_id not unique and non-null")
        written = np.sort(np.concatenate([tr_tk, ho_tk]))
        if not np.array_equal(written, tk_mem):
            problems.append(f"{name}: written t_known multiset differs from built")
        # Pushed-down filter vs in-memory filter, at every cutoff (big tables
        # at a sample of them: the multiset check above already covers all).
        cut_iter = cutoffs if mem.num_rows < 50_000 else cutoffs[:: max(1, PIT_CUTOFFS // 25)]
        for T in cut_iter:
            ts = pa.scalar(int(T), type=pa.int64()).cast(pa.timestamp("ms")).cast(pa.timestamp("ms", tz="UTC"))
            f = ds.field("t_known") <= ts
            tier = "train" if T <= t_train else None
            got = _read_tier(root, "train", name, f).num_rows
            if tier is None:
                got += _read_tier(root, "holdout", name, f).num_rows
            want = int(np.searchsorted(tk_mem, T, side="right"))
            if got != want:
                problems.append(f"{name}: at a cutoff, files give {got} rows, raw filter {want}")
                break
    for name in LABEL_TABLES:
        for tier in ("train", "holdout"):
            if (root / tier / name).exists() or (root / tier / f"{name}.parquet").exists():
                problems.append(f"label table {name} found in {tier}/")
    view_cutoffs = sorted({int(T) for T in cutoffs[:: max(1, len(cutoffs) // PIT_VIEW_CUTOFFS)]} | {int(t_train)})
    problems += core_view_problems(root, tables, view_cutoffs, t_end)
    return _ok("7_point_in_time", not problems, cutoffs=PIT_CUTOFFS, view_cutoffs=len(view_cutoffs),
               problems=problems[:50])


def core_view_problems(root, tables: dict[str, pa.Table], cutoffs: list[int], t_end: int) -> list[str]:
    """The written files as the harness serves them (`arena.snapshot.views`,
    the code every model's history comes from), at each cutoff, in both
    modes, with every account in view and no history start:

    - no served row is known after the cutoff;
    - no late value (`views.LATE_COLUMNS`) is served before its known time,
      and no current-only column (`views.ALWAYS_NULL`) is served at all;
    - in `current_code`, each table is exactly the built rows known by then;
    - streaming holds: the history at one cutoff extended with the events up
      to the next has the next cutoff's rows.
    """
    import polars as pl

    from arena.snapshot.views import (
        ALWAYS_NULL, LATE_COLUMNS, EventsView, HistoryView, SnapshotData, Tier, read_table,
    )
    from arena.types import Scope

    def epoch(df, col):
        return df[col].cast(pl.Datetime("ms", "UTC")).dt.epoch("ms")

    problems: list[str] = []
    roots = [root / "train", root / "holdout"]
    frames = {n: read_table(roots, n) for n in DATA_TABLES}
    lo = min((int(epoch(f, "t_known").min()) for f in frames.values() if f.height), default=0)
    data = SnapshotData(frames, snapshot_id="gate7", tier=Tier("gate7", lo, int(t_end)))
    accounts = data.accounts()
    if not accounts:
        return problems
    built = {n: np.sort(tables[n]["t_known"].cast(pa.int64()).to_numpy(zero_copy_only=False)) for n in DATA_TABLES}
    for mode in ("current_code", "as_recorded"):
        v = data.view(Scope(accounts, "all"), mode)
        for T in cutoffs:
            h = v.history(T)
            for name, df in h.items():
                if not df.height:
                    continue
                if int(epoch(df, "t_known").max()) > T:
                    problems.append(f"views/{mode}: {name} serves a row known after the cutoff")
                for col, kt in LATE_COLUMNS.get(name, {}).items():
                    if col not in df.columns or kt not in df.columns:
                        continue
                    k = epoch(df, kt)
                    early = df.filter(pl.col(col).is_not_null() & (k.is_null() | (k > T)))
                    if early.height:
                        problems.append(f"views/{mode}: {name}.{col} served {early.height} times before known")
                for col in ALWAYS_NULL.get(name, ()):
                    if col in df.columns and df[col].null_count() != df.height:
                        problems.append(f"views/{mode}: current-only {name}.{col} served")
                if mode == "current_code":
                    want = int(np.searchsorted(built[name], T, side="right"))
                    if df.height != want:
                        problems.append(f"views/{mode}: {name} serves {df.height} rows at a cutoff, built {want}")
        a, b = cutoffs[len(cutoffs) // 2 - 1: len(cutoffs) // 2 + 1] if len(cutoffs) > 1 else (cutoffs[0],) * 2
        hv = HistoryView(v.history(a), a, v.scope, mode).extend(EventsView(v.events(a, b), a, b))
        hb = v.history(b)
        for name in DATA_TABLES:
            x = np.sort(epoch(hv.table(name), "t_known").to_numpy()) if hv.table(name).height else np.zeros(0)
            y = np.sort(epoch(hb[name], "t_known").to_numpy()) if hb[name].height else np.zeros(0)
            if not np.array_equal(x, y):
                problems.append(f"views/{mode}: {name} history+events differs from history")
    return problems


# 8 -------------------------------------------------------------------------
def table_hash(t: pa.Table) -> str:
    """sha256 of the table's Arrow IPC stream: the content, independent of
    parquet encoding or file layout."""
    sink = pa.BufferOutputStream()
    with pa.ipc.new_stream(sink, t.schema) as w:
        w.write_table(t.combine_chunks() if t.num_rows else t)
    return hashlib.sha256(sink.getvalue().to_pybytes()).hexdigest()


def gate_determinism(h1: dict[str, str], h2: dict[str, str]) -> dict:
    diff = sorted(k for k in h1 if h1[k] != h2.get(k))
    return _ok("8_determinism", not diff and set(h1) == set(h2), tables=len(h1), differing=diff)


# 9 -------------------------------------------------------------------------
UUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")


def leak_terms(inp) -> tuple[list[str], list[str]]:
    """Raw account/org id prefixes and project names to look for. Returned
    to the gate only; never written."""
    prefixes = set()
    for col in ("account_id", "org_id"):
        for v in inp.accounts[col].dropna():
            if isinstance(v, str) and len(v) >= 8:
                prefixes.add(v[:8].lower())
    for v in inp.turns["account_id"].dropna().unique():
        if isinstance(v, str) and len(v) >= 8:
            prefixes.add(v[:8].lower())
    names = set()
    for col in ("project", "orig_project"):
        for p in inp.turns[col].dropna().unique():
            base = str(p).rstrip("/").rsplit("/", 1)[-1]
            if distinctive(base):
                names.add(base.lower())
    return sorted(prefixes), sorted(names)


def distinctive(name: str) -> bool:
    """A project name worth scanning for: one that would identify something.
    Single words of under 8 letters in any case ("history", "Models",
    "engine") and names without letters (a dated scratch dir) match the
    exporter's own vocabulary and app strings by accident and identify
    nothing, so they are skipped; identifier-shaped names (digits or
    separators mixed with letters) and long words are kept."""
    if len(name) < 5 or not re.search(r"[A-Za-z]", name):
        return False
    if re.fullmatch(r"[A-Za-z]+", name):
        return len(name) >= 8
    return True


def gate_leak_scan(tables: dict[str, pa.Table], prefixes: list[str], names: list[str]) -> dict:
    hits: dict[str, dict[str, int]] = {}
    for tname, t in tables.items():
        for field in t.schema:
            col = t[field.name]
            if pa.types.is_list(field.type):
                col = pc.list_flatten(col)
                vtype = field.type.value_type
            else:
                vtype = field.type
            if not pa.types.is_string(vtype):
                continue
            vals = [v for v in pc.unique(col).to_pylist() if v is not None]
            for v in vals:
                low = v.lower()
                kinds = []
                if "/users/" in low:
                    kinds.append("path")
                if "@" in v:
                    kinds.append("at_sign")
                if UUID_RE.search(v):
                    kinds.append("uuid")
                if any(p in low for p in prefixes):
                    kinds.append("account_prefix")
                if any(n in low for n in names):
                    kinds.append("project_name")
                for k in kinds:
                    key = f"{tname}.{field.name}"
                    hits.setdefault(key, {}).setdefault(k, 0)
                    hits[key][k] += 1
    return _ok("9_leak_scan", not hits, hits=hits, project_names_checked=len(names),
               account_prefixes_checked=len(prefixes))
