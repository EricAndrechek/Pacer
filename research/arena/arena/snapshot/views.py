"""As-of views of a snapshot: what a model may hold at a moment, and nothing
else.

Two halves, both in this file so they can never drift apart:

- **Runner side** (`SnapshotData`, `EpisodeView`): loads one tier's data
  tables into memory, prepares the internal clocks, and slices a view for a
  scope at any `now` (`history`) or between two moments (`events`). These hold
  future rows and must never be handed to a model.
- **Model side** (`HistoryView`, `EventsView`): the `History` / `Events`
  implementations from `arena.types`, built from exactly the tables the runner
  served — in a worker, from the Arrow tables that came over the pipe.

The as-of rule is `t_known <= now`, with these refinements, every one of them a
point-in-time trap from docs/snapshot-spec.md §2.6:

- **Values known later than their row** (`LATE_COLUMNS`, in both modes). A
  row can be known while one of its columns is still future information.
  Those columns, and the column saying when they become known, are null until
  that time, and the row is re-delivered (by its identity key) when they
  become known:
    - `turns.output_imputed*` until `output_imputed_t_known` (the imputation
      uses the session-end cost state);
    - `turns.t_first_recorded` / `t_final_recorded` until they happen (a
      backfilled row is known before the store wrote it; when it was written
      is later news);
    - `account_events.t_end` until `t_end_known` (an activation's end is
      known only when the next switch happens);
    - defensively, `sessions`/`app_alive`/`regimes.t_end` until they happen
      (exporters stamp those rows after they end, so this rarely bites).
  `prices.t_effective_to` is null in snapshots (a filled one dates the next
  change); if one is filled anyway it stays hidden until the next price for
  the same (model, part, tier) is known.
- **Current-only attributes** (`accounts.plan_current`, `tier_current`) are
  today's values and never served.
- **`as_recorded` mode** (strict, to reproduce what the app showed): a turn is
  visible from `t_first_recorded`; each revised group of columns is null until
  its revision is known (from `turn_revisions`, or never when `revised_mask`
  says it was revised and no revision row is in the tier), because the old
  values are not kept; the served `t_known` is when the served form became
  known. In `current_code` mode (default) a turn is served in its final form
  from `t_known`, and `revised_mask` keeps only the bits known by then.
- **Scope.** `scope_only` keeps the scope's accounts' rows: by `account`, and
  for tables without one, by the scope's sessions (`prompts`,
  `subagent_spawns`, `session_cost_state`) or calls (`turn_revisions`) as known
  at `now`. `prices`, `app_alive` and `regimes` are global.
- **History start.** Activity tables keep rows with `t_event >=` the
  episode's history start (a user who installed Pacer then); `prices`,
  `regimes` and `accounts` are not cut.

`history(a)` extended with `events(a, b)` equals `history(b)` exactly, in
both modes and both views (tests/core/test_views.py checks it).
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

import polars as pl
import pyarrow as pa
import pyarrow.parquet as pq

from arena.snapshot import snapshot_dir, arena_home
from arena.snapshot.schema import (
    DATA_TABLES, LABEL_TABLES, REVISED_ACCOUNT, REVISED_GEO_SPEED, REVISED_OUTPUT,
    REVISED_PROJECT, TABLES, Table,
)
from arena.types import Millis, Scope

Mode = Literal["current_code", "as_recorded"]
MODES: tuple[Mode, ...] = ("current_code", "as_recorded")
TIERS = ("visible", "leaderboard", "lockbox", "synthetic", "prospective")

ALWAYS = -(2 ** 62)   # knowability sentinel: known from the start
NEVER = 2 ** 62       # knowability sentinel: never known within this tier

# Tables an episode's history start does not cut.
UNCUT = frozenset({"prices", "regimes", "accounts"})
# Scope filtering.
ACCOUNT_TABLES = frozenset({"turns", "meter_readings", "accounts", "account_events",
                            "sessions", "limit_hits", "meter_fits"})
SESSION_TABLES = frozenset({"prompts", "subagent_spawns", "session_cost_state"})
CALL_TABLES = frozenset({"turn_revisions"})
GLOBAL_TABLES = frozenset({"prices", "app_alive", "regimes"})

# Rows that can be re-delivered in a newer form, and the columns that identify
# them (never a masked column). `History.extend` replaces by these keys.
IDENTITY: dict[str, tuple[str, ...]] = {
    "turns": ("call_id",),
    "sessions": ("session_h", "t_event", "t_known"),
    "account_events": ("t_event", "t_known", "account", "kind", "source"),
    "app_alive": ("t_event", "t_known"),
    "regimes": ("t_event", "t_known", "name"),
    "prices": ("t_event", "t_known", "model", "part", "tier_threshold", "source",
               "commit_sha", "is_correction", "rate_per_mtok", "geo_mult", "speed_mult"),
}

# Columns never served (current values, not history).
ALWAYS_NULL: dict[str, tuple[str, ...]] = {"accounts": ("plan_current", "tier_current")}

# turn_revisions.kind -> (revised_mask bit, columns it rewrites)
REVISION_GROUPS: dict[str, tuple[int, tuple[str, ...]]] = {
    "account_restamp": (REVISED_ACCOUNT, ("account",)),
    "output_upgrade": (REVISED_OUTPUT, ("output", "finished", "output_regime")),
    "project_rewrite": (REVISED_PROJECT, ("project_h", "subdir_depth")),
    "geo_speed_patch": (REVISED_GEO_SPEED, ("inference_geo", "speed")),
}

# Columns holding their final value but known later than their row:
# {table: {column: the column holding when it became known}}. In both modes a
# column is null while its known-time is > now (or null: never known), and the
# known-time column is hidden with it, since it dates news still to come. A
# column mapped to itself is known once it has happened. Exporters add here.
LATE_COLUMNS: dict[str, dict[str, str]] = {
    # t_first_recorded / t_final_recorded say when the store recorded the row
    # (and its final form). A backfilled row is known (t_known) before the
    # store wrote it, so either can lie after `now`: news still to come.
    "turns": {"output_imputed": "output_imputed_t_known", "output_imputed_src": "output_imputed_t_known",
              "t_first_recorded": "t_first_recorded", "t_final_recorded": "t_final_recorded"},
    "account_events": {"t_end": "t_end_known"},
    "sessions": {"t_end": "t_end"},
    "app_alive": {"t_end": "t_end"},
    "regimes": {"t_end": "t_end"},
}


def late_groups(table: str) -> dict[str, tuple[tuple[str, ...], str]]:
    """LATE_COLUMNS for one table as masked groups: group -> (columns hidden
    together, the known-time column). The group's clock is `_u_<group>`."""
    by_time: dict[str, list[str]] = {}
    for col, kt in LATE_COLUMNS.get(table, {}).items():
        cols = by_time.setdefault(kt, [])
        cols.append(col)
    out = {}
    for kt, cols in by_time.items():
        hidden = cols + ([kt] if kt not in cols else [])
        out[f"late_{kt}"] = (tuple(hidden), kt)
    return out


# Column groups masked until their own knowability time, by mode and table:
# group name -> columns. The knowability column is "_u_<group>".
_COMMON_MASKS: dict[str, dict[str, tuple[str, ...]]] = {
    **{t: {g: cols for g, (cols, _) in late_groups(t).items()} for t in LATE_COLUMNS},
    "prices": {"to": ("t_effective_to",)},
}
MASKS: dict[Mode, dict[str, dict[str, tuple[str, ...]]]] = {
    "current_code": _COMMON_MASKS,
    "as_recorded": {
        **_COMMON_MASKS,
        "turns": {
            **_COMMON_MASKS["turns"],          # includes t_final_recorded (LATE_COLUMNS)
            **{f"rev_{k}": cols for k, (_, cols) in REVISION_GROUPS.items()},
        },
    },
}


def ms(col: str) -> pl.Expr:
    return pl.col(col).dt.epoch("ms")


def empty_frame(name: str) -> pl.DataFrame:
    return pl.from_arrow(TABLES[name].arrow_schema().empty_table())


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

def parse_time(v) -> Millis | None:
    """Manifest times: epoch ms (int) or ISO 8601 (str)."""
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return int(v)
    import datetime as _dt
    s = str(v).replace("Z", "+00:00")
    t = _dt.datetime.fromisoformat(s)
    if t.tzinfo is None:
        t = t.replace(tzinfo=_dt.timezone.utc)
    return int(t.timestamp() * 1000)


def conform(table: pa.Table, spec: Table) -> pa.Table:
    """Cast a parquet piece to the pinned schema: missing columns become typed
    nulls; extra columns are dropped unless the table is open."""
    n = table.num_rows
    names, arrays = [], []
    for col, typ in spec.columns:
        if col in table.column_names:
            arr = table[col]
            if arr.type != typ:
                # Timestamps may arrive in another unit; truncating to ms is the
                # schema's resolution. Everything else casts safely or fails.
                arr = arr.cast(typ, safe=not pa.types.is_timestamp(typ))
        else:
            arr = pa.nulls(n, typ)
        names.append(col)
        arrays.append(arr)
    if spec.open_columns:
        for col in table.column_names:
            if col not in names and not col.startswith("_"):
                names.append(col)
                arrays.append(table[col])
    return pa.Table.from_arrays(arrays, names=names)


def _files(root: Path, name: str) -> list[Path]:
    single = root / f"{name}.parquet"
    if single.is_file():
        return [single]
    d = root / name
    return sorted(d.rglob("*.parquet")) if d.is_dir() else []


def read_table(roots: list[Path], name: str) -> pl.DataFrame:
    spec = TABLES[name]
    # One file at a time through ParquetFile: hive partitioning never applies,
    # so `month=`/`window=` path parts can't become columns.
    pieces = [conform(pq.ParquetFile(f).read(), spec) for root in roots for f in _files(root, name)]
    if not pieces:
        return empty_frame(name)
    t = pa.concat_tables(pieces, promote_options="permissive")
    return pl.from_arrow(t)


@dataclass(frozen=True)
class Tier:
    name: str
    start: Millis           # cutoffs are drawn in (start, end]
    end: Millis             # no row known after this is loaded


def manifest_times(manifest: dict) -> dict[str, Millis | None]:
    src = {**manifest, **(manifest.get("tiers") or {})}
    t_train = parse_time(src.get("T_train"))
    t_end = parse_time(src.get("T_end"))
    t_lb = parse_time(src.get("T_leaderboard_end")) or t_end
    return {"T_train": t_train, "T_leaderboard_end": t_lb, "T_end": t_end}


def resolve_snapshot(snapshot_id: str | None) -> str:
    """The id to use: the argument, $ARENA_SNAPSHOT, or the newest snapshot."""
    import os
    if snapshot_id:
        return snapshot_id
    if os.environ.get("ARENA_SNAPSHOT"):
        return os.environ["ARENA_SNAPSHOT"]
    root = arena_home() / "snapshots"
    found = []
    for d in sorted(root.glob("*/manifest.json")) if root.is_dir() else []:
        try:
            m = json.loads(d.read_text())
        except (OSError, ValueError):
            continue
        found.append((str(m.get("created_at", "")), d.parent.name))
    if not found:
        raise FileNotFoundError(f"no snapshot under {root}; pass --snapshot or run `arena export` / `arena synth`")
    return max(found)[1]


def iso_ms(ms: Millis) -> str:
    import datetime as _dt
    return _dt.datetime.fromtimestamp(ms / 1000, _dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def resolve_after(value: str | int) -> Millis:
    """The prospective tier's start: epoch ms, an ISO 8601 time, or the id of
    a snapshot under ARENA_HOME (its manifest's T_end: the moment the models
    scored on it were frozen against)."""
    if isinstance(value, (int, float)):
        return int(value)
    s = str(value).strip()
    try:
        return int(parse_time(s))
    except ValueError:
        pass
    f = snapshot_dir(s) / "manifest.json"
    if not f.is_file():
        raise ValueError(f"{s!r} is neither an ISO time nor a snapshot under {arena_home() / 'snapshots'}")
    t_end = manifest_times(json.loads(f.read_text()))["T_end"]
    if t_end is None:
        raise ValueError(f"snapshot {s} has no T_end in its manifest")
    return int(t_end)


class SnapshotData:
    """Every data table of one tier, in memory (runner side only).

    Label tables are not loaded here: nothing that can reach a model is built
    from them. `labels(name)` reads one for the harness on demand."""

    def __init__(self, tables: dict[str, pl.DataFrame], *, snapshot_id: str, tier: Tier,
                 manifest: dict | None = None, root: Path | None = None, after: Millis | None = None):
        self.after = after          # the prospective tier's start, when one was given
        self.tables = {n: tables.get(n, empty_frame(n)) for n in DATA_TABLES}
        bad = set(tables) & set(LABEL_TABLES)
        if bad:
            raise ValueError(f"label tables must not be loaded as data: {sorted(bad)}")
        self.snapshot_id = snapshot_id
        self.tier = tier
        self.manifest = manifest or {}
        self.root = root
        self._prepared: dict[Mode, dict[str, pl.DataFrame]] = {}
        # Rows known after the tier's end don't exist for this tier.
        for n, df in self.tables.items():
            if df.height:
                self.tables[n] = df.filter(ms("t_known") <= tier.end)

    @classmethod
    def load(cls, snapshot_id: str | None, tier: str = "visible", *, after: Millis | None = None) -> "SnapshotData":
        if tier not in TIERS:
            raise ValueError(f"unknown tier {tier!r}; one of {TIERS}")
        sid = resolve_snapshot(snapshot_id)
        return cls.from_dir(snapshot_dir(sid), tier, sid, after=after)

    @classmethod
    def from_dir(cls, root: Path, tier: str = "visible", snapshot_id: str | None = None, *,
                 after: Millis | None = None) -> "SnapshotData":
        """One tier of the snapshot at `root` (what `load` resolves to); a
        parallel run's job processes reload their data this way.

        `after` (prospective tier only): cutoffs fall in (after, T_end], so
        models frozen at `after` are scored only on what did not exist when
        they were written; history before it is still served as usual.
        Without it the prospective tier spans all the data, like synthetic."""
        if after is not None and tier != "prospective":
            raise ValueError("`after` applies to the prospective tier only")
        if tier not in TIERS:
            raise ValueError(f"unknown tier {tier!r}; one of {TIERS}")
        root = Path(root)
        sid = snapshot_id or root.name
        manifest = json.loads((root / "manifest.json").read_text())
        times = manifest_times(manifest)
        roots = [root / "train"]
        if tier != "visible" and (root / "holdout").is_dir():
            roots.append(root / "holdout")
        tables = {n: read_table(roots, n) for n in DATA_TABLES}
        data_start = _data_start(tables)
        t_train, t_lb, t_end = times["T_train"], times["T_leaderboard_end"], times["T_end"]
        data_end = _data_end(tables)
        if tier == "visible":
            tr = Tier(tier, data_start, t_train or data_end)
        elif tier == "leaderboard":
            _need(t_train, t_lb, tier)
            tr = Tier(tier, t_train, t_lb)
        elif tier == "lockbox":
            _need(t_lb, t_end, tier)
            tr = Tier(tier, t_lb, t_end)
        else:
            end = t_end or data_end
            start = data_start
            if after is not None:
                start = max(data_start, int(after))
                if start >= end:
                    raise ValueError(f"nothing to score after {iso_ms(int(after))}: snapshot {sid} ends "
                                     f"{iso_ms(end)}; export a newer one")
            tr = Tier(tier, start, end)
        return cls(tables, snapshot_id=sid, tier=tr, manifest=manifest, root=root, after=after)

    def labels(self, name: str) -> pl.DataFrame:
        if name not in LABEL_TABLES:
            raise KeyError(name)
        if self.root is None:
            return empty_frame(name)
        return read_table([self.root / "labels", self.root / "train", self.root / "holdout"], name)

    @property
    def data_start(self) -> Millis:
        return _data_start(self.tables)

    def accounts(self) -> tuple[str, ...]:
        seen: set[str] = set()
        for n in ("turns", "meter_readings", "accounts"):
            df = self.tables[n]
            if df.height:
                seen.update(a for a in df["account"].unique().to_list() if a is not None)
        return tuple(sorted(seen))

    def prepared(self, mode: Mode) -> dict[str, pl.DataFrame]:
        if mode not in self._prepared:
            self._prepared[mode] = prepare(self.tables, mode)
        return self._prepared[mode]

    def view(self, scope: Scope, mode: Mode = "current_code",
             history_start: Millis | None = None) -> "EpisodeView":
        return EpisodeView(self, scope, mode, history_start)


def _need(*vals):
    if any(v is None for v in vals[:-1]):
        raise ValueError(f"manifest lacks the boundaries of the {vals[-1]!r} tier")


def _data_start(tables: dict[str, pl.DataFrame]) -> Millis:
    vals = [tables[n].select(ms("t_event").min()).item() for n in ("turns", "meter_readings")
            if n in tables and tables[n].height]
    vals = [v for v in vals if v is not None]
    return int(min(vals)) if vals else 0


def _data_end(tables: dict[str, pl.DataFrame]) -> Millis:
    vals = [df.select(ms("t_known").max()).item() for df in tables.values() if df.height]
    vals = [v for v in vals if v is not None]
    return int(max(vals)) if vals else 0


# ---------------------------------------------------------------------------
# Internal clocks
# ---------------------------------------------------------------------------

def _u(expr: pl.Expr, present: pl.Expr) -> pl.Expr:
    """Knowability of a masked group: `expr` (ms) when the group holds a value
    whose time is given; NEVER when it holds a value of unknown time; ALWAYS
    when there is nothing to hide."""
    return (pl.when(~present).then(pl.lit(ALWAYS, pl.Int64))
            .otherwise(expr.fill_null(NEVER)).cast(pl.Int64))


def prepare(tables: dict[str, pl.DataFrame], mode: Mode) -> dict[str, pl.DataFrame]:
    """Add the internal columns every slice reads: `_te`, `_tk`, `_vis`
    (visibility time in this mode) and `_u_<group>` per masked group. Rows are
    sorted by (`_vis`, `_te`) so served tables come out in a stable order."""
    out: dict[str, pl.DataFrame] = {}
    revs = _revision_times(tables.get("turn_revisions"))
    for name, df in tables.items():
        df = df.with_columns(ms("t_event").alias("_te"), ms("t_known").alias("_tk"))
        df = df.with_columns(pl.col("_tk").alias("_vis"))
        for g, (cols, kt) in late_groups(name).items():
            present = pl.any_horizontal([pl.col(c).is_not_null() for c in cols])
            df = df.with_columns(_u(ms(kt), present).alias(f"_u_{g}"))
        if name == "turns":
            df = _prepare_turns(df, mode, revs)
        elif name == "prices":
            df = _prepare_prices(df)
        out[name] = df.sort(["_vis", "_te"], maintain_order=True)
    return out


def _revision_times(revs: pl.DataFrame | None) -> pl.DataFrame | None:
    """Per call: the time the LAST revision of each kind became known. Before
    it, the column held an older value the store did not keep."""
    if revs is None or revs.height == 0:
        return None
    r = revs.filter(pl.col("kind").is_in(list(REVISION_GROUPS)))
    if r.height == 0:
        return None
    return (r.group_by(["call_id", "kind"]).agg(ms("t_known").max().alias("t"))
            .pivot(on="kind", index="call_id", values="t"))


def _prepare_turns(df: pl.DataFrame, mode: Mode, revs: pl.DataFrame | None) -> pl.DataFrame:
    if revs is not None:
        df = df.join(revs.rename({k: f"_r_{k}" for k in revs.columns if k != "call_id"}),
                     on="call_id", how="left")
    mask = pl.col("revised_mask").fill_null(0).cast(pl.Int64)
    for kind, (bit, _) in REVISION_GROUPS.items():
        rc = f"_r_{kind}"
        rev = pl.col(rc) if rc in df.columns else pl.lit(None, pl.Int64)
        has_bit = (mask & bit) != 0
        df = df.with_columns(
            pl.when(rev.is_not_null()).then(rev)
            .when(has_bit).then(pl.lit(NEVER, pl.Int64))
            .otherwise(pl.lit(ALWAYS, pl.Int64)).cast(pl.Int64).alias(f"_u_rev_{kind}"))
    df = df.drop([c for c in df.columns if c.startswith("_r_")])
    if mode == "current_code":
        # Final values from t_known; the mask keeps only revisions known by then
        # (an upgrade before the row was final), never a later rewrite.
        known_bits = sum(
            (pl.when(pl.col(f"_u_rev_{k}") <= pl.col("_tk")).then(pl.lit(b, pl.Int64))
             .otherwise(pl.lit(0, pl.Int64)) for k, (b, _) in REVISION_GROUPS.items()),
            pl.lit(0, pl.Int64))
        df = df.with_columns(
            pl.when(pl.col("revised_mask").is_null()).then(None)
            .otherwise(mask & known_bits).cast(pl.Int16).alias("revised_mask"))
        df = df.drop([f"_u_rev_{k}" for k in REVISION_GROUPS])
    else:
        df = df.with_columns(pl.coalesce(ms("t_first_recorded"), pl.col("_tk")).alias("_vis"))
    return df


def _prepare_prices(df: pl.DataFrame) -> pl.DataFrame:
    """A rate's end is known when the next rate for the same (model, part,
    tier) is known: the successor whose period starts where this one ends."""
    key = ["model", "part", "tier_threshold"]
    succ = (df.select(*key, ms("t_effective_from").alias("_from"), pl.col("_tk").alias("_succ_tk"))
            .group_by([*key, "_from"]).agg(pl.col("_succ_tk").min()))
    df = df.with_columns(ms("t_effective_to").alias("_to"))
    df = df.join(succ, left_on=[*key, "_to"], right_on=[*key, "_from"], how="left", nulls_equal=True)
    df = df.with_columns(_u(pl.col("_succ_tk"), pl.col("t_effective_to").is_not_null()).alias("_u_to"))
    return df.drop(["_to", "_succ_tk"])


def _apply_masks(name: str, df: pl.DataFrame, now: Millis, mode: Mode) -> pl.DataFrame:
    """The served form of each row at `now`; drops every internal column."""
    groups = MASKS[mode].get(name, {})
    exprs = []
    for g, cols in groups.items():
        known = pl.col(f"_u_{g}") <= now
        for c in cols:
            exprs.append(pl.when(known).then(pl.col(c)).otherwise(None).alias(c))
    for c in ALWAYS_NULL.get(name, ()):
        exprs.append(pl.lit(None, df.schema[c]).alias(c))
    if name == "turns" and mode == "as_recorded":
        applied = [pl.when(pl.col(f"_u_rev_{k}") <= now).then(pl.col(f"_u_rev_{k}"))
                   .otherwise(pl.lit(ALWAYS, pl.Int64)) for k in REVISION_GROUPS]
        bits = sum((pl.when(pl.col(f"_u_rev_{k}") <= now).then(pl.lit(b, pl.Int64))
                    .otherwise(pl.lit(0, pl.Int64)) for k, (b, _) in REVISION_GROUPS.items()),
                   pl.lit(0, pl.Int64))
        exprs.append(pl.max_horizontal(pl.col("_vis"), *applied).cast(pl.Datetime("ms", "UTC")).alias("t_known"))
        exprs.append(pl.when(pl.col("revised_mask").is_null()).then(None)
                     .otherwise(pl.col("revised_mask").cast(pl.Int64) & bits).cast(pl.Int16).alias("revised_mask"))
    if exprs:
        df = df.with_columns(exprs)
    return df.drop([c for c in df.columns if c.startswith("_")])


def _changes_in(name: str, df: pl.DataFrame, since: Millis, until: Millis, mode: Mode) -> pl.Expr:
    """Rows whose served form changed in (since, until]: newly visible, or a
    masked group became known."""
    vis = pl.col("_vis")
    cond = (vis > since) & (vis <= until)
    for g in MASKS[mode].get(name, {}):
        u = pl.col(f"_u_{g}")
        cond = cond | ((vis <= since) & (u > since) & (u <= until))
    return cond


# ---------------------------------------------------------------------------
# Runner-side slicing
# ---------------------------------------------------------------------------

class EpisodeView:
    """One episode's view (scope, mode, history start), sliced at any moment.
    Runner side: it holds the whole tier."""

    def __init__(self, data: SnapshotData, scope: Scope, mode: Mode = "current_code",
                 history_start: Millis | None = None):
        if mode not in MODES:
            raise ValueError(f"unknown mode {mode!r}")
        if scope.view not in ("scope_only", "all"):
            raise ValueError(f"unknown view {scope.view!r}")
        self.data, self.scope, self.mode, self.start = data, scope, mode, history_start
        self._p = data.prepared(mode)
        self._sets: dict[Millis, tuple[pl.Series, pl.Series]] = {}

    @property
    def key(self) -> dict:
        """What identifies this view (with the snapshot and `now`): the child
        cache and determinism rely on it."""
        return {"accounts": list(self.scope.accounts), "view": self.scope.view,
                "mode": self.mode, "start": self.start, "tier_end": self.data.tier.end}

    def _base(self, name: str) -> pl.DataFrame:
        df = self._p[name]
        if self.start is not None and name not in UNCUT:
            df = df.filter(pl.col("_te") >= self.start)
        return df

    def _scope_sets(self, now: Millis) -> tuple[pl.Series, pl.Series]:
        """(call ids, session hashes) in scope as known at `now`."""
        if now in self._sets:
            return self._sets[now]
        acc = list(self.scope.accounts)
        turns = _apply_masks("turns", self._base("turns").filter(pl.col("_vis") <= now), now, self.mode)
        turns = turns.filter(pl.col("account").is_in(acc))
        sess = self._base("sessions").filter((pl.col("_vis") <= now) & pl.col("account").is_in(acc))
        calls = turns["call_id"].unique()
        sessions = pl.concat([turns["session_h"].drop_nulls(), sess["session_h"].drop_nulls()]).unique()
        if len(self._sets) > 8:
            self._sets.pop(next(iter(self._sets)))
        self._sets[now] = (calls, sessions)
        return calls, sessions

    def _scoped(self, name: str, df: pl.DataFrame, now: Millis) -> pl.DataFrame:
        if self.scope.view == "all" or name in GLOBAL_TABLES:
            return df
        if name in ACCOUNT_TABLES:
            return df.filter(pl.col("account").is_in(list(self.scope.accounts)))
        calls, sessions = self._scope_sets(now)
        if name in SESSION_TABLES:
            return df.filter(pl.col("session_h").is_in(sessions.implode()))
        if name in CALL_TABLES:
            return df.filter(pl.col("call_id").is_in(calls.implode()))
        raise AssertionError(f"no scope rule for {name}")

    def history(self, now: Millis) -> dict[str, pl.DataFrame]:
        """Every data table as known at `now`, in served form."""
        out = {}
        for name in DATA_TABLES:
            df = self._base(name).filter(pl.col("_vis") <= now)
            out[name] = self._scoped(name, _apply_masks(name, df, now, self.mode), now)
        return out

    def events(self, since: Millis, until: Millis) -> dict[str, pl.DataFrame]:
        """Rows whose served form changed in (since, until], in their form at
        `until`: newly known rows, rows whose masked columns became known, and
        rows that entered the scope (their session or call joined it)."""
        if until < since:
            raise ValueError("until < since")
        out = {}
        if self.scope.view == "scope_only":
            c0, s0 = self._scope_sets(since)
            c1, s1 = self._scope_sets(until)
            new_calls = c1.filter(~c1.is_in(c0.implode()))
            new_sessions = s1.filter(~s1.is_in(s0.implode()))
        for name in DATA_TABLES:
            df = self._base(name)
            cond = _changes_in(name, df, since, until, self.mode)
            if self.scope.view == "scope_only":
                if name in SESSION_TABLES:
                    cond = cond | ((pl.col("_vis") <= since) & pl.col("session_h").is_in(new_sessions.implode()))
                elif name in CALL_TABLES:
                    cond = cond | ((pl.col("_vis") <= since) & pl.col("call_id").is_in(new_calls.implode()))
            df = df.filter(cond)
            out[name] = self._scoped(name, _apply_masks(name, df, until, self.mode), until)
        return out

    def accounts_at(self, now: Millis) -> tuple[str, ...]:
        if self.scope.view == "scope_only":
            return tuple(self.scope.accounts)
        return view_accounts(self.history(now), self.scope)


def view_accounts(tables: dict[str, pl.DataFrame], scope: Scope) -> tuple[str, ...]:
    """The accounts a view shows: the scope's, or every account seen so far."""
    if scope.view == "scope_only":
        return tuple(scope.accounts)
    seen: set[str] = set(scope.accounts)
    for n in ("turns", "meter_readings", "accounts", "account_events", "sessions"):
        df = tables.get(n)
        if df is not None and df.height and "account" in df.columns:
            seen.update(a for a in df["account"].unique().to_list() if a is not None)
    return tuple(sorted(seen))


# ---------------------------------------------------------------------------
# Model-side views (the `History` and `Events` of arena.types)
# ---------------------------------------------------------------------------

class _Tables:
    tables: tuple[str, ...]
    _t: dict[str, pl.DataFrame]

    def table(self, name: str) -> pl.DataFrame:
        try:
            return self._t[name]
        except KeyError:
            if name in LABEL_TABLES:
                raise KeyError(f"{name!r} is a label table: never part of a model's history") from None
            raise KeyError(f"no table {name!r}; tables: {', '.join(self.tables)}") from None

    def arrow(self, name: str) -> pa.Table:
        return self.table(name).to_arrow()

    def sql(self, query: str) -> pl.DataFrame:
        """DuckDB over the same tables, each registered under its own name."""
        if self._con is None:
            import duckdb
            con = duckdb.connect()
            for n, df in self._t.items():
                con.register(n, df.to_arrow())
            self._con = con
        return self._con.sql(query).pl()

    _con = None


class HistoryView(_Tables):
    """Everything known at `now` for one scope. Read-only."""

    def __init__(self, tables: dict[str, pl.DataFrame], now: Millis, scope: Scope,
                 mode: Mode = "current_code", start: Millis | None = None,
                 tz_offset_min: int | None = None):
        bad = set(tables) - set(DATA_TABLES)
        if bad:
            raise ValueError(f"not data tables: {sorted(bad)}")
        self._t = {n: tables.get(n, empty_frame(n)) for n in DATA_TABLES}
        self.tables = tuple(self._t)
        self.now, self.scope, self.mode, self.start = int(now), scope, mode, start
        # The device's UTC offset as known at now (minutes; None = unknown).
        # The runner sends it: the user's clock is not account data, so a
        # scope-only view knows it even before its own accounts have a turn.
        self.tz_offset_min = None if tz_offset_min is None else int(tz_offset_min)
        self.accounts = view_accounts(self._t, scope)
        self._con = None

    @classmethod
    def from_arrow(cls, tables: dict[str, pa.Table], now: Millis, scope: Scope,
                   mode: Mode = "current_code", start: Millis | None = None,
                   tz_offset_min: int | None = None) -> "HistoryView":
        return cls({n: pl.from_arrow(t) for n, t in tables.items()}, now, scope, mode, start, tz_offset_min)

    def extend(self, events: "EventsView") -> "HistoryView":
        """The history as of `events.until`. Rows the events re-deliver in a
        newer form (same identity key) replace the old ones."""
        if events.since != self.now:
            raise ValueError(f"events start at {events.since}, history is at {self.now}")
        out = {}
        for name, h in self._t.items():
            e = events._t.get(name)
            if e is None or e.height == 0:
                out[name] = h
                continue
            key = IDENTITY.get(name)
            if key and h.height:
                h = h.join(e.select(list(key)).unique(), on=list(key), how="anti", nulls_equal=True)
            out[name] = pl.concat([h, e], how="vertical_relaxed") if h.height else e
        tz = getattr(events, "tz_offset_min", None)
        return HistoryView(out, events.until, self.scope, self.mode, self.start,
                           self.tz_offset_min if tz is None else tz)

    def __repr__(self) -> str:
        rows = ", ".join(f"{n}={df.height}" for n, df in self._t.items() if df.height)
        return f"HistoryView(now={self.now}, scope={self.scope}, mode={self.mode}, {rows})"


class EventsView(_Tables):
    """Rows whose served form changed in (since, until]. A row seen before
    may come again in a newer form; `IDENTITY` names the key that matches it."""

    keys = IDENTITY

    def __init__(self, tables: dict[str, pl.DataFrame], since: Millis, until: Millis,
                 tz_offset_min: int | None = None):
        bad = set(tables) - set(DATA_TABLES)
        if bad:
            raise ValueError(f"not data tables: {sorted(bad)}")
        self._t = {n: tables.get(n, empty_frame(n)) for n in DATA_TABLES}
        self.tables = tuple(self._t)
        self.since, self.until = int(since), int(until)
        self.tz_offset_min = None if tz_offset_min is None else int(tz_offset_min)   # as known at until
        self._con = None

    @classmethod
    def from_arrow(cls, tables: dict[str, pa.Table], since: Millis, until: Millis,
                   tz_offset_min: int | None = None) -> "EventsView":
        return cls({n: pl.from_arrow(t) for n, t in tables.items()}, since, until, tz_offset_min)

    def __repr__(self) -> str:
        rows = ", ".join(f"{n}={df.height}" for n, df in self._t.items() if df.height)
        return f"EventsView(({self.since}, {self.until}], {rows})"
