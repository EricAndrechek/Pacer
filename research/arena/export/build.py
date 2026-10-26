"""Stage 3: every snapshot table, as a pure function of `Inputs` and the
salt. The determinism gate calls `build_all` twice and compares hashes, so
nothing here may read the clock, the environment or an RNG with state."""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
import pandas as pd
import pyarrow as pa

from arena.snapshot.schema import TABLES

from . import prices as prices_mod
from . import readings as readings_mod
from . import records
from . import turns as turns_mod
from .pseudo import Hasher, label_accounts
from .util import to_arrow

PRED_TYPES = {
    "period_key": pa.string(), "period_end": pa.timestamp("ms", tz="UTC"), "value": pa.float64(),
    "used_pct": pa.float64(), "lo50": pa.float64(), "hi50": pa.float64(), "lo80": pa.float64(), "hi80": pa.float64(),
    "crossing_at": pa.timestamp("ms", tz="UTC"), "crossing_earliest": pa.timestamp("ms", tz="UTC"),
    "crossing_latest": pa.timestamp("ms", tz="UTC"), "slope_pct_per_hour": pa.float64(), "spend_so_far": pa.float64(),
    "residual_count": pa.int64(), "support": pa.int64(), "anchor_shift": pa.float64(), "band_stratum": pa.string(),
    "confidence": pa.string(), "engine_version": pa.string(), "params_version": pa.string(), "note": pa.string(),
    "hit_claimed": pa.bool_(), "replaced_method": pa.string(), "pricing_version": pa.string(),
}
EVAL_TYPES = {"surface": pa.string(), "key": pa.string(), "bucket": pa.string(), "period_key": pa.string(),
              "predicted": pa.float64(), "truth": pa.float64(), "abs_pct_error": pa.float64(),
              "recorded_at": pa.timestamp("ms", tz="UTC")}
FIT_TYPES = {"fitted_day": pa.string(), "method": pa.string(), "window": pa.string(), "pooled_r2": pa.float64(),
             "pooled_rate": pa.float64(), "rmse": pa.float64(), "intercept_per_hour": pa.float64(),
             "intercept_share": pa.float64(), "no_spend_rise_share": pa.float64(), "total_rise": pa.float64(),
             "total_spend_usd": pa.float64(), "unfitted_spend_usd": pa.float64(), "active_hours": pa.int64(),
             "hours": pa.int64(), "span_start": pa.timestamp("ms", tz="UTC"), "span_end": pa.timestamp("ms", tz="UTC")}


@dataclass
class Built:
    tables: dict[str, pa.Table]
    frames: dict[str, pd.DataFrame]        # wide frames for validation (raw ids; never written)
    labels: dict[str, str]                 # real id -> label (memory only)
    lag_models: dict
    stats: dict = field(default_factory=dict)
    data_end_ms: int = 0


def first_seen(inp, readings: pd.DataFrame) -> dict[str, int]:
    fs: dict[str, int] = {}
    for a, t in zip(inp.turns["account_id"], inp.turns["t"]):
        if isinstance(a, str):
            fs[a] = min(fs.get(a, t), t)
    for a, t in zip(readings["account_id"], readings["t_event"]):
        if isinstance(a, str):
            fs[a] = min(fs.get(a, int(t)), int(t))
    for a, t in zip(inp.activations["account_id"], inp.activations["started"]):
        if isinstance(a, str) and a not in fs and pd.notna(t):
            fs[a] = int(t)
    return {a: int(t) for a, t in fs.items()}


def canonicalizer(inp):
    """raw cwd -> canonical project path, as the store resolved it."""
    pairs = inp.turns[["orig_project", "project"]].dropna().drop_duplicates()
    m = dict(zip(pairs["orig_project"], pairs["project"]))
    alias = inp.alias_map

    def canon(p):
        if not isinstance(p, str):
            return None
        return m.get(p) or alias.get(p) or p
    return canon


def build_all(inp, salt: bytes) -> Built:
    hasher = Hasher(salt)
    stats: dict = {}

    rd = readings_mod.unify(inp)
    stats["readings_dedup_dropped"] = int(rd.attrs.get("dedup_dropped", 0))
    alive = readings_mod.app_alive(rd)
    labels = label_accounts(first_seen(inp, rd), hasher)
    cs_last = records.cost_state_last(inp.cost_state)

    tr = turns_mod.build_turns(inp, hasher, labels, alive, 0, cs_last)
    stats["turns"] = tr.stats
    rd, cswap_lag = readings_mod.assign_t_known(rd, inp, alive, hasher)
    data_end = int(max(tr.turns["t_known"].max() if len(tr.turns) else 0,
                       rd["t_known"].max() if len(rd) else 0))
    rd, cycles = readings_mod.build_readings(rd, labels, data_end)
    stats["readings"] = {"rows": len(rd), "by_src": rd["t_known_src"].value_counts().to_dict(),
                         "idle": int((rd["state"] == "idle").sum())}

    prices = prices_mod.build_prices(inp)
    data_start = int(inp.turns["t"].min()) if len(inp.turns) else 0
    canon = canonicalizer(inp)
    t = tr.turns
    session_project = (t[t["session_id"].notna() & t["project"].notna()]
                       .sort_values(["session_id", "t_event"]).drop_duplicates("session_id")
                       .set_index("session_id")["project"].to_dict())

    frames = {
        "turns": t,
        "turn_revisions": tr.revisions,
        "meter_readings": rd,
        "cycles": cycles,
        "prices": prices,
        "accounts": records.build_accounts(first_seen(inp, rd), labels, inp.accounts),
        "account_events": records.build_account_events(inp, labels, data_start),
        "sessions": records.build_sessions(t, inp.desktop_ids),
        "prompts": records.build_prompts(inp, hasher, session_project, canon),
        "subagent_spawns": records.build_spawns(inp, hasher),
        "session_cost_state": records.build_session_cost_state(cs_last, hasher),
        "limit_hits": records.build_limit_hits(inp, t, hasher),
        "app_alive": records.build_app_alive(alive),
        "meter_fits": records.build_meter_fits(inp, labels),
        "regimes": records.build_regimes(),
        "predictions_of_record": records.build_predictions(inp, labels),
        "eval_of_record": records.build_evals(inp, labels),
    }
    extras = {"predictions_of_record": list(PRED_TYPES.items()),
              "eval_of_record": list(EVAL_TYPES.items()),
              "meter_fits": list(FIT_TYPES.items())}
    tables = {name: to_arrow(name, frames[name], extras.get(name)) for name in TABLES}
    lag_models = {"turns": tr.lag.params(), "cswap_readings": cswap_lag.params(),
                  "backfill_slack_ms": readings_mod.clocks.BACKFILL_SLACK_MS,
                  "alive_gap_ms": readings_mod.clocks.ALIVE_GAP_MS}
    frames["_cost_state_last"] = cs_last
    frames["_reconcile"] = turns_mod.reconcile_sessions(t, cs_last)
    return Built(tables, frames, labels, lag_models, stats, data_end)
