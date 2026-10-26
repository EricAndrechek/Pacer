"""The results database: `<ARENA_HOME>/results/arena.duckdb`, created from
`arena/results_schema.sql`, plus the forecast archive (parquet under
`results/forecasts/<run_id>/`). Leaderboards are views over these tables
(the scoring builder's `arena board`).

Attribution columns of `models` are written by whoever registers a model
first (the fleet collector for agent models; otherwise the runner, from the
tracked `models/PROVENANCE.toml`, `arena.provenance`) and never overwritten.
"""
from __future__ import annotations

import datetime as dt
from pathlib import Path

import duckdb
import pyarrow as pa
import pyarrow.parquet as pq

from arena import provenance
from arena.snapshot import arena_home

SCHEMA_SQL = Path(__file__).with_name("results_schema.sql")
TS = pa.timestamp("ms", tz="UTC")


def default_path() -> Path:
    return arena_home() / "results" / "arena.duckdb"


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _provenance_roots(path: Path) -> list[Path]:
    """Where a model's PROVENANCE.toml may be: the folder holding it, then
    this arena's models/ (a model staged elsewhere, e.g. for Docker workers,
    keeps its name)."""
    out = [path.parent]
    if provenance.ARENA_ROOT / "models" not in out:
        out.append(provenance.ARENA_ROOT / "models")
    return out


def _provenance_for(path: Path, name: str) -> dict | None:
    for r in _provenance_roots(path):
        rec = provenance.lookup(name, r)
        if rec is not None:
            return rec
    return None


def _hashes_of(path: Path, names: list[str]) -> list[str]:
    """Content hashes of the named models, found next to `path` or in this
    arena's models/ (names that are not there are skipped)."""
    from arena.registry import content_hash
    out = []
    for n in names:
        for r in _provenance_roots(path):
            d = r / n
            if (d / "model.toml").is_file() and (d / "model.py").is_file():
                out.append(content_hash(d))
                break
    return out


class ResultsDB:
    def __init__(self, path: Path | None = None, read_only: bool = False):
        self.path = Path(path) if path is not None else default_path()
        if not read_only:
            self.path.parent.mkdir(parents=True, exist_ok=True)
        self.con = duckdb.connect(str(self.path), read_only=read_only)
        if not read_only:
            self.con.execute(SCHEMA_SQL.read_text())

    def close(self) -> None:
        self.con.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    # rows ----------------------------------------------------------------
    def start_run(self, run_id: str, *, kind: str, tier: str, snapshot_id: str, seed: int,
                  harness_version: str, mode: str, requested_by: str | None = None) -> None:
        self.con.execute("INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)",
                         [run_id, kind, tier, snapshot_id, seed, harness_version, mode, requested_by, _now()])

    def finish_run(self, run_id: str) -> None:
        self.con.execute("UPDATE runs SET finished_at = ? WHERE run_id = ?", [_now(), run_id])

    def register_model(self, info, *, author_kind: str | None = None, generation: int | None = None,
                       niche: str | None = None, agent_session: str | None = None,
                       claude_model: str | None = None, claude_effort: str | None = None,
                       copied_from: list[str] | None = None, root: Path | None = None) -> None:
        """Insert a model (and its children) unless its hash is known.
        Without an explicit `author_kind`, attribution comes from the tracked
        `models/PROVENANCE.toml` when the model is listed there (so a fresh
        clone attributes agent models like the machine that ran the fleet),
        else 'coordinator'. Each child is looked up on its own."""
        path = Path(info.path)
        try:
            rel = str(path.relative_to(root or Path(__file__).resolve().parent.parent))
        except ValueError:
            rel = path.name
        if author_kind is None:
            rec = _provenance_for(path, info.name)
            if rec is not None:
                author_kind = provenance.author_kind(rec["kind"])
                generation, niche = rec["generation"], rec["niche"]
                claude_model, claude_effort = rec["claude_model"], rec["effort"]
                copied_from = _hashes_of(path, rec["copied_from"]) or None
            else:
                author_kind = "coordinator"
        self.con.execute(
            "INSERT INTO models VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING",
            [info.hash, info.name, rel, info.child_hashes(), generation, niche, author_kind, agent_session,
             claude_model, claude_effort, copied_from, _now()])
        for c in info.children.values():
            self.register_model(c, root=root)

    def add_episodes(self, run_id: str, episodes) -> None:
        if not episodes:
            return
        t = pa.table({
            "run_id": [run_id] * len(episodes),
            "episode_id": pa.array([e.episode_id for e in episodes], pa.int32()),
            "accounts": [list(e.scope.accounts) for e in episodes],
            "view": [e.scope.view for e in episodes],
            "history_start": pa.array([e.history_start for e in episodes], TS),
            "cutoff": pa.array([e.cutoff for e in episodes], TS),
            "horizon_end": pa.array([e.horizon_end for e in episodes], TS),
            "n_checkpoints": pa.array([len(e.checkpoints) for e in episodes], pa.int32()),
        })
        self._insert("episodes", t)

    def add_scores(self, rows: list[dict]) -> None:
        if not rows:
            return
        t = pa.table({
            "run_id": [r["run_id"] for r in rows],
            "episode_id": pa.array([r["episode_id"] for r in rows], pa.int32()),
            "model_hash": [r["model_hash"] for r in rows],
            "checkpoint_t": pa.array([r["checkpoint_t"] for r in rows], TS),
            "target_key": [r["target_key"] for r in rows],
            "target": [r["target"] for r in rows],
            "metric": [r["metric"] for r in rows],
            "lead_s": pa.array([r["lead_s"] for r in rows], pa.float64()),
            "value": pa.array([r["value"] for r in rows], pa.float64()),
        })
        self._insert("scores", t)

    def add_failures(self, rows: list[dict]) -> None:
        if not rows:
            return
        t = pa.table({
            "run_id": [r["run_id"] for r in rows],
            "episode_id": pa.array([r["episode_id"] for r in rows], pa.int32()),
            "model_hash": [r["model_hash"] for r in rows],
            "checkpoint_t": pa.array([r["checkpoint_t"] for r in rows], TS),
            "kind": [r["kind"] for r in rows],
            "message": [r["message"] for r in rows],
        })
        self._insert("failures", t)

    def write_forecasts(self, run_id: str, model_hash: str, rows: list[dict]) -> Path | None:
        """Forecast quantiles (or paths) for drill-downs, one parquet per
        run and model."""
        if not rows:
            return None
        d = self.path.parent / "forecasts" / run_id
        d.mkdir(parents=True, exist_ok=True)
        f = d / f"{model_hash}.parquet"
        t = pa.table({
            "episode_id": pa.array([r["episode_id"] for r in rows], pa.int32()),
            "checkpoint_t": pa.array([r["checkpoint_t"] for r in rows], TS),
            "target_key": [r["target_key"] for r in rows],
            "kind": [r["kind"] for r in rows],
            "grid": pa.array([r["grid"] for r in rows], pa.list_(pa.int64())),
            "values": pa.array([r["values"] for r in rows], pa.list_(pa.list_(pa.float32()))),
        })
        pq.write_table(t, f, compression="zstd")
        self.con.execute("INSERT INTO forecast_files VALUES (?, ?, ?)",
                         [run_id, model_hash, str(f.relative_to(self.path.parent))])
        return f

    def _insert(self, table: str, t: pa.Table) -> None:
        self.con.register("_arena_rows", t)
        try:
            cols = ", ".join(t.column_names)
            self.con.execute(f"INSERT INTO {table} ({cols}) SELECT {cols} FROM _arena_rows")
        finally:
            self.con.unregister("_arena_rows")
