"""`turns` and `turn_revisions` (spec §2.1, §2.2).

One row per store TokenSample: the store is the system of record (it alone
reaches back past transcript pruning). Transcripts, where a line survives,
add what the store doesn't keep — subagent or not, finished or not, entry
point, API error — and re-fill geo/speed the store left null.
"""
from __future__ import annotations

from dataclasses import dataclass

import duckdb
import numpy as np
import pandas as pd

from . import clocks
from .util import (DEFECT_TINY_OUTPUT, OUTPUT_CLEAN_FROM, era_output_clean, in_suspect_defect,
                   in_verified_defect, model_family, version_num)
from arena.snapshot.schema import REVISED_ACCOUNT, REVISED_GEO_SPEED, REVISED_OUTPUT, REVISED_PROJECT

# Subagent types Claude Code ships. Anything else is a user-defined agent,
# exported only as "custom" — never by name.
BUILTIN_AGENTS = frozenset({
    "general-purpose", "Explore", "Plan", "claude-code-guide", "statusline-setup",
    "output-style-setup", "workflow-subagent", "web-fetch", "fork",
})
DESKTOP_ENTRYPOINTS = ("claude-desktop", "local-agent")

REVISION_BITS = {"ACCOUNTID": REVISED_ACCOUNT, "OUTPUTTOKENS": REVISED_OUTPUT,
                 "PROJECTPATH": REVISED_PROJECT, "INFERENCEGEO": REVISED_GEO_SPEED,
                 "SPEED": REVISED_GEO_SPEED}
STREAM_TURN_LAG = 1


def kept_copies(lines: pd.DataFrame) -> pd.DataFrame:
    """One transcript copy per `${messageId}:${requestId}`: the one
    `ParsedUsageEntry.isKept` picks (finished first, then larger output, then
    earliest, then file path by bytes), with the cache-write split mapped the
    way JSONLParser maps it (a lone summed figure is the 5m tier)."""
    con = duckdb.connect()
    try:
        con.register("lines", lines)
        return con.execute("""
        WITH r AS (
          SELECT *, message_id || ':' || request_id AS key,
                 CASE WHEN e5m = 0 AND e1h = 0 AND summed_cc > 0 THEN summed_cc ELSE e5m END AS cw5,
                 CASE WHEN e5m = 0 AND e1h = 0 AND summed_cc > 0 THEN 0 ELSE e1h END AS cw1,
                 row_number() OVER (PARTITION BY message_id || ':' || request_id
                                    ORDER BY finished DESC, output DESC, t ASC, fname ASC) AS rn,
                 count(*) OVER (PARTITION BY message_id || ':' || request_id) AS n_copies
          FROM lines
          WHERE model <> '<synthetic>' AND message_id IS NOT NULL AND request_id IS NOT NULL
        )
        SELECT key, t AS tx_t, model AS tx_model, session_id AS tx_session, cc_version AS tx_cc,
               finished, entrypoint, speed AS tx_speed, geo AS tx_geo,
               input AS tx_input, output AS tx_output, cache_read AS tx_cache_read,
               cw5 AS tx_cw5, cw1 AS tx_cw1, api_error, n_iter, fname, n_copies,
               contains(fname, '/subagents/') AS is_subagent
        FROM r WHERE rn = 1 ORDER BY key
        """).df()
    finally:
        con.close()


def agent_kind(kept: pd.DataFrame, metas: pd.DataFrame) -> pd.Series:
    m = metas.set_index("fname")
    kind = pd.Series([None] * len(kept), index=kept.index, dtype=object)
    sub = kept["is_subagent"].astype(bool)
    kind[~sub] = "main"
    info = kept.loc[sub, "fname"].map(lambda f: m.loc[f] if f in m.index else None)
    for i, row in info.items():
        if row is None or (isinstance(row, pd.DataFrame)):
            continue
        if bool(row["is_fork"]) or row["agent_type"] == "fork":
            kind[i] = "fork"
        elif row["agent_type"] in BUILTIN_AGENTS or row["is_builtin_flag"] is True:
            kind[i] = "builtin"
        elif row["agent_type"] is not None:
            kind[i] = "custom"
    return kind


@dataclass
class TurnsResult:
    turns: pd.DataFrame           # snapshot columns + helper columns (pk, raw ids, tx_*) for validation
    revisions: pd.DataFrame
    lag: clocks.LagModel
    stats: dict


def _activation_lookup(t: np.ndarray, acts: pd.DataFrame, now_ms: int):
    """For each time, the covering activation by (credential > observed >
    manual, then latest start). Returns (account_id, source) arrays."""
    prio = {"credential": 3, "observed": 2, "manual": 1}
    best_p = np.zeros(len(t), dtype=np.int64)
    best_s = np.full(len(t), np.iinfo(np.int64).min, dtype=np.int64)
    acct = np.array([None] * len(t), dtype=object)
    src = np.array([None] * len(t), dtype=object)
    for r in acts.itertuples(index=False):
        start = -(1 << 62) if pd.isna(r.started) else int(r.started)
        end = (1 << 62) if pd.isna(r.ended) else int(r.ended)
        p = prio.get(r.source, 0)
        m = (t >= start) & (t < end)
        better = m & ((p > best_p) | ((p == best_p) & (start > best_s)))
        best_p[better], best_s[better] = p, start
        acct[better], src[better] = r.account_id, r.source
    return acct, src


def _observed_replay(t: np.ndarray, acts: pd.DataFrame, fallback: np.ndarray) -> np.ndarray:
    """The account a replay of observed activations alone gives at t: the
    latest observed switch at or before t; before the first one, `fallback`."""
    obs = acts[(acts["source"] == "observed") & acts["started"].notna()].sort_values(["started", "pk"])
    out = fallback.copy()
    if obs.empty:
        return out
    starts = obs["started"].to_numpy(dtype=np.int64)
    ids = obs["account_id"].to_numpy(dtype=object)
    i = np.searchsorted(starts, t, side="right") - 1
    ok = i >= 0
    out[ok] = ids[i[ok]]
    return out


def build_turns(inp, hasher, labels: dict[str, str], alive: clocks.Alive, now_ms: int,
                cost_state_last: pd.DataFrame) -> TurnsResult:
    st = inp.turns.copy()
    st["t"] = st["t"].astype("int64")
    n = len(st)
    stats: dict = {"rows": n}

    # --- transcripts -------------------------------------------------------
    kept = kept_copies(inp.lines)
    kept["agent_kind"] = agent_kind(kept, inp.metas)
    df = st.merge(kept, how="left", left_on="dedup_key", right_on="key")
    assert len(df) == n, "dedup keys must be unique in the store"
    has_tx = df["key"].notna().to_numpy()
    stats["with_transcript"] = int(has_tx.sum())

    # --- ids and plain columns ---------------------------------------------
    keys = df["dedup_key"].astype(object).to_numpy()
    nokey = [f"{s}|{t}|{m}|{a}|{b}|{c}|{d}|{e}" for s, t, m, a, b, c, d, e in zip(
        df["session_id"].astype(object), df["t"], df["model"].astype(object), df["input"], df["output"],
        df["cache_read"], df["cache_write_5m"], df["cache_write_1h"])]
    df["call_id"] = np.fromiter(
        (hasher.h("call", k) if isinstance(k, str) else hasher.h("call-nokey", nk) for k, nk in zip(keys, nokey)),
        dtype=np.uint64, count=n)
    stats["no_dedup_key"] = int(sum(1 for k in keys if not isinstance(k, str)))
    df["session_h"] = pd.array([hasher.h("session", s) if isinstance(s, str) else None
                                for s in df["session_id"].astype(object)], dtype="UInt64")
    df["project_h"] = pd.array([hasher.h("project", s) if isinstance(s, str) else None
                                for s in df["project"].astype(object)], dtype="UInt64")
    df["subdir_depth"] = [_subdir_depth(o, p) for o, p in zip(df["orig_project"].astype(object), df["project"].astype(object))]
    df["model_family"] = [model_family(m) for m in df["model"].astype(object)]
    df["cc_version_num"] = [version_num(v) for v in df["cc_version"].astype(object)]
    utc_hour = (df["t"] // 3_600_000) % 24
    off = (df["local_hour"].astype("Int64") - utc_hour) % 24
    off = off.where(off <= 14, off - 24)
    df["tz_offset_min"] = (off * 60).astype("Int64")

    # geo/speed: re-filled from the surviving line; null stays unknown.
    df["inference_geo"] = df["tx_geo"].where(df["tx_geo"].notna(), df["geo"])
    df["speed"] = df["tx_speed"].where(df["tx_speed"].notna(), df["speed"])
    df["is_subagent"] = df["is_subagent"].where(pd.Series(has_tx), None)
    df["finished"] = df["finished"].where(pd.Series(has_tx), None)
    df["api_error"] = df["api_error"].where(pd.Series(has_tx), None)

    # --- persistent history -----------------------------------------------
    ch = inp.ts_changes
    ins = ch[ch["ct"] == 0].groupby("pk")["t"].min()
    upd = ch[ch["ct"] == 1]
    out_up = upd[upd["changed"].map(lambda a: "OUTPUTTOKENS" in a)]
    df["t_ins"] = df["pk"].map(ins).astype("Int64")

    t_ev = df["t"].to_numpy(dtype=np.int64)
    alive_at = alive.adjust(t_ev)
    t_ins = df["t_ins"].to_numpy(dtype="float64")
    hist = ~np.isnan(t_ins)
    backfill = hist & (t_ins > alive_at + clocks.BACKFILL_SLACK_MS)
    # A streamed upgrade lands seconds to minutes after the insert; one long
    # after it is a re-read under a code fix and doesn't move availability.
    up = out_up.merge(df[["pk", "t_ins"]], on="pk")
    up = up[up["t"] <= up["t_ins"].astype("float64") + clocks.BACKFILL_SLACK_MS]
    last_up = up.groupby("pk")["t"].max()
    t_up = df["pk"].map(last_up).to_numpy(dtype="float64")
    t_final = np.where(np.isnan(t_up), t_ins, np.fmax(t_ins, t_up))
    stats["history_rows"] = int(hist.sum())
    stats["backfill_rows"] = int(backfill.sum())
    stats["late_upgrades_ignored"] = int(len(out_up) - len(up))

    # Lag model: history rows, Pacer alive when the turn happened, not backfills.
    hs = inp.history_start_ms
    fit_mask = hist & ~backfill & alive.is_alive(t_ev)
    if hs is not None:
        fit_mask &= t_ev >= hs
    lag = clocks.LagModel.fit("turn_ingest", (t_final - t_ev)[fit_mask])

    call_ids = df["call_id"].to_numpy(dtype=np.uint64)
    modeled = clocks.modeled_t_known(t_ev, call_ids, lag, alive, STREAM_TURN_LAG)
    use_hist = hist & ~backfill
    t_known = np.where(use_hist, np.nan_to_num(t_final, nan=0).astype(np.int64), modeled)
    df["t_known"] = np.maximum(t_known, t_ev)
    df["t_known_src"] = np.where(use_hist, "history", "modeled")
    df["t_first_recorded"] = pd.array(np.where(hist, np.nan_to_num(t_ins, nan=0), 0).astype(np.int64), dtype="Int64")
    df.loc[~hist, "t_first_recorded"] = pd.NA
    df["t_final_recorded"] = pd.array(np.nan_to_num(t_final, nan=0).astype(np.int64), dtype="Int64")
    df.loc[~hist, "t_final_recorded"] = pd.NA
    df["t_event"] = t_ev

    # revised_mask: only revisions already recorded when the row became known.
    # A later rewrite (a geo/speed patch, an account restamp) is a final value
    # known later than the row; its time is in turn_revisions, which the
    # harness serves as of now. Counting it here would leak it.
    mask_bits = upd.assign(bits=upd["changed"].map(lambda a: int(np.bitwise_or.reduce([REVISION_BITS.get(x, 0) for x in a] or [0]))))
    mask_bits = mask_bits.merge(df[["pk", "t_known"]], on="pk")
    mask_bits = mask_bits[mask_bits["t"] <= mask_bits["t_known"]]
    rev_mask = mask_bits.groupby("pk")["bits"].agg(lambda b: int(np.bitwise_or.reduce(b.to_numpy())))
    df["revised_mask"] = df["pk"].map(rev_mask).fillna(0).astype("int64")
    all_bits = upd.assign(bits=upd["changed"].map(lambda a: int(np.bitwise_or.reduce([REVISION_BITS.get(x, 0) for x in a] or [0]))))
    restamp_any = all_bits.groupby("pk")["bits"].agg(lambda b: int(np.bitwise_or.reduce(b.to_numpy())))
    df["revised_mask_final"] = df["pk"].map(restamp_any).fillna(0).astype("int64")

    # --- accounts ----------------------------------------------------------
    acts = inp.activations
    act_acct, act_src = _activation_lookup(t_ev, acts, now_ms)
    store_acct = df["account_id"].astype(object).to_numpy()
    restamped = (df["revised_mask_final"].to_numpy() & REVISED_ACCOUNT) > 0
    desktop = df["entrypoint"].isin(DESKTOP_ENTRYPOINTS).to_numpy()
    differs = np.array([a is not None and b is not None and a != b for a, b in zip(store_acct, act_acct)])
    src_map = {"manual": "manual_range", "observed": "observed", "credential": "credential"}
    attr = np.array([src_map.get(s) for s in act_src], dtype=object)
    reassigned = differs | restamped
    attr[reassigned & desktop] = "desktop_restamp"
    attr[reassigned & ~desktop] = "retro_reassign"
    df["attribution_src"] = attr
    manual_acct = _activation_lookup(t_ev, acts[acts["source"] == "manual"], now_ms)[0]
    obs = _observed_replay(t_ev, acts, manual_acct)
    df["account"] = [labels.get(a) if isinstance(a, str) else None for a in store_acct]
    df["account_as_observed"] = [labels.get(a) if isinstance(a, str) else None for a in obs]
    stats["attribution_src"] = pd.Series(attr).value_counts(dropna=False).to_dict()

    # --- output regime -----------------------------------------------------
    vn = df["cc_version_num"].to_numpy()
    tx_vn = pd.array([version_num(v) for v in df["tx_cc"].astype(object)], dtype="Int64")
    vn_eff = pd.array(vn, dtype="Int64").fillna(tx_vn) if len(df) else pd.array([], dtype="Int64")
    verified = in_verified_defect(vn_eff)
    suspect = in_suspect_defect(vn_eff)
    fin = df["finished"].fillna(False).astype(bool).to_numpy()
    sub = df["is_subagent"].fillna(False).astype(bool).to_numpy()
    out_tok = df["output"].to_numpy(dtype=np.int64)
    regime = np.full(n, "unknown", dtype=object)
    regime[has_tx & fin] = "finished"
    unf = has_tx & ~fin
    regime[unf] = "unfinished_interrupted"
    regime[unf & sub & suspect] = "subagent_defect_suspect"
    regime[unf & sub & verified] = "subagent_defect"
    no_tx = ~has_tx
    regime[no_tx & (t_ev < OUTPUT_CLEAN_FROM)] = "first_copy"
    regime[no_tx & (t_ev >= OUTPUT_CLEAN_FROM) & (suspect | verified) & (out_tok <= DEFECT_TINY_OUTPUT)] = "subagent_defect_suspect"
    reliable = np.where(has_tx, regime == "finished", (regime == "unknown") & era_output_clean(t_ev))
    df["output_regime"] = regime
    df["output_reliable"] = reliable
    stats["output_regime"] = pd.Series(regime).value_counts().to_dict()

    # --- imputation --------------------------------------------------------
    imp = impute_output(df, cost_state_last)
    df["output_imputed"] = imp["output_imputed"]
    df["output_imputed_src"] = imp["output_imputed_src"]
    df["output_imputed_t_known"] = imp["output_imputed_t_known"]
    stats["imputed"] = pd.Series(imp["output_imputed_src"]).value_counts().to_dict()

    df = df.sort_values(["t_known", "t_event", "call_id"], kind="stable").reset_index(drop=True)

    # --- revisions ---------------------------------------------------------
    pk_call = df.set_index("pk")["call_id"]
    rv = ch[ch["pk"].isin(pk_call.index)].copy()
    kinds = []
    for ct, changed in zip(rv["ct"], rv["changed"]):
        if ct == 0:
            kinds.append(("insert",))
        else:
            ks = []
            for a in changed:
                k = {"ACCOUNTID": "account_restamp", "OUTPUTTOKENS": "output_upgrade",
                     "PROJECTPATH": "project_rewrite", "INFERENCEGEO": "geo_speed_patch",
                     "SPEED": "geo_speed_patch"}.get(a)
                if k and k not in ks:
                    ks.append(k)
            kinds.append(tuple(ks))
    rv["kind"] = kinds
    rv = rv.explode("kind").dropna(subset=["kind"])
    rv["call_id"] = rv["pk"].map(pk_call).astype(np.uint64)
    rv["t_event"] = rv["t"].astype("int64")
    rv["t_known"] = rv["t_event"]
    rv["t_known_src"] = "history"
    rv = rv.sort_values(["t_known", "call_id", "kind"], kind="stable").reset_index(drop=True)
    stats["revisions"] = rv["kind"].value_counts().to_dict()
    return TurnsResult(df, rv[["t_event", "t_known", "t_known_src", "call_id", "kind"]], lag, stats)


def _subdir_depth(orig, canon) -> int | None:
    """Depth of the original cwd below the canonical project path: 0 when
    equal, -1 when the original is not under it (an alias), never the path."""
    if not isinstance(orig, str) or not isinstance(canon, str):
        return None
    o, c = orig.rstrip("/"), canon.rstrip("/")
    if o == c:
        return 0
    if o.startswith(c + "/"):
        return len([p for p in o[len(c) + 1:].split("/") if p])
    return -1


def impute_output(df: pd.DataFrame, cs: pd.DataFrame) -> dict:
    """Imputed output for defect rows only; `output` is never overwritten.

    Per (session, model), Claude Code's own `cost-state` counter is compared
    with the transcript totals of the same session:
    - `cost_state`: cache reads agree within ±5%, so both cover the same
      calls; the counter's output surplus is spread evenly over that
      session's defect calls of that model.
    - `cost_state_scaled`: cache reads agree within a factor of two. The
      defect versions also lose whole calls (the counter reads ~26% more
      cache in defect sessions, against ±0% elsewhere), so the counter's
      output is first scaled to the calls the transcript holds (by the
      cache-read ratio), and only that surplus is spread. Without the
      scaling the output of calls absent from the store would be charged to
      the calls present.
    - otherwise the median surplus per defect call over the sessions whose
      evidence was known by the row's own t_known: same model, else family,
      else any (`model_median`, `family_median`, `global_median`).
    An imputation is known only once its evidence is: `output_imputed_t_known`
    is the later of the row's t_known and the evidence's.
    """
    n = len(df)
    out_val = np.full(n, np.nan)
    out_src = np.array([None] * n, dtype=object)
    out_tk = np.full(n, -1, dtype=np.int64)
    defect = df["output_regime"].isin(["subagent_defect", "subagent_defect_suspect"]).to_numpy()
    rec = reconcile_sessions(df, cs)
    if defect.any():
        sess = df["session_id"].astype(object).to_numpy()
        model = df["model"].astype(object).to_numpy()
        tk = df["t_known"].to_numpy(dtype=np.int64)
        output = df["output"].to_numpy(dtype=np.float64)
        usable = rec[rec["imp_src"].notna() & (rec["imp_gap"] > 0) & (rec["n_defect"] > 0)]
        share = {(r.session_id, r.model): (r.imp_gap / r.n_defect, int(r.cs_t), r.imp_src) for r in usable.itertuples()}
        for i in np.flatnonzero(defect):
            got = share.get((sess[i], model[i]))
            if got is not None:
                out_val[i] = output[i] + got[0]
                out_src[i] = got[2]
                out_tk[i] = max(tk[i], got[1])
        # Fallback: medians as of the evidence known by each row.
        ev = rec[rec["imp_src"].notna() & (rec["n_defect"] > 0) & (rec["imp_gap"] >= 0)].copy()
        if not ev.empty:
            ev["per_call"] = ev["imp_gap"] / ev["n_defect"]
            ev["family"] = [model_family(m) for m in ev["model"]]
            ev = ev.sort_values(["cs_t", "session_id", "model"], kind="stable")
            series = {}
            for level, key in (("model_median", "model"), ("family_median", "family"), ("global_median", None)):
                groups = ev.groupby(key, sort=True) if key else [(None, ev)]
                for g, sub in groups:
                    vals = sub["per_call"].to_numpy()
                    times = sub["cs_t"].to_numpy(dtype=np.int64)
                    meds = np.array([np.median(vals[: j + 1]) for j in range(len(vals))])
                    series[(level, g)] = (times, meds)
            fam = np.array([model_family(m) for m in model], dtype=object)
            for i in np.flatnonzero(defect & (out_src == None)):  # noqa: E711
                for level, g in (("model_median", model[i]), ("family_median", fam[i]), ("global_median", None)):
                    s = series.get((level, g))
                    if s is None:
                        continue
                    times, meds = s
                    j = np.searchsorted(times, tk[i], side="right") - 1
                    if j < 0:
                        j = 0
                    out_val[i] = output[i] + meds[j]
                    out_src[i] = level
                    out_tk[i] = max(tk[i], int(times[j]))
                    break
    tk_arr = pd.array(np.where(out_tk >= 0, out_tk, 0), dtype="Int64")
    tk_arr[out_tk < 0] = pd.NA
    return {"output_imputed": out_val, "output_imputed_src": out_src, "output_imputed_t_known": tk_arr,
            "reconcile": rec}


def reconcile_sessions(df: pd.DataFrame, cs: pd.DataFrame) -> pd.DataFrame:
    """Per (session, model): Claude Code's last cost-state against the
    transcript totals of the same session (main and subagent lines alike —
    subagent lines carry their parent's sessionId). `valid` when cache reads
    agree within ±5%, i.e. both cover the same calls."""
    cols = ["session_id", "model", "cs_t", "cs_output", "cs_cache_read", "tx_output", "tx_cache_read",
            "n_defect", "n_tx", "all_reliable", "gap", "ratio", "cr_ratio", "valid", "imp_src", "imp_gap"]
    if cs.empty:
        return pd.DataFrame(columns=cols).astype({"valid": bool, "gap": float, "n_defect": int, "imp_gap": float})
    tx = df[df["key"].notna()]
    agg = tx.groupby(["session_id", "model"]).agg(
        tx_output=("tx_output", "sum"), tx_cache_read=("tx_cache_read", "sum"), n_tx=("key", "size"),
        n_defect=("output_regime", lambda r: int(r.isin(["subagent_defect", "subagent_defect_suspect"]).sum())),
        all_reliable=("output_reliable", "all")).reset_index()
    c = cs.rename(columns={"t": "cs_t", "output": "cs_output", "cache_read": "cs_cache_read"})
    r = c[["session_id", "model", "cs_t", "cs_output", "cs_cache_read"]].merge(agg, on=["session_id", "model"], how="inner")
    r["gap"] = r["cs_output"].astype("float64") - r["tx_output"].astype("float64")
    r["ratio"] = r["cs_output"].astype("float64") / r["tx_output"].replace(0, np.nan).astype("float64")
    r["cr_ratio"] = r["cs_cache_read"].astype("float64") / r["tx_cache_read"].replace(0, np.nan).astype("float64")
    r["valid"] = (r["cr_ratio"] - 1).abs() <= 0.05
    r["valid"] = r["valid"].fillna(False).astype(bool)
    scaled_ok = (r["cr_ratio"] >= 0.5) & (r["cr_ratio"] <= 2.0) & ~r["valid"]
    r["imp_src"] = np.where(r["valid"], "cost_state", np.where(scaled_ok.fillna(False), "cost_state_scaled", None))
    r["imp_gap"] = np.where(r["valid"], r["gap"],
                            r["cs_output"].astype("float64") / r["cr_ratio"] - r["tx_output"].astype("float64"))
    r.loc[r["imp_src"].isna(), "imp_gap"] = np.nan
    return r[cols].sort_values(["session_id", "model"]).reset_index(drop=True)
