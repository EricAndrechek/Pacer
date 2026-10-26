"""The smaller tables: accounts, account_events, sessions, prompts,
subagent_spawns, session_cost_state, limit_hits, app_alive, regimes,
meter_fits, and the records of what the app did (predictions_of_record,
eval_of_record).

Every string that leaves here is an enum, a public model id, a version, a
pseudonymous account label or an app-generated category. Raw evidence text,
custom agent names, surfaces with account ids in them: all mapped first.
"""
from __future__ import annotations

import re

import numpy as np
import pandas as pd

from . import clocks
from .turns import BUILTIN_AGENTS, DESKTOP_ENTRYPOINTS
from .util import ms

UUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")


def relabel(s, labels: dict[str, str]):
    """Replace every UUID in an app-written string with its account label
    (or "unknown"): surfaces and eval keys embed the raw account id."""
    if not isinstance(s, str):
        return s
    return UUID_RE.sub(lambda m: labels.get(m.group(0), labels.get(m.group(0).lower(), "unknown")), s)


def account_of(s, labels: dict[str, str]):
    if not isinstance(s, str):
        return None
    m = UUID_RE.search(s)
    if not m:
        return None
    return labels.get(m.group(0), labels.get(m.group(0).lower(), "unknown"))


# AccountActivation.evidence is free text written by the app; only its kind
# leaves the exporter.
def evidence_category(source: str | None, evidence: str | None) -> str:
    e = (evidence or "").lower()
    if source == "manual":
        return "maintainer_reassign" if "reassign" in e else "maintainer_assign"
    if source == "credential":
        return "keychain_credential" if "keychain" in e else "credential"
    if "reassigned" in e:
        return "oauth_account_file_reassigned"
    if "refuted" in e:
        return "oauth_account_file_refuted"
    if "oauthaccount" in e or ".claude.json" in e:
        return "oauth_account_file"
    return "other"


def build_accounts(first_seen: dict[str, int], labels: dict[str, str], acc: pd.DataFrame) -> pd.DataFrame:
    meta = {r.account_id: r for r in acc.itertuples()} if len(acc) else {}
    rows = []
    for a, lab in labels.items():
        r = meta.get(a)
        rows.append({"account": lab, "t_event": first_seen[a], "t_known": first_seen[a], "t_known_src": "observed",
                     "plan_current": getattr(r, "plan", None) if r is not None else None,
                     "tier_current": getattr(r, "tier", None) if r is not None else None})
    return pd.DataFrame(rows).sort_values(["t_known", "account"]).reset_index(drop=True)


def build_account_events(inp, labels: dict[str, str], data_start: int) -> pd.DataFrame:
    rows = []
    acts = inp.activations
    rec = inp.record_inserts
    ins = rec[(rec["entity"] == "AccountActivation") & (rec["ct"] == 0)].groupby("pk")["t"].min() if len(rec) else pd.Series(dtype="int64")
    obs_start = acts.loc[acts["source"] == "observed", "started"].dropna()
    multi_from = int(obs_start.min()) if len(obs_start) else data_start
    for r in acts.itertuples(index=False):
        start = None if pd.isna(r.started) else int(r.started)
        if r.source == "manual":
            # The manual range runs from distantPast; it was written when the
            # multi-account trail began (or when history saw it, if later).
            t_event = max(start if start is not None else data_start, data_start)
            t_known = int(ins.get(r.pk, multi_from)) if r.pk in ins.index else multi_from
            src = "history" if r.pk in ins.index else "modeled"
        else:
            t_event = start if start is not None else data_start
            t_known = t_event
            src = "observed"
        end = None if pd.isna(r.ended) else int(r.ended)
        rows.append({"t_event": t_event, "t_known": max(t_known, t_event), "t_known_src": src,
                     "account": labels.get(r.account_id), "kind": "activation",
                     "t_end": end, "t_end_known": end, "source": r.source,
                     "evidence": evidence_category(r.source, r.evidence), "row_scope": "M"})
    slot_acct = {int(r.slot): r.account_id for r in inp.accounts.itertuples() if pd.notna(r.slot)}
    for r in inp.cswap_switches.itertuples(index=False):
        rows.append({"t_event": int(r.t), "t_known": int(r.t), "t_known_src": "observed",
                     "account": labels.get(slot_acct.get(int(r.to_slot))), "kind": "switch",
                     "t_end": None, "t_end_known": None, "source": "cswap", "evidence": "cswap_switch",
                     "row_scope": "S"})
    for r in inp.rotate_ticks.itertuples(index=False):
        rows.append({"t_event": int(r.t), "t_known": int(r.t), "t_known_src": "observed",
                     "account": labels.get(slot_acct.get(int(r.slot))), "kind": "rotation_tick",
                     "t_end": None, "t_end_known": None, "source": "rotation", "evidence": "tick",
                     "row_scope": "S"})
    df = pd.DataFrame(rows, columns=["t_event", "t_known", "t_known_src", "account", "kind", "t_end",
                                     "t_end_known", "source", "evidence", "row_scope"])
    return df.sort_values(["t_known", "t_event", "kind", "account", "source"], na_position="first",
                          kind="stable").reset_index(drop=True)


def build_sessions(turns: pd.DataFrame, desktop_ids: set[str]) -> pd.DataFrame:
    t = turns
    if t.empty:
        return pd.DataFrame(columns=["t_event", "t_known", "t_known_src", "session_h", "project_h", "account",
                                     "entrypoint", "is_desktop", "cc_version", "t_end", "session_id"])
    t = t[t["session_id"].notna()].sort_values(["session_id", "t_event", "call_id"], kind="stable")
    g = t.groupby("session_id", sort=True)
    first = g.head(1).set_index("session_id")
    acct = (t.groupby(["session_id", "account"]).size().reset_index(name="n")
            .sort_values(["session_id", "n", "account"], ascending=[True, False, True])
            .drop_duplicates("session_id").set_index("session_id")["account"])
    ep = t[t["entrypoint"].notna()].groupby("session_id")["entrypoint"].first()
    out = pd.DataFrame({
        "t_event": g["t_event"].min(), "t_end": g["t_event"].max(), "t_known": g["t_known"].max(),
        "t_known_src": g["t_known_src"].agg(lambda s: "history" if (s == "history").all() else "modeled"),
        "session_h": first["session_h"], "project_h": first["project_h"], "account": acct,
        "entrypoint": ep, "cc_version": first["cc_version"],
    })
    out.index.name = "session_id"
    out = out.reset_index()
    out["is_desktop"] = out["entrypoint"].isin(DESKTOP_ENTRYPOINTS) | out["session_id"].isin(desktop_ids)
    return out.sort_values(["t_known", "session_h"], kind="stable").reset_index(drop=True)


def _origin(r) -> str:
    if r.compact:
        return "compact"
    if r.scheduled or r.turn_origin == "scheduled":
        return "scheduled"
    if r.turn_origin == "task_notification" or r.origin_kind == "task-notification":
        return "task_notification"
    if r.turn_origin == "human" or r.prompt_source == "typed" or r.origin_kind == "human":
        return "human"
    if r.content0 == "tool_result":
        return "tool_result"
    return "unknown"


def build_prompts(inp, hasher, session_project: dict[str, str], canon) -> pd.DataFrame:
    """One row per prompt: the first user line of each (session, promptId)
    in a main transcript, plus `history.jsonl` prompts of sessions whose
    transcripts are gone (03-30 on). Timestamps and hashes only."""
    u = inp.user_lines
    u = u[u["prompt_id"].notna() & u["session_id"].notna() & ~u["is_meta"].astype(bool)]
    u = u.sort_values(["session_id", "prompt_id", "t", "fname"], kind="stable").drop_duplicates(["session_id", "prompt_id"])
    rows = []
    for r in u.itertuples(index=False):
        proj = session_project.get(r.session_id)
        rows.append((int(r.t), hasher.h("session", r.session_id), hasher.h("project", proj) if proj else None, _origin(r)))
    seen = set(u["session_id"])
    h = inp.history
    for r in h.itertuples(index=False):
        if r.session_id in seen:
            continue
        proj = session_project.get(r.session_id) or canon(r.project)
        rows.append((int(r.t), hasher.h("session", r.session_id) if r.session_id else None,
                     hasher.h("project", proj) if proj else None, "human"))
    df = pd.DataFrame(rows, columns=["t_event", "session_h", "project_h", "origin"])
    df["t_known"] = df["t_event"]
    df["t_known_src"] = "observed"
    df["session_h"] = df["session_h"].astype("UInt64")
    df["project_h"] = df["project_h"].astype("UInt64")
    return df.sort_values(["t_known", "session_h", "origin"], kind="stable").reset_index(drop=True)


def build_spawns(inp, hasher) -> pd.DataFrame:
    lines = inp.lines
    first = lines.groupby("fname").agg(t=("t", "min"), session_id=("session_id", "first"))
    rows = []
    for r in inp.metas.itertuples(index=False):
        if r.fname not in first.index:
            continue
        f = first.loc[r.fname]
        builtin = r.agent_type in BUILTIN_AGENTS or r.is_builtin_flag is True or bool(r.is_fork)
        rows.append({"t_event": int(f["t"]), "session_h": hasher.h("session", f["session_id"]) if isinstance(f["session_id"], str) else None,
                     "agent_class": "builtin" if builtin else "custom",
                     "builtin_type": (r.agent_type if r.agent_type in BUILTIN_AGENTS else ("fork" if r.is_fork else None)) if builtin else None,
                     "model": r.model, "spawn_depth": None if pd.isna(r.spawn_depth) else int(r.spawn_depth),
                     "is_fork": bool(r.is_fork), "file_h": hasher.h("file", r.fname)})
    df = pd.DataFrame(rows, columns=["t_event", "session_h", "agent_class", "builtin_type", "model", "spawn_depth", "is_fork", "file_h"])
    df["t_known"] = df["t_event"]
    df["t_known_src"] = "observed"
    df["session_h"] = df["session_h"].astype("UInt64")
    df = df.sort_values(["t_known", "session_h", "file_h"], kind="stable").reset_index(drop=True)
    return df.drop(columns=["file_h"])


def cost_state_last(cs: pd.DataFrame) -> pd.DataFrame:
    """Claude Code's last cost-state per (session, model): the latest line,
    largest output on ties. Lines with no timestamped line before them are
    dropped (no time to know them by)."""
    c = cs[cs["t"].notna() & cs["session_id"].notna()].copy()
    if c.empty:
        return c.assign(t=pd.Series([], dtype="int64"))
    c["t"] = c["t"].astype("int64")
    c = c.sort_values(["session_id", "model", "t", "output", "fname"], ascending=[True, True, False, False, True],
                      kind="stable").drop_duplicates(["session_id", "model"])
    return c.reset_index(drop=True)


def build_session_cost_state(cs_last: pd.DataFrame, hasher) -> pd.DataFrame:
    df = pd.DataFrame({
        "t_event": cs_last["t"], "t_known": cs_last["t"], "t_known_src": "observed",
        "session_h": pd.array([hasher.h("session", s) for s in cs_last["session_id"]], dtype="UInt64"),
        "model": cs_last["model"], "input": cs_last["input"], "output": cs_last["output"],
        "cache_read": cs_last["cache_read"], "cache_write": cs_last["cache_write"], "cost_usd": cs_last["cost_usd"],
    })
    return df.sort_values(["t_known", "session_h", "model"], kind="stable").reset_index(drop=True)


def build_limit_hits(inp, turns: pd.DataFrame, hasher) -> pd.DataFrame:
    """Rate-limit errors Claude Code wrote into a transcript: direct sightings
    of a meter at 100%. Account and model are those of the session's last
    turn at or before the error (the error line itself is `<synthetic>`)."""
    l = inp.lines
    hits = l[l["api_error"].astype(bool) & (l["error"] == "rate_limit") & l["session_id"].notna()]
    hits = hits.drop_duplicates(["session_id", "t"]).sort_values(["session_id", "t"])
    tt = turns[turns["session_id"].notna()].sort_values(["session_id", "t_event"])
    by_sess = {s: (g["t_event"].to_numpy(dtype=np.int64), g["account"].to_numpy(dtype=object), g["model"].to_numpy(dtype=object))
               for s, g in tt.groupby("session_id")}
    rows = []
    for r in hits.itertuples(index=False):
        acct = model = None
        s = by_sess.get(r.session_id)
        if s is not None:
            i = np.searchsorted(s[0], r.t, side="right") - 1
            if i >= 0:
                acct, model = s[1][i], s[2][i]
        rows.append({"t_event": int(r.t), "t_known": int(r.t), "t_known_src": "observed", "account": acct,
                     "session_h": hasher.h("session", r.session_id), "model": model})
    df = pd.DataFrame(rows, columns=["t_event", "t_known", "t_known_src", "account", "session_h", "model"])
    df["session_h"] = df["session_h"].astype("UInt64")
    return df.sort_values(["t_known", "session_h"], kind="stable").reset_index(drop=True)


def build_app_alive(alive: clocks.Alive) -> pd.DataFrame:
    """A polling interval is fully known at its last poll."""
    df = pd.DataFrame({"t_event": alive.starts, "t_end": alive.ends, "t_known": alive.ends})
    df["t_known_src"] = "observed"
    return df


REGIMES = [
    ("first_copy_output", "2026-03-30", "2026-07-03", ["turns.output", "cost"],
     "Output kept the first streamed copy; under-counted (rows before the v3 repair reach)."),
    ("readings_start_a1", "2026-05-07", None, ["meter_readings"], "OAuth polling starts (5-minute cadence)."),
    ("output_clean_v3", "2026-07-03", None, ["turns.output"], "Streaming dedup keeps the finished copy."),
    ("polling_60s", "2026-07-08", None, ["meter_readings"], "Adaptive polling, about 60 s; 15 s by October."),
    ("scoped_limits", "2026-07-11", None, ["meter_readings"], "Scoped limits appear: Fable weekly, session, weekly_all."),
    ("subagent_defect_suspected", "2026-08-25", "2026-09-16", ["turns.output", "cost"],
     "Suspected Claude Code subagent defect (2.1.245-268); transcripts gone."),
    ("multi_account", "2026-09-03", None, ["turns.account", "account_events"], "Second account; activation trail."),
    ("per_account_fits", "2026-09-04", None, ["predictions_of_record", "eval_of_record"], "Per-account engine fits."),
    ("cswap_readings", "2026-09-08", None, ["meter_readings"], "Readings delivered through cswap; denser from 10-06."),
    ("subagent_defect_verified", "2026-09-23", "2026-10-22", ["turns.output", "cost"],
     "Claude Code 2.1.280-306 dropped finished subagent messages; output under-counted."),
    ("swiftdata_history", "2026-09-24T17:50:00Z", None, ["t_known", "turns.account"],
     "Persistent history begins: exact t_known; attribution fix."),
    ("rotation_controller", "2026-10-19", None, ["account_events"], "Rotation controller live (this setup only)."),
    ("geo_speed_ledger", "2026-10-21", None, ["turns.inference_geo", "turns.speed", "prices"],
     "Geo/speed reliable for new rows; Cowork roots; price ledger."),
    ("per_account_grading", "2026-10-23", None, ["eval_of_record", "predictions_of_record", "meter_fits"],
     "Per-account grading; unscoped rl snapshots stop; SpendMeterFit."),
]


def build_regimes() -> pd.DataFrame:
    """One row per regime from its start, with `t_end` null; a regime that
    has ended gets a second row, known from its end, carrying `t_end`. The
    end of a regime is future information until then (there is no
    `t_end_known` column here), so it only appears once it happened; a
    reader takes the latest row per name."""
    rows = []
    for name, start, end, affects, desc in REGIMES:
        t = ms(start)
        rows.append({"t_event": t, "t_known": t, "t_known_src": "observed", "name": name,
                     "t_end": None, "affects": affects, "description": desc})
        if end:
            rows.append({"t_event": t, "t_known": ms(end), "t_known_src": "observed", "name": name,
                         "t_end": ms(end), "affects": affects, "description": desc})
    return pd.DataFrame(rows).sort_values(["t_known", "name"]).reset_index(drop=True)


FIT_EXTRA = ["fitted_day", "method", "window", "pooled_r2", "pooled_rate", "rmse", "intercept_per_hour",
             "intercept_share", "no_spend_rise_share", "total_rise", "total_spend_usd", "unfitted_spend_usd",
             "active_hours", "hours", "span_start", "span_end"]


def build_meter_fits(inp, labels) -> pd.DataFrame:
    f = inp.fits
    if f.empty:
        return pd.DataFrame(columns=["t_event", "t_known", "t_known_src", "account", "window_kind", "fit_json", "r2"] + FIT_EXTRA)
    rec = inp.record_inserts
    ins = rec[(rec["entity"] == "SpendMeterFit") & (rec["ct"] == 0)].groupby("pk")["t"].min()
    t_ev = f["fitted_at"].astype("int64")
    t_ins = f["pk"].map(ins)
    df = pd.DataFrame({
        "t_event": t_ev, "t_known": np.maximum(t_ev, t_ins.fillna(t_ev).astype("int64")),
        "t_known_src": np.where(t_ins.notna(), "history", "observed"),
        "account": [labels.get(a) for a in f["account_id"]],
        "window_kind": [w.split("|")[0] if isinstance(w, str) else None for w in f["window"]],
        "fit_json": [relabel(x, labels) for x in f["rates_json"]], "r2": f["r2"],
    })
    for c in FIT_EXTRA:
        df[c] = f[c].to_numpy()
    df["window"] = [relabel(x, labels) for x in df["window"]]
    return df.sort_values(["t_known", "account", "window"], kind="stable").reset_index(drop=True)


PRED_EXTRA = ["period_key", "period_end", "value", "used_pct", "lo50", "hi50", "lo80", "hi80", "crossing_at",
              "crossing_earliest", "crossing_latest", "slope_pct_per_hour", "spend_so_far", "residual_count",
              "support", "anchor_shift", "band_stratum", "confidence", "engine_version", "params_version", "note",
              "hit_claimed", "replaced_method", "pricing_version"]


def build_predictions(inp, labels) -> pd.DataFrame:
    p = inp.predictions
    if p.empty:
        return pd.DataFrame(columns=["t_event", "t_known", "t_known_src", "surface", "account", "method", "is_lab"] + PRED_EXTRA)
    df = pd.DataFrame({
        "t_event": p["recorded_at"].astype("int64"), "t_known": p["recorded_at"].astype("int64"),
        "t_known_src": "observed",
        "surface": [relabel(s, labels) for s in p["surface"]],
        "account": [account_of(s, labels) for s in p["surface"]],
        "method": p["method"], "is_lab": p["method"].fillna("").str.startswith("lab"),
    })
    for c in PRED_EXTRA:
        df[c] = p[c].to_numpy()
    df["period_key"] = [relabel(x, labels) for x in df["period_key"]]
    df["_pk"] = p["pk"].to_numpy()
    df = df.sort_values(["t_known", "surface", "method", "_pk"], kind="stable").reset_index(drop=True)
    return df.drop(columns=["_pk"])


EVAL_EXTRA = ["surface", "key", "bucket", "period_key", "predicted", "truth", "abs_pct_error", "recorded_at"]
RETRO_UNSCOPED_BEFORE = ms("2026-06-11")
RETRO_PER_ACCOUNT_BEFORE = ms("2026-09-04")


def _period_end(key) -> int | None:
    if not isinstance(key, str):
        return None
    try:
        if len(key) == 7:
            y, m = int(key[:4]), int(key[5:7])
            return ms(f"{y + (m == 12):04d}-{(m % 12) + 1:02d}-01")
        if len(key) == 10:
            return ms(key) + clocks.DAY
        return ms(key)
    except ValueError:
        return None


def build_evals(inp, labels) -> pd.DataFrame:
    e = inp.evals
    if e.empty:
        return pd.DataFrame(columns=["t_event", "t_known", "t_known_src", "account", "method", "retro", "rescored"] + EVAL_EXTRA)
    rec = inp.record_inserts
    er = rec[rec["entity"] == "EngineEvalOutcome"] if len(rec) else rec
    ins = er[er["ct"] == 0].groupby("pk")["t"].min() if len(er) else pd.Series(dtype="int64")
    upd = set(er.loc[er["ct"] == 1, "pk"]) if len(er) else set()
    rec_at = e["recorded_at"].astype("int64")
    t_ins = e["pk"].map(ins)
    has = t_ins.notna()
    t_first = t_ins.fillna(rec_at).astype("int64")
    acct = [account_of(s, labels) for s in e["surface"]]
    pend = [_period_end(k) for k in e["period_key"]]
    retro = [pe is not None and pe < (RETRO_PER_ACCOUNT_BEFORE if a else RETRO_UNSCOPED_BEFORE) for pe, a in zip(pend, acct)]
    df = pd.DataFrame({
        "t_event": t_first, "t_known": t_first, "t_known_src": np.where(has, "history", "unknown"),
        "account": acct, "method": e["method"], "retro": retro,
        "rescored": [bool(pk in upd) or (bool(h) and r > ti + 1000) for pk, h, r, ti in zip(e["pk"], has, rec_at, t_first)],
    })
    for c in EVAL_EXTRA:
        df[c] = e[c].to_numpy()
    df["surface"] = [relabel(s, labels) for s in df["surface"]]
    df["key"] = [relabel(s, labels) for s in df["key"]]
    df["_pk"] = e["pk"].to_numpy()
    df = df.sort_values(["t_known", "key", "_pk"], kind="stable").reset_index(drop=True)
    return df.drop(columns=["_pk"])
