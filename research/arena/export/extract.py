"""Stage 2: read the copies and the transcripts into plain frames.

Everything here is numbers, ids, enums and times (epoch ms, int64). No
message content, prompt text, tool input or log text is read into a frame:
transcript lines are reduced in DuckDB to a fixed list of scalar fields, and
`history.jsonl`'s `display` / `pastedContents` are dropped as each line is
parsed. Raw ids and paths are still raw here; `build` hashes them.

The output, `Inputs`, is what the determinism gate rebuilds from: every frame
is sorted by a total key before it leaves this module.
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd

from . import achange
from .sources import open_store

CD_EPOCH = 978307200.0


def _ms(col: str) -> str:
    return f"CAST(ROUND(({col} + {CD_EPOCH}) * 1000) AS INTEGER)"


def _read(conn: sqlite3.Connection, sql: str, params=()) -> pd.DataFrame:
    return pd.read_sql_query(sql, conn, params=params, dtype_backend="numpy_nullable")


def _cols(conn: sqlite3.Connection, table: str) -> list[str]:
    return [r[1] for r in conn.execute(f"PRAGMA table_info({table})")]


def _has(conn: sqlite3.Connection, table: str) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone() is not None


@dataclass
class Inputs:
    """Every frame the build reads. Sorted, raw ids still raw."""

    # store
    turns: pd.DataFrame
    rl: pd.DataFrame              # RateLimitSample (live)
    ul: pd.DataFrame              # UsageLimitSample (live)
    archive: pd.DataFrame         # AccountUsageArchive
    activations: pd.DataFrame
    accounts: pd.DataFrame
    predictions: pd.DataFrame
    evals: pd.DataFrame
    fits: pd.DataFrame
    price_records: pd.DataFrame
    meta: dict
    ts_order: list[str]           # TokenSample attribute order (ACHANGE bitmap)
    ts_changes: pd.DataFrame      # TokenSample inserts/updates: pk, ct, cols(list), t
    reading_inserts: pd.DataFrame  # entity, pk, t (RateLimitSample / UsageLimitSample inserts)
    record_inserts: pd.DataFrame   # entity, pk, ct, t (predictions, evals, fits, activations)
    history_start_ms: int | None
    alias_map: dict               # raw path -> canonical path (store aliases)
    # archive (DuckDB copy)
    duck_archive: dict | None     # aggregate sums for gate 2
    # transcripts
    lines: pd.DataFrame           # assistant lines (numbers/ids only)
    user_lines: pd.DataFrame      # main-transcript user lines (origin fields only)
    cost_state: pd.DataFrame      # cost-state per (file, model), last line per file
    metas: pd.DataFrame           # subagent meta.json fields
    history: pd.DataFrame         # history.jsonl: t, project, session
    cswap_switches: pd.DataFrame  # t, from_slot, to_slot
    rotate_ticks: pd.DataFrame    # t, slot
    price_candidate: dict | None
    price_curated: dict | None
    desktop_ids: set = field(default_factory=set)
    transcript_files: int = 0
    extra: dict = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Store
# ---------------------------------------------------------------------------

def read_store(store_copy: Path) -> dict:
    conn = open_store(store_copy)
    try:
        return _read_store(conn)
    finally:
        conn.close()


def _read_store(conn: sqlite3.Connection) -> dict:
    out: dict = {}
    out["turns"] = _read(conn, f"""
        SELECT Z_PK pk, {_ms('ZSAMPLEDAT')} t, ZMODEL model,
               ZINPUTTOKENS input, ZOUTPUTTOKENS output, ZCACHEREADTOKENS cache_read,
               ZCACHECREATION5MTOKENS cache_write_5m, ZCACHECREATION1HTOKENS cache_write_1h,
               ZDEDUPKEY dedup_key, ZSESSIONID session_id, ZPROJECTPATH project,
               ZORIGINALPROJECTPATH orig_project, ZCCVERSION cc_version, ZLOCALHOUR local_hour,
               ZDATE local_date, ZACCOUNTID account_id, ZINFERENCEGEO geo, ZSPEED speed,
               ZSOURCECOSTUSD source_cost
        FROM ZTOKENSAMPLE ORDER BY Z_PK""")
    out["rl"] = _read(conn, f"""
        SELECT Z_PK pk, {_ms('ZSAMPLEDAT')} t, ZWINDOW window, ZUSEDPERCENTAGE util,
               {_ms('ZRESETSAT')} resets_at, ZSOURCE source, ZACCOUNTID account_id
        FROM ZRATELIMITSAMPLE ORDER BY Z_PK""")
    out["ul"] = _read(conn, f"""
        SELECT Z_PK pk, {_ms('ZSAMPLEDAT')} t, ZIDENTITY identity, ZKIND kind, ZGROUP grp,
               ZMODELDISPLAYNAME model_display, ZMODELID model_id, ZPERCENT util,
               {_ms('ZRESETSAT')} resets_at, ZSEVERITY severity, ZISACTIVE is_active,
               ZSOURCE source, ZACCOUNTID account_id
        FROM ZUSAGELIMITSAMPLE ORDER BY Z_PK""") if _has(conn, "ZUSAGELIMITSAMPLE") else pd.DataFrame()
    out["archive"] = _read(conn, f"""
        SELECT Z_PK pk, ZKIND kind, {_ms('ZSAMPLEDAT')} t, ZWINDOW window, ZIDENTITY identity,
               ZLIMITKIND limit_kind, ZGROUP grp, ZMODELDISPLAYNAME model_display, ZMODELID model_id,
               ZUSEDPERCENTAGE util, {_ms('ZRESETSAT')} resets_at, ZSEVERITY severity,
               ZISACTIVE is_active, ZSOURCE source, ZACCOUNTID account_id
        FROM ZACCOUNTUSAGEARCHIVE ORDER BY Z_PK""") if _has(conn, "ZACCOUNTUSAGEARCHIVE") else pd.DataFrame()
    out["activations"] = _read(conn, f"""
        SELECT Z_PK pk, {_ms('ZSTARTEDAT')} started, {_ms('ZENDEDAT')} ended, ZACCOUNTID account_id,
               ZEVIDENCE evidence, ZSOURCE source, ZROOTPATH root
        FROM ZACCOUNTACTIVATION ORDER BY Z_PK""")
    out["accounts"] = _read(conn, f"""
        SELECT Z_PK pk, ZID account_id, {_ms('ZFIRSTSEENAT')} first_seen,
               ZSUBSCRIPTIONTYPE plan, ZRATELIMITTIER tier, ZSWITCHERSLOT slot,
               ZORGANIZATIONID org_id
        FROM ZACCOUNT ORDER BY Z_PK""")
    out["predictions"] = _read(conn, f"""
        SELECT Z_PK pk, {_ms('ZRECORDEDAT')} recorded_at, ZSURFACE surface, ZMETHOD method,
               ZPERIODKEY period_key, {_ms('ZPERIODEND')} period_end, ZVALUE value, ZUSEDPCT used_pct,
               ZLO50 lo50, ZHI50 hi50, ZLO80 lo80, ZHI80 hi80, {_ms('ZCROSSINGAT')} crossing_at,
               {_ms('ZCROSSINGEARLIEST')} crossing_earliest, {_ms('ZCROSSINGLATEST')} crossing_latest,
               ZSLOPEPERCENTPERHOUR slope_pct_per_hour, ZSPENDSOFAR spend_so_far,
               ZRESIDUALCOUNT residual_count, ZSUPPORT support, ZANCHORSHIFT anchor_shift,
               ZBANDSTRATUM band_stratum, ZCONFIDENCE confidence, ZENGINEVERSION engine_version,
               ZPARAMSVERSION params_version, ZNOTE note, ZHITCLAIMED hit_claimed,
               ZREPLACEDMETHOD replaced_method, ZPRICINGVERSION pricing_version
        FROM ZPREDICTIONSNAPSHOT ORDER BY Z_PK""") if _has(conn, "ZPREDICTIONSNAPSHOT") else pd.DataFrame()
    out["evals"] = _read(conn, f"""
        SELECT Z_PK pk, {_ms('ZRECORDEDAT')} recorded_at, ZSURFACE surface, ZMETHOD method,
               ZKEY key, ZBUCKET bucket, ZPERIODKEY period_key, ZPREDICTED predicted,
               ZTRUTH truth, ZABSPCTERROR abs_pct_error
        FROM ZENGINEEVALOUTCOME ORDER BY Z_PK""") if _has(conn, "ZENGINEEVALOUTCOME") else pd.DataFrame()
    out["fits"] = _read(conn, f"""
        SELECT Z_PK pk, {_ms('ZFITTEDAT')} fitted_at, ZFITTEDDAY fitted_day, ZACCOUNTID account_id,
               ZWINDOW window, ZMETHOD method, ZMODELRATESJSON rates_json, ZR2 r2, ZPOOLEDR2 pooled_r2,
               ZPOOLEDRATE pooled_rate, ZRMSE rmse, ZINTERCEPTPERHOUR intercept_per_hour,
               ZINTERCEPTSHARE intercept_share, ZNOSPENDRISESHARE no_spend_rise_share,
               ZTOTALRISE total_rise, ZTOTALSPENDUSD total_spend_usd, ZUNFITTEDSPENDUSD unfitted_spend_usd,
               ZACTIVEHOURS active_hours, ZHOURS hours, {_ms('ZSPANSTART')} span_start,
               {_ms('ZSPANEND')} span_end
        FROM ZSPENDMETERFIT ORDER BY Z_PK""") if _has(conn, "ZSPENDMETERFIT") else pd.DataFrame()
    out["price_records"] = _read(conn, f"""
        SELECT Z_PK pk, ZMODEL model, ZPROVIDER provider, ZREGION region, ZSPEED speed, ZSOURCE source,
               ZCURATED curated, ZTIERABOVEPROMPTTOKENS tier, ZINPUTPERTOKEN input,
               ZOUTPUTPERTOKEN output, ZCACHEREADPERTOKEN cache_read,
               ZCACHEWRITE5MPERTOKEN cache_write_5m, ZCACHEWRITE1HPERTOKEN cache_write_1h,
               ZFASTMULTIPLIER fast_mult, ZREGIONALMULTIPLIER regional_mult,
               {_ms('ZEFFECTIVEFROM')} eff_from, {_ms('ZEFFECTIVETO')} eff_to,
               {_ms('ZRECORDEDAT')} recorded_at, {_ms('ZREVIEWEDAT')} reviewed_at
        FROM ZPRICERECORD ORDER BY Z_PK""") if _has(conn, "ZPRICERECORD") else pd.DataFrame()
    meta = {}
    if _has(conn, "ZCLAUDECODEMETA"):
        for k, v in conn.execute("SELECT ZKEY, ZVALUE FROM ZCLAUDECODEMETA"):
            if k in ("scan_version", "cost_recompute_version", "account_backfill_version",
                     "duplicate_repair_version", "path_canonicalization_version"):
                meta[k] = v
    out["meta"] = meta
    alias = {}
    if _has(conn, "ZPROJECTPATHALIAS"):
        for src, canon in conn.execute("SELECT ZSOURCEPATH, ZCANONICALPATH FROM ZPROJECTPATHALIAS"):
            if src and canon:
                alias[src] = canon
    out["alias_map"] = alias

    # Persistent history.
    ents = {}
    if _has(conn, "Z_PRIMARYKEY"):
        ents = {n: e for e, n in conn.execute("SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY")}
    out["ts_order"] = achange.attribute_order(_cols(conn, "ZTOKENSAMPLE"))
    achange.check_tokensample_order(out["ts_order"])
    empty_changes = pd.DataFrame({"pk": pd.Series([], dtype="int64"), "ct": pd.Series([], dtype="int64"),
                                  "t": pd.Series([], dtype="int64")})
    if _has(conn, "ACHANGE") and _has(conn, "ATRANSACTION") and "TokenSample" in ents:
        hs = conn.execute("SELECT MIN(ZTIMESTAMP) FROM ATRANSACTION").fetchone()[0]
        out["history_start_ms"] = None if hs is None else int(round((hs + CD_EPOCH) * 1000))
        ts_ent = ents["TokenSample"]
        rows = conn.execute(f"""
            SELECT a.ZENTITYPK, a.ZCHANGETYPE, a.ZCOLUMNS, {_ms('t.ZTIMESTAMP')}
            FROM ACHANGE a JOIN ATRANSACTION t ON t.Z_PK = a.ZTRANSACTIONID
            WHERE a.ZENTITY = ? AND a.ZCHANGETYPE IN (0, 1)
            ORDER BY a.Z_PK""", (ts_ent,)).fetchall()
        order = out["ts_order"]
        out["ts_changes"] = pd.DataFrame({
            "pk": np.array([r[0] for r in rows], dtype=np.int64),
            "ct": np.array([r[1] for r in rows], dtype=np.int64),
            "changed": [tuple(achange.changed_attributes(r[2], order)) if r[1] == achange.UPDATE else ()
                      for r in rows],
            "t": np.array([r[3] for r in rows], dtype=np.int64),
        })
        want = {e: n for n, e in ents.items() if n in ("RateLimitSample", "UsageLimitSample")}
        rec = {e: n for n, e in ents.items() if n in ("PredictionSnapshot", "EngineEvalOutcome",
                                                     "SpendMeterFit", "AccountActivation")}
        q = lambda ids, types: _read(conn, f"""
            SELECT a.ZENTITY ent, a.ZENTITYPK pk, a.ZCHANGETYPE ct, {_ms('t.ZTIMESTAMP')} t
            FROM ACHANGE a JOIN ATRANSACTION t ON t.Z_PK = a.ZTRANSACTIONID
            WHERE a.ZENTITY IN ({','.join(str(i) for i in ids) or 'NULL'})
              AND a.ZCHANGETYPE IN ({','.join(str(x) for x in types)})
            ORDER BY a.Z_PK""")
        ri = q(list(want), [achange.INSERT])
        ri["entity"] = ri["ent"].map(want)
        out["reading_inserts"] = ri.drop(columns=["ent"])
        rc = q(list(rec), [achange.INSERT, achange.UPDATE])
        rc["entity"] = rc["ent"].map(rec)
        out["record_inserts"] = rc.drop(columns=["ent"])
    else:
        out["history_start_ms"] = None
        out["ts_changes"] = empty_changes.assign(changed=[])
        out["reading_inserts"] = pd.DataFrame({"pk": [], "ct": [], "t": [], "entity": []})
        out["record_inserts"] = pd.DataFrame({"pk": [], "ct": [], "t": [], "entity": []})
    return out


def read_duck_archive(archive_copy: Path | None) -> dict | None:
    """Row count and sums of the DuckDB raw archive (gate 2). The copy is
    opened read-write so DuckDB can replay its WAL; it is a private clone."""
    if archive_copy is None:
        return None
    con = duckdb.connect(str(archive_copy))
    try:
        tables = {r[0] for r in con.execute("SELECT table_name FROM information_schema.tables").fetchall()}
        if "turn" not in tables:
            return None
        cols = {r[0] for r in con.execute("SELECT column_name FROM information_schema.columns WHERE table_name='turn'").fetchall()}
        df = con.execute(f"""
            SELECT epoch_ms(sampled_at) AS t, dedup_key,
                   input_tokens, output_tokens, cache_read, cache_creation_5m, cache_creation_1h
                   {', source_cost' if 'source_cost' in cols else ''}
            FROM turn""").df()
        return {"frame": df}
    finally:
        con.close()


# ---------------------------------------------------------------------------
# Transcripts
# ---------------------------------------------------------------------------

def _duck() -> duckdb.DuckDBPyConnection:
    con = duckdb.connect()
    con.execute("SET threads=4; SET preserve_insertion_order=false;")
    return con


def _file_list_sql(files: list[Path]) -> str:
    return "[" + ", ".join("'" + str(f).replace("'", "''") + "'" for f in files) + "]"


def extract_transcript_lines(files: list[Path]) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Assistant lines (every file) and main-transcript user lines, reduced
    to scalar fields. Mirrors ArchiveImporter's extraction plus the fields
    the snapshot needs (stop_reason presence, sidechain, error kind, agent).

    Never selected: message content, tool inputs/results, cwd, git branch."""
    if not files:
        return _empty_lines(), _empty_user_lines()
    con = _duck()
    main = [f for f in files if "/subagents/" not in str(f)]
    src = lambda fl: (f"read_ndjson_objects({_file_list_sql(fl)}, ignore_errors = true, "
                      f"maximum_object_size = 268435456, filename = true)")
    try:
        # Two streaming passes, each projecting its scalar fields straight
        # away: the raw JSON (which holds message content) is never
        # materialized.
        lines = con.execute(f"""
        WITH p AS (
          SELECT json_extract_string(json, ['$.type','$.timestamp','$.message.model','$.message.id',
                   '$.requestId','$.sessionId','$.version','$.message.stop_reason','$.entrypoint',
                   '$.agentId','$.message.usage.speed','$.message.usage.inference_geo',
                   '$.error','$.apiError']) AS s,
                 json_extract(json, ['$.message.usage.input_tokens','$.message.usage.output_tokens',
                   '$.message.usage.cache_read_input_tokens',
                   '$.message.usage.cache_creation.ephemeral_5m_input_tokens',
                   '$.message.usage.cache_creation.ephemeral_1h_input_tokens',
                   '$.message.usage.cache_creation_input_tokens','$.isApiErrorMessage',
                   '$.message.usage.iterations','$.isSidechain']) AS x,
                 filename AS fname
          FROM {src(files)} WHERE contains(json, '"assistant"')
        )
        SELECT epoch_ms(try_cast(s[2] AS TIMESTAMPTZ)) AS t, s[3] AS model, s[4] AS message_id,
               s[5] AS request_id, s[6] AS session_id, s[7] AS cc_version,
               s[8] IS NOT NULL AS finished, s[9] AS entrypoint, s[10] AS agent_id,
               s[11] AS speed, s[12] AS geo, s[13] AS error, s[14] AS api_error_kind,
               COALESCE(TRY_CAST(x[1] AS BIGINT), 0) AS input,
               COALESCE(TRY_CAST(x[2] AS BIGINT), 0) AS output,
               COALESCE(TRY_CAST(x[3] AS BIGINT), 0) AS cache_read,
               COALESCE(TRY_CAST(x[4] AS BIGINT), 0) AS e5m,
               COALESCE(TRY_CAST(x[5] AS BIGINT), 0) AS e1h,
               COALESCE(TRY_CAST(x[6] AS BIGINT), 0) AS summed_cc,
               COALESCE(TRY_CAST(x[7] AS BOOLEAN), false) AS api_error,
               COALESCE(json_array_length(x[8]), 0) AS n_iter,
               COALESCE(TRY_CAST(x[9] AS BOOLEAN), false) AS sidechain,
               fname
        FROM p
        WHERE s[1] = 'assistant' AND s[3] IS NOT NULL AND s[3] <> '' AND s[2] IS NOT NULL
          AND try_cast(s[2] AS TIMESTAMPTZ) IS NOT NULL
        ORDER BY fname, t, message_id, request_id, output, finished
        """).df()
        if main:
            users = con.execute(f"""
            WITH p AS (
              SELECT json_extract_string(json, ['$.type','$.timestamp','$.sessionId','$.promptId',
                       '$.promptSource','$.turnOrigin','$.scheduledTaskId','$.isCompactSummary',
                       '$.isMeta','$.origin.kind','$.message.content[0].type']) AS s,
                     json_type(json, '$.message.content') AS ctype, filename AS fname
              FROM {src(main)} WHERE contains(json, '"user"')
            )
            SELECT epoch_ms(try_cast(s[2] AS TIMESTAMPTZ)) AS t, s[3] AS session_id, s[4] AS prompt_id,
                   s[5] AS prompt_source, s[6] AS turn_origin, s[7] IS NOT NULL AS scheduled,
                   COALESCE(TRY_CAST(s[8] AS BOOLEAN), false) AS compact,
                   COALESCE(TRY_CAST(s[9] AS BOOLEAN), false) AS is_meta,
                   s[10] AS origin_kind,
                   CASE WHEN ctype = 'VARCHAR' THEN 'text' ELSE s[11] END AS content0,
                   fname
            FROM p WHERE s[1] = 'user' AND try_cast(s[2] AS TIMESTAMPTZ) IS NOT NULL
            ORDER BY fname, t, prompt_id
            """).df()
        else:
            users = _empty_user_lines()
    finally:
        con.close()
    for c in ("t", "input", "output", "cache_read", "e5m", "e1h", "summed_cc", "n_iter"):
        lines[c] = lines[c].astype("int64")
    users["t"] = users["t"].astype("int64")
    return lines, users


def _empty_lines() -> pd.DataFrame:
    return pd.DataFrame({c: pd.Series([], dtype=d) for c, d in [
        ("t", "int64"), ("model", object), ("message_id", object), ("request_id", object),
        ("session_id", object), ("cc_version", object), ("finished", bool), ("entrypoint", object),
        ("agent_id", object), ("speed", object), ("geo", object), ("error", object),
        ("api_error_kind", object), ("input", "int64"), ("output", "int64"), ("cache_read", "int64"),
        ("e5m", "int64"), ("e1h", "int64"), ("summed_cc", "int64"), ("api_error", bool),
        ("n_iter", "int64"), ("sidechain", bool), ("fname", object)]})


def _empty_user_lines() -> pd.DataFrame:
    return pd.DataFrame({c: pd.Series([], dtype=d) for c, d in [
        ("t", "int64"), ("session_id", object), ("prompt_id", object), ("prompt_source", object),
        ("turn_origin", object), ("scheduled", bool), ("compact", bool), ("is_meta", bool),
        ("origin_kind", object), ("content0", object), ("fname", object)]})


_TS_RE = re.compile(rb'"timestamp":"([^"]+)"')


def _parse_iso_ms(s: str) -> int | None:
    try:
        return int(datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() * 1000)
    except ValueError:
        return None


def extract_cost_state(files: list[Path]) -> pd.DataFrame:
    """Every `cost-state` line in main transcripts, per model. A cost-state
    line carries no timestamp of its own, so its time is the timestamp of the
    nearest earlier line that has one (spec §2.1). Streams line by line; a
    line is parsed only when it is a cost-state line."""
    rows = []
    for f in files:
        if "/subagents/" in str(f):
            continue
        last_ts: int | None = None
        try:
            fh = open(f, "rb")
        except OSError:
            continue
        with fh:
            for line in fh:
                if b'"cost-state"' in line:
                    try:
                        o = json.loads(line)
                    except ValueError:
                        continue
                    if o.get("type") != "cost-state":
                        continue
                    for model, u in (o.get("modelUsage") or {}).items():
                        if not isinstance(u, dict):
                            continue
                        rows.append({
                            "fname": str(f), "session_id": o.get("sessionId"), "t": last_ts,
                            "start_ms": o.get("startTime"), "model": model,
                            "input": u.get("inputTokens"), "output": u.get("outputTokens"),
                            "cache_read": u.get("cacheReadInputTokens"),
                            "cache_write": u.get("cacheCreationInputTokens"),
                            "cost_usd": u.get("costUSD"),
                        })
                    continue
                m = _TS_RE.search(line, 0, 4096) or _TS_RE.search(line)
                if m:
                    v = _parse_iso_ms(m.group(1).decode(errors="replace"))
                    if v is not None:
                        last_ts = v
    df = pd.DataFrame(rows, columns=["fname", "session_id", "t", "start_ms", "model", "input", "output",
                                     "cache_read", "cache_write", "cost_usd"])
    for c in ("t", "start_ms", "input", "output", "cache_read", "cache_write"):
        df[c] = pd.to_numeric(df[c], errors="coerce").astype("Int64")
    df["cost_usd"] = pd.to_numeric(df["cost_usd"], errors="coerce").astype("float64")
    return df.sort_values(["fname", "t", "model"], kind="stable").reset_index(drop=True)


def extract_metas(files: list[Path]) -> pd.DataFrame:
    """Subagent `*.meta.json` beside each `subagents/agent-*.jsonl`. Only
    the structural fields: type, model alias, depth, fork flag. The custom
    agent name and description are read by json.load but never kept beyond
    the builtin/custom decision made in `build`."""
    rows = []
    dirs = sorted({f.parent for f in files if f.parent.name == "subagents"}, key=lambda p: str(p).encode())
    for d in dirs:
        for m in sorted(d.glob("*.meta.json"), key=lambda p: str(p).encode()):
            try:
                o = json.loads(m.read_text())
            except (OSError, ValueError):
                continue
            if not isinstance(o, dict):
                continue
            jsonl = m.with_name(m.name[: -len(".meta.json")] + ".jsonl")
            rows.append({
                "fname": str(jsonl),
                "agent_type": o.get("agentType") if isinstance(o.get("agentType"), str) else None,
                "is_builtin_flag": o.get("isBuiltIn") if isinstance(o.get("isBuiltIn"), bool) else None,
                "model": o.get("model") if isinstance(o.get("model"), str) else None,
                "spawn_depth": o.get("spawnDepth") if isinstance(o.get("spawnDepth"), int) else None,
                "is_fork": bool(o.get("isFork")) if o.get("isFork") is not None else False,
            })
    df = pd.DataFrame(rows, columns=["fname", "agent_type", "is_builtin_flag", "model", "spawn_depth", "is_fork"])
    df["spawn_depth"] = pd.to_numeric(df["spawn_depth"], errors="coerce").astype("Int64")
    return df


def extract_history(path: Path | None) -> pd.DataFrame:
    """`history.jsonl`: one row per typed prompt — timestamp, project path,
    session id. `display` and `pastedContents` are discarded per line."""
    rows = []
    if path is not None and path.exists():
        with open(path, "rb") as fh:
            for line in fh:
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(o, dict):
                    continue
                ts = o.get("timestamp")
                if not isinstance(ts, (int, float)):
                    continue
                rows.append((int(ts), o.get("project") if isinstance(o.get("project"), str) else None,
                             o.get("sessionId") if isinstance(o.get("sessionId"), str) else None))
    df = pd.DataFrame(rows, columns=["t", "project", "session_id"])
    df["t"] = df["t"].astype("int64")
    return df.sort_values(["t", "session_id", "project"], kind="stable", na_position="first").reset_index(drop=True)


_CSWAP_SWITCH = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),(\d{3}) - INFO - Switched from account (\d+) to (\d+)\s*$")
_ROTATE_TICK = re.compile(r"^(\d{2}):(\d{2}):(\d{2}) status: on (\d+)\b")


def _local_ms(naive: datetime) -> int:
    """A naive local wall-clock time from a log, in epoch ms, using this
    machine's time zone rules (DST included)."""
    return int(naive.astimezone().timestamp() * 1000)


def extract_cswap(path: Path | None) -> pd.DataFrame:
    """cswap "Switched from account N to M" events (switcher slots, not ids).
    Only the timestamp and the two slot numbers are kept."""
    rows = []
    if path is not None and path.exists():
        with open(path, errors="replace") as fh:
            for line in fh:
                m = _CSWAP_SWITCH.match(line.rstrip("\n"))
                if m:
                    t = _local_ms(datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")) + int(m.group(2))
                    rows.append((t, int(m.group(3)), int(m.group(4))))
    return pd.DataFrame(rows, columns=["t", "from_slot", "to_slot"]).astype("int64")


def extract_rotate(path: Path | None) -> pd.DataFrame:
    """Rotation-controller ticks. The log stamps time of day only, so dates
    are rebuilt from the order of lines: the last line is dated by the file's
    mtime, and walking backwards a time-of-day that goes *up* means the line
    before it was a day earlier. A gap of a whole day without a tick would
    be invisible; the rows are scope S and only used as helpers."""
    if path is None or not path.exists():
        return pd.DataFrame({"t": pd.Series([], dtype="int64"), "slot": pd.Series([], dtype="int64")})
    ticks = []
    with open(path, errors="replace") as fh:
        for line in fh:
            m = _ROTATE_TICK.match(line)
            if m:
                ticks.append((int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3)), int(m.group(4))))
    if not ticks:
        return pd.DataFrame({"t": pd.Series([], dtype="int64"), "slot": pd.Series([], dtype="int64")})
    mtime = datetime.fromtimestamp(os.stat(path).st_mtime)
    day = mtime.date()
    if ticks[-1][0] > mtime.hour * 3600 + mtime.minute * 60 + mtime.second + 60:
        day = day.fromordinal(day.toordinal() - 1)
    rows = []
    prev = None
    for sec, slot in reversed(ticks):
        if prev is not None and sec > prev:
            day = day.fromordinal(day.toordinal() - 1)
        prev = sec
        naive = datetime(day.year, day.month, day.day, sec // 3600, (sec // 60) % 60, sec % 60)
        rows.append((_local_ms(naive), slot))
    rows.reverse()
    return pd.DataFrame(rows, columns=["t", "slot"]).astype("int64")


def extract_desktop_ids(root: Path | None) -> set[str]:
    """Claude Desktop's own session records: only the `cliSessionId` of
    each, to flag Desktop sessions whose transcripts are gone."""
    out: set[str] = set()
    if root is None or not root.exists():
        return out
    for p in sorted(root.rglob("local_*.json"), key=lambda x: str(x).encode()):
        try:
            o = json.loads(p.read_text())
        except (OSError, ValueError):
            continue
        v = o.get("cliSessionId") if isinstance(o, dict) else None
        if isinstance(v, str):
            out.add(v)
    return out


def read_json(path: Path | None) -> dict | None:
    if path is None or not path.exists():
        return None
    return json.loads(path.read_text())
