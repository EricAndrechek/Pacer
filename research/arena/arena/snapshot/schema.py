"""The snapshot's tables: the one schema the exporter writes, the synthetic
generator imitates, and the harness slices. docs/snapshot-spec.md explains
where each column comes from; this file is what code agrees on.

Conventions:
- Every time is UTC, `timestamp[ms, UTC]` in parquet, and epoch milliseconds
  (`Millis`) in Python APIs.
- Every table carries `t_event` (when it happened), `t_known` (the earliest
  moment today's Pacer would have held the row in its final form) and
  `t_known_src`. The harness's as-of view is `t_known <= now`; nothing else.
- Accounts are pseudonymous labels (`A1`…); ids, sessions and projects are
  salted 64-bit hashes. No prompt or message text exists anywhere.
- A table's `scope` says who would have the data: every Pacer user (E), users
  with several accounts (M), or only this setup (S). A model that should
  generalize must be able to drop every S table.
"""
from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum

import pyarrow as pa

TS = pa.timestamp("ms", tz="UTC")
SCHEMA_VERSION = 1


class Scope(StrEnum):
    EVERY_USER = "E"
    MULTI_ACCOUNT = "M"
    THIS_SETUP = "S"


class Where(StrEnum):
    """Which part of a snapshot a table lives in."""

    DATA = "data"        # train/ and holdout/: models may read it (as of now)
    LABELS = "labels"    # labels/: harness only — scoring truth, never a feature


@dataclass(frozen=True)
class Table:
    name: str
    scope: Scope
    where: Where
    grain: str
    columns: tuple[tuple[str, pa.DataType], ...]
    # Opaque tables keep the columns below as a minimum; the exporter may add
    # more (records of what the app did), and the harness passes them through.
    open_columns: bool = False

    def arrow_schema(self) -> pa.Schema:
        return pa.schema([pa.field(n, t) for n, t in self.columns])


_CLOCKS = (("t_event", TS), ("t_known", TS), ("t_known_src", pa.string()))

# t_known_src values: "history" (SwiftData change history), "modeled" (lag
# drawn from the measured distribution), "observed" (recorded at the event),
# "unknown" (label-only rows).
T_KNOWN_SOURCES = ("history", "modeled", "observed", "unknown")

WINDOW_KINDS = ("five_hour", "seven_day", "session", "weekly_all", "weekly_scoped")
OUTPUT_REGIMES = (
    "first_copy", "finished", "unfinished_interrupted",
    "subagent_defect", "subagent_defect_suspect", "unknown",
)
# Bits of turns.revised_mask.
REVISED_ACCOUNT, REVISED_OUTPUT, REVISED_PROJECT, REVISED_GEO_SPEED = 1, 2, 4, 8

TABLES: dict[str, Table] = {t.name: t for t in (
    Table("turns", Scope.EVERY_USER, Where.DATA, "one API call", _CLOCKS + (
        ("call_id", pa.uint64()),
        ("account", pa.string()),
        ("account_as_observed", pa.string()),   # replay of observed-only activations at t_known
        ("attribution_src", pa.string()),       # manual_range | observed | credential | retro_reassign | desktop_restamp
        ("model", pa.string()),
        ("model_family", pa.string()),          # fable | opus | sonnet | haiku | other
        ("input", pa.int64()),
        ("output", pa.int64()),                 # as recorded; never overwritten
        ("cache_read", pa.int64()),
        ("cache_write_5m", pa.int64()),
        ("cache_write_1h", pa.int64()),
        ("output_regime", pa.string()),         # OUTPUT_REGIMES
        ("output_reliable", pa.bool_()),
        ("output_imputed", pa.float64()),       # defect rows only; null elsewhere
        ("output_imputed_src", pa.string()),
        ("output_imputed_t_known", TS),         # an imputation is known only when its evidence is
        ("inference_geo", pa.string()),         # null = unknown, never "standard"
        ("speed", pa.string()),
        ("session_h", pa.uint64()),
        ("project_h", pa.uint64()),
        ("subdir_depth", pa.int16()),
        ("cc_version", pa.string()),
        ("cc_version_num", pa.int64()),         # major*1_000_000 + minor*1_000 + patch
        ("tz_offset_min", pa.int16()),
        ("is_subagent", pa.bool_()),            # transcript-derived columns: null where pruned
        ("agent_kind", pa.string()),            # main | fork | builtin | custom
        ("finished", pa.bool_()),
        ("entrypoint", pa.string()),
        ("api_error", pa.bool_()),
        ("t_first_recorded", TS),
        ("t_final_recorded", TS),
        ("revised_mask", pa.int16()),
    )),
    Table("turn_revisions", Scope.EVERY_USER, Where.DATA, "one recorded change to a turn", _CLOCKS + (
        ("call_id", pa.uint64()),
        ("kind", pa.string()),                  # insert | output_upgrade | account_restamp | project_rewrite | geo_speed_patch
    )),
    Table("meter_readings", Scope.EVERY_USER, Where.DATA, "one poll of one window", _CLOCKS + (
        ("account", pa.string()),
        ("window_kind", pa.string()),           # WINDOW_KINDS
        ("scope_model", pa.string()),           # e.g. "Fable" for a per-model cap; else null
        ("identity", pa.string()),
        ("util_pct", pa.float64()),             # integer-valued today
        ("resets_at", TS),                      # null when the window is idle
        ("state", pa.string()),                 # active | idle
        ("severity", pa.string()),
        ("source", pa.string()),                # oauth | cswap | switcher
        ("origin", pa.string()),                # live | archive
        ("dup_group", pa.int64()),              # links session/weekly_all rows to their 5h/7d twin
        ("backwards_pp", pa.float64()),         # > 0 when the reading fell within its cycle
    )),
    Table("prices", Scope.EVERY_USER, Where.DATA, "one rate for one period from one source", _CLOCKS + (
        ("model", pa.string()),
        ("part", pa.string()),                  # input | output | cache_read | cache_write_5m | cache_write_1h
        ("tier_threshold", pa.int64()),         # prompt tokens above which this rate applies; null = base
        ("geo_mult", pa.float64()),
        ("speed_mult", pa.float64()),
        ("rate_per_mtok", pa.float64()),
        ("source", pa.string()),                # litellm | models_dev | curated | ledger
        ("commit_sha", pa.string()),
        ("t_effective_from", TS),               # t_event == t_effective_from
        ("t_effective_to", TS),
        ("is_correction", pa.bool_()),
    )),
    Table("accounts", Scope.MULTI_ACCOUNT, Where.DATA, "one account", _CLOCKS + (
        ("account", pa.string()),
        ("plan_current", pa.string()),          # current value only: never a historical feature
        ("tier_current", pa.string()),
    )),
    Table("account_events", Scope.MULTI_ACCOUNT, Where.DATA, "an activation, switch or rotation tick", _CLOCKS + (
        ("account", pa.string()),
        ("kind", pa.string()),                  # activation | switch | rotation_tick
        ("t_end", TS),                          # future information until t_end_known
        ("t_end_known", TS),
        ("source", pa.string()),
        ("evidence", pa.string()),              # a category, never raw text
        ("row_scope", pa.string()),             # M or S (cswap / rotation rows are S)
    )),
    Table("sessions", Scope.EVERY_USER, Where.DATA, "one Claude Code session", _CLOCKS + (
        ("session_h", pa.uint64()),
        ("project_h", pa.uint64()),
        ("account", pa.string()),
        ("entrypoint", pa.string()),
        ("is_desktop", pa.bool_()),
        ("cc_version", pa.string()),
        ("t_end", TS),
    )),
    Table("prompts", Scope.EVERY_USER, Where.DATA, "one prompt (timestamp only)", _CLOCKS + (
        ("session_h", pa.uint64()),
        ("project_h", pa.uint64()),
        ("origin", pa.string()),                # human | tool_result | scheduled | task_notification | compact | unknown
    )),
    Table("subagent_spawns", Scope.EVERY_USER, Where.DATA, "one subagent spawn", _CLOCKS + (
        ("session_h", pa.uint64()),
        ("agent_class", pa.string()),           # builtin | custom (never the custom name)
        ("builtin_type", pa.string()),
        ("model", pa.string()),
        ("spawn_depth", pa.int16()),
        ("is_fork", pa.bool_()),
    )),
    Table("session_cost_state", Scope.EVERY_USER, Where.DATA, "Claude Code's own per-session totals, per model", _CLOCKS + (
        ("session_h", pa.uint64()),
        ("model", pa.string()),
        ("input", pa.int64()),
        ("output", pa.int64()),
        ("cache_read", pa.int64()),
        ("cache_write", pa.int64()),
        ("cost_usd", pa.float64()),
    )),
    Table("limit_hits", Scope.EVERY_USER, Where.DATA, "a rate-limit error seen in a transcript", _CLOCKS + (
        ("account", pa.string()),
        ("session_h", pa.uint64()),
        ("model", pa.string()),
    )),
    Table("app_alive", Scope.EVERY_USER, Where.DATA, "an interval when Pacer was polling", _CLOCKS + (
        ("t_end", TS),
    )),
    Table("meter_fits", Scope.EVERY_USER, Where.DATA, "the app's daily spend-to-meter fit", _CLOCKS + (
        ("account", pa.string()),
        ("window_kind", pa.string()),
        ("fit_json", pa.string()),
        ("r2", pa.float64()),
    ), open_columns=True),
    Table("regimes", Scope.EVERY_USER, Where.DATA, "a dated change in how data was collected", _CLOCKS + (
        ("name", pa.string()),
        ("t_end", TS),
        ("affects", pa.list_(pa.string())),
        ("description", pa.string()),
    )),
    # Records of what the app did. Baselines and labels: the harness never
    # serves them to a model as history (a model must not learn from the app's
    # own later re-scoring), only to scoring and to the shipping-model ports.
    Table("predictions_of_record", Scope.EVERY_USER, Where.LABELS, "one PredictionSnapshot row", _CLOCKS + (
        ("surface", pa.string()),
        ("account", pa.string()),
        ("method", pa.string()),
        ("is_lab", pa.bool_()),
    ), open_columns=True),
    Table("eval_of_record", Scope.EVERY_USER, Where.LABELS, "one EngineEvalOutcome row", _CLOCKS + (
        ("account", pa.string()),
        ("method", pa.string()),
        ("retro", pa.bool_()),
        ("rescored", pa.bool_()),
    ), open_columns=True),
    Table("cycles", Scope.EVERY_USER, Where.LABELS, "one observed meter cycle", _CLOCKS + (
        ("cycle_id", pa.string()),
        ("account", pa.string()),
        ("window_kind", pa.string()),
        ("scope_model", pa.string()),
        ("reset_at", TS),
        ("start", TS),
        ("first_t", TS),
        ("last_t", TS),
        ("n", pa.int32()),
        ("max_util", pa.float64()),
        ("final_util", pa.float64()),
        ("censored", pa.bool_()),
    )),
)}

DATA_TABLES = tuple(n for n, t in TABLES.items() if t.where is Where.DATA)
LABEL_TABLES = tuple(n for n, t in TABLES.items() if t.where is Where.LABELS)
