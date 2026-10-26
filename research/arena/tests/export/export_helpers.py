"""A tiny, fully synthetic set of exporter inputs: a Pacer-shaped SQLite
store (with persistent history), a DuckDB raw archive, a transcript tree
(main and subagent files, streamed copies, a cost-state line), a prompt
log and price files. Every value is made up; nothing is read from this Mac.

The scenario, one UTC day from D0 = 2026-10-01:
- account X polls every 5 min all day; account Y from 06:00, via cswap,
  its morning readings already moved to the archive;
- 48 turns of X every 30 min and 12 of Y, half before SwiftData history
  starts (12:00), half after it (with inserts and one streamed upgrade);
- one subagent turn on a defect Claude Code version (unfinished copy only);
- activations: manual X until 06:00, observed Y 06:00-18:00, observed X after.
"""
from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import duckdb
import pytest

from export.sources import SourcePaths

CD = 978307200.0
D0 = 1790812800000          # 2026-10-01T00:00:00Z
MIN, HOUR = 60_000, 3_600_000
ACCT_X = "aaaaaaaa-1111-4111-8111-111111111111"
ACCT_Y = "bbbbbbbb-2222-4222-8222-222222222222"
ORG = "cccccccc-3333-4333-8333-333333333333"
PROJECT = "/Users/someone/work/proj-alpha"
SUBDIR = PROJECT + "/sub/dir"
SESSION_X = "dddddddd-4444-4444-8444-444444444444"
SESSION_Y = "eeeeeeee-5555-4555-8555-555555555555"
MODEL = "claude-opus-5-5"
HISTORY_START = D0 + 12 * HOUR

TS_COLS = ["Z_PK", "Z_ENT", "Z_OPT", "ZCACHECREATION1HTOKENS", "ZCACHECREATION5MTOKENS", "ZCACHEREADTOKENS",
           "ZINPUTTOKENS", "ZOUTPUTTOKENS", "ZSAMPLEDAT", "ZSOURCECOSTUSD", "ZCCVERSION", "ZDATE", "ZDEDUPKEY",
           "ZMODEL", "ZPROJECTPATH", "ZSESSIONID", "ZORIGINALPROJECTPATH", "ZLOCALHOUR", "ZACCOUNTID",
           "ZINFERENCEGEO", "ZSPEED"]


def cd(t_ms: int) -> float:
    return t_ms / 1000 - CD


def iso(t_ms: int) -> str:
    from datetime import datetime, timezone
    return datetime.fromtimestamp(t_ms / 1000, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def _turns():
    """(pk, t, account, session, key, input, output, cr, c5, c1, version, subagent, finished)"""
    out = []
    pk = 0
    for i in range(48):
        t = D0 + i * 30 * MIN + 10 * MIN
        acct = ACCT_Y if 6 * HOUR <= t - D0 < 18 * HOUR and i % 4 == 0 else ACCT_X
        pk += 1
        out.append(dict(pk=pk, t=t, acct=acct, session=SESSION_Y if acct == ACCT_Y else SESSION_X,
                        key=f"msg_{i:03d}:req_{i:03d}", input=100 + i, output=200 + 3 * i, cr=1000 + 10 * i,
                        c5=50, c1=5 * (i % 3), ver="2.1.300" if i % 7 else "2.1.270", sub=False, fin=True))
    # one subagent call on a defect version: only a mid-stream copy exists
    pk += 1
    out.append(dict(pk=pk, t=D0 + 15 * HOUR + 5 * MIN, acct=ACCT_X, session=SESSION_X, key="msg_sub:req_sub",
                    input=7, output=3, cr=500, c5=0, c1=0, ver="2.1.290", sub=True, fin=False))
    return out


def build_store(path: Path, turns, *, tamper_archive: bool = False) -> None:
    c = sqlite3.connect(path)
    c.execute(f"CREATE TABLE ZTOKENSAMPLE ({', '.join(TS_COLS)})")
    for r in turns:
        geo = "not_available" if r["t"] >= HISTORY_START else None
        c.execute(f"INSERT INTO ZTOKENSAMPLE VALUES ({','.join('?' * len(TS_COLS))})",
                  (r["pk"], 29, 1, r["c1"], r["c5"], r["cr"], r["input"], r["output"], cd(r["t"]), None, r["ver"],
                   "2026-10-01", r["key"], MODEL, PROJECT, r["session"], SUBDIR if r["pk"] % 2 else PROJECT,
                   ((r["t"] - D0) // HOUR - 4) % 24, r["acct"], geo, None))
    c.execute("CREATE TABLE ZRATELIMITSAMPLE (Z_PK, Z_ENT, Z_OPT, ZRESETSAT, ZSAMPLEDAT, ZUSEDPERCENTAGE, ZSOURCE, ZWINDOW, ZACCOUNTID)")
    c.execute("CREATE TABLE ZUSAGELIMITSAMPLE (Z_PK, Z_ENT, Z_OPT, ZISACTIVE, ZPERCENT, ZRESETSAT, ZSAMPLEDAT, ZGROUP, ZIDENTITY, ZKIND, ZLABEL, ZMODELDISPLAYNAME, ZMODELID, ZSEVERITY, ZSOURCE, ZSURFACE, ZACCOUNTID)")
    c.execute("CREATE TABLE ZACCOUNTUSAGEARCHIVE (Z_PK, Z_ENT, Z_OPT, ZAMOUNTCENTS, ZRESETSAT, ZSAMPLEDAT, ZUSEDPERCENTAGE, ZACCOUNTID, ZKIND, ZSOURCE, ZWINDOW, ZSEVERITY, ZSURFACE, ZLIMITKIND, ZLABEL, ZGROUP, ZMODELID, ZIDENTITY, ZMODELDISPLAYNAME, ZISACTIVE)")
    rl_pk = ul_pk = ar_pk = 0
    readings_inserts = []   # (entity, pk, t_insert)
    for acct, step, src, start in ((ACCT_X, 5, "oauth", 0), (ACCT_Y, 10, "cswap", 6 * 60)):
        for m in range(start, 24 * 60 + 1, step):
            t = D0 + m * MIN
            five_reset = D0 + ((m // 300) + 1) * 300 * MIN
            util5 = float((m % 300) // 10)
            seven_reset = D0 + 7 * 24 * HOUR
            util7 = float(m // 60)
            idle = acct == ACCT_X and 20 * 60 <= m < 21 * 60
            r5 = None if idle else cd(five_reset)
            u5 = 0.0 if idle else util5
            archive = acct == ACCT_Y and m < 12 * 60
            for win, reset, util in (("five_hour", r5, u5), ("seven_day", cd(seven_reset), util7)):
                if archive:
                    ar_pk += 1
                    c.execute("INSERT INTO ZACCOUNTUSAGEARCHIVE (Z_PK, ZKIND, ZSAMPLEDAT, ZWINDOW, ZUSEDPERCENTAGE, ZRESETSAT, ZSOURCE, ZACCOUNTID) VALUES (?,?,?,?,?,?,?,?)",
                              (ar_pk, "rate_limit", cd(t), win, util, reset, src, acct))
                else:
                    rl_pk += 1
                    c.execute("INSERT INTO ZRATELIMITSAMPLE (Z_PK, ZRESETSAT, ZSAMPLEDAT, ZUSEDPERCENTAGE, ZSOURCE, ZWINDOW, ZACCOUNTID) VALUES (?,?,?,?,?,?,?)",
                              (rl_pk, reset, cd(t), util, src, win, acct))
                    if t >= HISTORY_START:
                        readings_inserts.append((25, rl_pk, t + (2000 if src == "oauth" else 30_000)))
            if acct == ACCT_X:
                for ident, kind, grp, disp, reset, util in (("session||", "session", "session", None, r5, u5),
                                                            ("weekly_scoped|Fable|", "weekly_scoped", "weekly", "Fable",
                                                             cd(seven_reset), float(m // 120))):
                    ul_pk += 1
                    c.execute("INSERT INTO ZUSAGELIMITSAMPLE (Z_PK, ZISACTIVE, ZPERCENT, ZRESETSAT, ZSAMPLEDAT, ZGROUP, ZIDENTITY, ZKIND, ZMODELDISPLAYNAME, ZSEVERITY, ZSOURCE, ZACCOUNTID) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                              (ul_pk, 1, util, reset, cd(t), grp, ident, kind, disp, "normal", src, acct))
                    if t >= HISTORY_START:
                        readings_inserts.append((30, ul_pk, t + 2000))
    c.execute("CREATE TABLE ZACCOUNTACTIVATION (Z_PK, Z_ENT, Z_OPT, ZENDEDAT, ZSTARTEDAT, ZACCOUNTID, ZEVIDENCE, ZROOTPATH, ZSOURCE)")
    c.executemany("INSERT INTO ZACCOUNTACTIVATION (Z_PK, ZENDEDAT, ZSTARTEDAT, ZACCOUNTID, ZEVIDENCE, ZSOURCE) VALUES (?,?,?,?,?,?)", [
        (1, cd(D0 + 6 * HOUR), -63114076800.0, ACCT_X, f"assigned by the maintainer via PACER_ACCOUNT_ASSIGN ({ACCT_X[:4]})", "manual"),
        (2, cd(D0 + 18 * HOUR), cd(D0 + 6 * HOUR), ACCT_Y, "oauthAccount in .claude.json", "observed"),
        (3, None, cd(D0 + 18 * HOUR), ACCT_X, "oauthAccount in .claude.json", "observed"),
    ])
    c.execute("CREATE TABLE ZACCOUNT (Z_PK, Z_ENT, Z_OPT, ZISACTIVE, ZLATESTEXTRAUSAGECENTS, ZFIRSTSEENAT, ZLASTSEENAT, ZLATESTFIVEHOURPCT, ZLATESTFIVEHOURRESETSAT, ZLATESTPOLLEDAT, ZLATESTSEVENDAYPCT, ZLATESTSEVENDAYRESETSAT, ZDISPLAYNAME, ZID, ZORGANIZATIONID, ZSUBSCRIPTIONTYPE, ZEMAILADDRESS, ZORGANIZATIONNAME, ZSWITCHERSLOT, ZRATELIMITTIER)")
    for i, a in enumerate((ACCT_X, ACCT_Y), start=1):
        c.execute("INSERT INTO ZACCOUNT (Z_PK, ZID, ZFIRSTSEENAT, ZSUBSCRIPTIONTYPE, ZRATELIMITTIER, ZSWITCHERSLOT, ZORGANIZATIONID, ZEMAILADDRESS, ZDISPLAYNAME) VALUES (?,?,?,?,?,?,?,?,?)",
                  (i, a, cd(D0), "max", "default_claude_max_20x", i, ORG, f"user{i}@example.com", f"User {i}"))
    c.execute("CREATE TABLE ZPREDICTIONSNAPSHOT (Z_PK, Z_ENT, Z_OPT, ZRESIDUALCOUNT, ZSUPPORT, ZANCHORSHIFT, ZCROSSINGAT, ZCROSSINGEARLIEST, ZCROSSINGLATEST, ZHI50, ZHI80, ZLO50, ZLO80, ZPERIODEND, ZRECORDEDAT, ZSLOPEPERCENTPERHOUR, ZSPENDSOFAR, ZUSEDPCT, ZVALUE, ZBANDSTRATUM, ZCONFIDENCE, ZENGINEVERSION, ZMETHOD, ZNOTE, ZPARAMSVERSION, ZPERIODKEY, ZSURFACE, ZHITCLAIMED, ZREPLACEDMETHOD, ZPRICINGVERSION)")
    for i in range(6):
        c.execute("INSERT INTO ZPREDICTIONSNAPSHOT (Z_PK, ZRECORDEDAT, ZSURFACE, ZMETHOD, ZVALUE, ZPERIODKEY, ZNOTE, ZCONFIDENCE) VALUES (?,?,?,?,?,?,?,?)",
                  (i + 1, cd(D0 + (2 + 3 * i) * HOUR), f"rl-five_hour#{ACCT_X}" if i % 2 else "rl-five_hour",
                   "lab-ensemble-5h" if i == 5 else "linear-recent", 40.0 + i, "2026-10-01T05:00:00Z",
                   "hitting the cap is rare for you", "low"))
    c.execute("CREATE TABLE ZENGINEEVALOUTCOME (Z_PK, Z_ENT, Z_OPT, ZABSPCTERROR, ZPREDICTED, ZRECORDEDAT, ZTRUTH, ZBUCKET, ZKEY, ZMETHOD, ZPERIODKEY, ZSURFACE)")
    for i in range(4):
        s = f"rl-five_hour#{ACCT_X}"
        c.execute("INSERT INTO ZENGINEEVALOUTCOME VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                  (i + 1, 11, 1, 2.0, 40.0, cd(D0 + (10 + 3 * i) * HOUR), 42.0, "cut=0.50|v2",
                   f"{s}|linear-recent|cut=0.50|v2|2026-10-01T05:00:00Z", "linear-recent", "2026-10-01T05:00:00Z", s))
    c.execute("CREATE TABLE ZSPENDMETERFIT (Z_PK, Z_ENT, Z_OPT, ZACTIVEHOURS, ZHOURS, ZFITTEDAT, ZINTERCEPTPERHOUR, ZINTERCEPTSHARE, ZNOSPENDRISESHARE, ZPOOLEDR2, ZPOOLEDRATE, ZR2, ZRMSE, ZSPANEND, ZSPANSTART, ZTOTALRISE, ZTOTALSPENDUSD, ZUNFITTEDSPENDUSD, ZACCOUNTID, ZFITKEY, ZFITTEDDAY, ZMETHOD, ZMODELRATESJSON, ZWINDOW)")
    c.execute("INSERT INTO ZSPENDMETERFIT (Z_PK, ZFITTEDAT, ZACCOUNTID, ZWINDOW, ZMETHOD, ZMODELRATESJSON, ZR2, ZFITTEDDAY, ZFITKEY) VALUES (1,?,?,?,?,?,?,?,?)",
              (cd(D0 + 13 * HOUR), ACCT_X, "five_hour", "nnls-hourly-v1", json.dumps({MODEL: 0.5}), 0.9, "2026-10-01", f"{ACCT_X}|five_hour"))
    c.execute("CREATE TABLE ZPRICERECORD (Z_PK, Z_ENT, Z_OPT, ZCURATED, ZDERIVEDMASK, ZTIERABOVEPROMPTTOKENS, ZCACHEREADPERTOKEN, ZCACHEWRITE1HPERTOKEN, ZCACHEWRITE5MPERTOKEN, ZEFFECTIVEFROM, ZEFFECTIVETO, ZFASTMULTIPLIER, ZINPUTPERTOKEN, ZOUTPUTPERTOKEN, ZRECORDEDAT, ZREGIONALMULTIPLIER, ZREVIEWEDAT, ZMODEL, ZNOTE, ZPROVIDER, ZRECORDID, ZREGION, ZSOURCE, ZSOURCEURL, ZSPEED)")
    c.execute("INSERT INTO ZPRICERECORD (Z_PK, ZCURATED, ZTIERABOVEPROMPTTOKENS, ZCACHEREADPERTOKEN, ZCACHEWRITE1HPERTOKEN, ZCACHEWRITE5MPERTOKEN, ZEFFECTIVEFROM, ZINPUTPERTOKEN, ZOUTPUTPERTOKEN, ZRECORDEDAT, ZREGIONALMULTIPLIER, ZREVIEWEDAT, ZMODEL, ZPROVIDER, ZREGION, ZSOURCE, ZSPEED) VALUES (1,1,0,2e-7,8e-6,5e-6,?,4e-6,2e-5,?,1.1,?,?,?,?,?,?)",
              (cd(D0 - 9 * 24 * HOUR), cd(D0 + 20 * 24 * HOUR), cd(D0 + 20 * 24 * HOUR), MODEL, "anthropic", "global", "curated", "standard"))
    c.execute("CREATE TABLE ZCLAUDECODEMETA (Z_PK, Z_ENT, Z_OPT, ZKEY, ZVALUE)")
    c.executemany("INSERT INTO ZCLAUDECODEMETA (ZKEY, ZVALUE) VALUES (?,?)", [("scan_version", "5"), ("cost_recompute_version", "19")])
    c.execute("CREATE TABLE ZPROJECTPATHALIAS (Z_PK, Z_ENT, Z_OPT, ZCREATEDAT, ZCANONICALPATH, ZSOURCEPATH, ZISAUTOGENERATED)")
    c.execute("CREATE TABLE Z_PRIMARYKEY (Z_ENT, Z_NAME, Z_SUPER, Z_MAX)")
    c.executemany("INSERT INTO Z_PRIMARYKEY (Z_ENT, Z_NAME) VALUES (?,?)", [
        (2, "AccountActivation"), (11, "EngineEvalOutcome"), (17, "PredictionSnapshot"), (25, "RateLimitSample"),
        (27, "SpendMeterFit"), (29, "TokenSample"), (30, "UsageLimitSample")])
    c.execute("CREATE TABLE ATRANSACTION (Z_PK INTEGER PRIMARY KEY, Z_ENT, Z_OPT, ZAUTHORTS, ZBUNDLEIDTS, ZCONTEXTNAMETS, ZPROCESSIDTS, ZTIMESTAMP, ZAUTHOR, ZBUNDLEID, ZCONTEXTNAME, ZPROCESSID, ZQUERYGEN)")
    c.execute("CREATE TABLE ACHANGE (Z_PK INTEGER PRIMARY KEY, Z_ENT, Z_OPT, ZCHANGETYPE, ZENTITY, ZENTITYPK, ZTRANSACTIONID, ZCOLUMNS)")
    tx = [0]

    def change(ent, pk, ct, t, cols=None):
        tx[0] += 1
        c.execute("INSERT INTO ATRANSACTION (Z_PK, ZTIMESTAMP) VALUES (?,?)", (tx[0], cd(t)))
        c.execute("INSERT INTO ACHANGE (ZCHANGETYPE, ZENTITY, ZENTITYPK, ZTRANSACTIONID, ZCOLUMNS) VALUES (?,?,?,?,?)",
                  (ct, ent, pk, tx[0], cols))
    change(29, 0, 0, HISTORY_START)  # history begins
    for r in turns:
        if r["t"] >= HISTORY_START:
            change(29, r["pk"], 0, r["t"] + 15_000)
            if r["pk"] % 5 == 0:
                change(29, r["pk"], 1, r["t"] + 60_000, bytes.fromhex("000800"))   # output upgrade
            if r["pk"] % 6 == 0:
                change(29, r["pk"], 1, D0 + 24 * HOUR + 30 * MIN, bytes.fromhex("010040"))   # geo/speed patch, later
    for ent, pk, t in sorted(readings_inserts, key=lambda x: x[2]):
        change(ent, pk, 0, t)
    for i in range(4):
        change(11, i + 1, 0, D0 + (10 + 3 * i) * HOUR + 1000)
    change(27, 1, 0, D0 + 13 * HOUR + 500)
    c.commit()
    c.close()


def build_archive(path: Path, turns, tamper: bool = False) -> None:
    con = duckdb.connect(str(path))
    con.execute("""CREATE TABLE turn (sampled_at TIMESTAMP, date VARCHAR, local_hour INTEGER, model VARCHAR,
        input_tokens BIGINT, output_tokens BIGINT, cache_read BIGINT, cache_creation_5m BIGINT, cache_creation_1h BIGINT,
        source_cost DOUBLE, dedup_key VARCHAR, session_id VARCHAR, original_project_path VARCHAR, cc_version VARCHAR)""")
    for r in turns:
        out = r["output"] + (1 if tamper and r["pk"] == 1 else 0)
        con.execute("INSERT INTO turn VALUES (make_timestamp(?::BIGINT * 1000), '2026-10-01', 0, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?)",
                    [r["t"], MODEL, r["input"], out, r["cr"], r["c5"], r["c1"], r["key"], r["session"], PROJECT, r["ver"]])
    con.close()


def _line(r, *, finished: bool, output: int, t: int, agent: str | None = None) -> str:
    msg_id, req_id = r["key"].split(":")
    o = {"type": "assistant", "timestamp": iso(t), "sessionId": r["session"], "version": r["ver"],
         "entrypoint": "cli", "cwd": SUBDIR, "requestId": req_id, "isSidechain": agent is not None,
         "message": {"id": msg_id, "model": MODEL, "role": "assistant",
                     "stop_reason": "end_turn" if finished else None,
                     "content": [{"type": "text", "text": "SECRET-CONTENT-NEVER-EXPORTED"}],
                     "usage": {"input_tokens": r["input"], "output_tokens": output, "cache_read_input_tokens": r["cr"],
                               "cache_creation_input_tokens": r["c5"] + r["c1"],
                               "cache_creation": {"ephemeral_5m_input_tokens": r["c5"], "ephemeral_1h_input_tokens": r["c1"]}}}}
    if agent:
        o["agentId"] = agent
    return json.dumps(o, separators=(",", ":"))


def build_transcripts(root: Path, turns) -> None:
    proj = root / "-Users-someone-work-proj-alpha"
    files: dict[Path, list[str]] = {}
    for sess in (SESSION_X, SESSION_Y):
        files[proj / f"{sess}.jsonl"] = []
    sub = proj / SESSION_X / "subagents" / "agent-a1b2.jsonl"
    files[sub] = []
    totals = {sess: {"input": 0, "output": 0, "cr": 0, "cw": 0} for sess in (SESSION_X, SESSION_Y)}
    for r in turns:
        tot = totals[r["session"]]
        tot["input"] += r["input"]
        tot["output"] += r["output"]
        tot["cr"] += r["cr"]
        tot["cw"] += r["c5"] + r["c1"]
        if r["sub"]:
            files[sub].append(_line(r, finished=False, output=1, t=r["t"], agent="a1b2"))
            files[sub].append(_line(r, finished=False, output=r["output"], t=r["t"] + 500, agent="a1b2"))
            continue
        f = proj / f"{r['session']}.jsonl"
        files[f].append(json.dumps({"type": "user", "timestamp": iso(r["t"] - 5000), "sessionId": r["session"],
                                    "promptId": f"p-{r['pk']}", "promptSource": "typed", "turnOrigin": "human",
                                    "message": {"role": "user", "content": "SECRET-PROMPT-NEVER-EXPORTED"}}))
        files[f].append(_line(r, finished=False, output=1, t=r["t"]))
        files[f].append(_line(r, finished=True, output=r["output"], t=r["t"] + 2000))
    # Claude Code's own counters: equal to the transcript totals for Y; for X,
    # 500 output tokens more, the finished copy the defect never wrote.
    for sess, extra in ((SESSION_Y, 0), (SESSION_X, 500)):
        tot = totals[sess]
        files[proj / f"{sess}.jsonl"].append(json.dumps({
            "type": "cost-state", "sessionId": sess, "startTime": D0, "totalCostUSD": 1.0,
            "modelUsage": {MODEL: {"inputTokens": tot["input"], "outputTokens": tot["output"] + extra,
                                   "cacheReadInputTokens": tot["cr"], "cacheCreationInputTokens": tot["cw"],
                                   "costUSD": 1.0}}}))
    # a rate-limit error line
    files[proj / f"{SESSION_X}.jsonl"].append(json.dumps({
        "type": "assistant", "timestamp": iso(D0 + 16 * HOUR), "sessionId": SESSION_X, "isApiErrorMessage": True,
        "error": "rate_limit", "message": {"id": "err1", "model": "<synthetic>", "role": "assistant",
                                           "content": [{"type": "text", "text": "limit"}]}}))
    for p, lines in files.items():
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("\n".join(lines) + "\n")
    (sub.with_name("agent-a1b2.meta.json")).write_text(json.dumps(
        {"agentType": "general-purpose", "model": "sonnet", "spawnDepth": 1, "description": "SECRET-DESC"}))


def build_prices(cand: Path, cur: Path) -> None:
    rates = {"input": 4.0, "output": 20.0, "cacheWrite5m": 5.0, "cacheWrite1h": 8.0, "cacheRead": 0.2}
    cand.write_text(json.dumps({"schema": 1, "generatedAt": "2026-10-21T00:00:00Z", "sources": {"litellm": "x", "modelsDev": "y"},
                                "models": [{"model": MODEL, "litellm": {"periods": [
                                    {"from": "2026-09-22", "commit": "1" * 40, "perMTok": rates,
                                     "tiers": {"above200k": None, "above100k": None}, "multipliers": {"us": 1.1}}]},
                                    "modelsDev": {"periods": []}}]}))
    cur.write_text(json.dumps({"schema": 1, "asOf": "2026-10-21", "records": [
        {"model": MODEL, "effectiveFrom": "2026-09-22", "effectiveTo": None, "perMTok": rates, "regionalMultiplier": 1.1}]}))


@pytest.fixture
def fixture_sources(tmp_path) -> SourcePaths:
    return make_sources(tmp_path)


def make_sources(tmp_path: Path, *, tamper_archive: bool = False) -> SourcePaths:
    turns = _turns()
    src = tmp_path / "src"
    (src / "group").mkdir(parents=True)
    build_store(src / "group" / "pacer.sqlite", turns)
    build_archive(src / "group" / "raw-archive.duckdb", turns, tamper_archive)
    build_transcripts(src / "claude" / "projects", turns)
    hist = src / "claude" / "history.jsonl"
    hist.write_text("\n".join(json.dumps({"display": "SECRET-PROMPT", "pastedContents": {}, "timestamp": D0 + i * HOUR,
                                          "project": PROJECT, "sessionId": "ffffffff-6666-4666-8666-666666666666"})
                              for i in range(3)) + "\n")
    build_prices(src / "cand.json", src / "cur.json")
    return SourcePaths(store=src / "group" / "pacer.sqlite", archive=src / "group" / "raw-archive.duckdb",
                       transcript_roots=[src / "claude" / "projects"], history_jsonl=hist, cswap_log=None,
                       rotate_log=None, price_candidate=src / "cand.json", price_curated=src / "cur.json")
