"""`arena runs merge`: fold a run into another run that has exactly the same
episodes, so models scored separately sit on one board.

Why runs get split: `--docker` puts every worker of a run in a container, and
the trusted ports are several times faster on host workers, so the final
tournaments ran the ports on host workers into the main database and the
agents' models under `--docker` into separate ones, each with the same tier,
snapshot, seed, episode count and `--targets` (the episodes depend on the
targets requested: without `--targets` they follow what the models declare).
Same inputs, same episodes; this command checks that episode by episode
before it copies anything.

    arena runs merge --from-db results/final-gen1.duckdb --run <id> --into <id> [--results-db PATH]

Copies the source run's models (unless their hash is known), scores,
failures and forecast archive under the target run id. Paired comparisons
then work as if one run had scored every model.
"""
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

EPISODE_COLS = ("episode_id", "accounts", "view", "epoch_ms(history_start)", "epoch_ms(cutoff)",
                "epoch_ms(horizon_end)", "n_checkpoints")
RUN_COLS = ("tier", "snapshot_id", "seed", "mode")


class MergeError(Exception):
    pass


def register(subparsers) -> argparse.ArgumentParser:
    p = subparsers.add_parser("runs", help="manage runs in the results database")
    sub = p.add_subparsers(dest="runs_cmd", required=True)
    m = sub.add_parser("merge", help="fold a run (any database) into a run with identical episodes")
    m.add_argument("--from-db", required=True, help="the database holding the source run")
    m.add_argument("--run", required=True, help="the source run id")
    m.add_argument("--into", required=True, help="the target run id (in --results-db)")
    m.add_argument("--results-db", help="target database (default ARENA_HOME/results/arena.duckdb)")
    m.add_argument("--dry-run", action="store_true", help="check only")
    m.set_defaults(func=cmd_merge)
    return p


def merge(target_db: Path, source_db: Path, run: str, into: str, *, dry_run: bool = False) -> dict:
    """Check that `run` (in source_db) and `into` (in target_db) have the same
    tier, snapshot, seed, mode and episodes, then copy the source's rows in.
    Returns counts. Refuses a model already scored in the target run."""
    import duckdb
    target_db, source_db = Path(target_db), Path(source_db)
    same = target_db.resolve() == source_db.resolve()
    con = duckdb.connect(str(target_db), read_only=dry_run)
    try:
        if not same:
            con.execute(f"ATTACH '{source_db}' AS src (READ_ONLY)")
        src = "main" if same else "src"
        cols = ", ".join(RUN_COLS)
        a = con.execute(f"SELECT {cols} FROM runs WHERE run_id = ?", [into]).fetchone()
        b = con.execute(f"SELECT {cols} FROM {src}.runs WHERE run_id = ?", [run]).fetchone()
        if a is None or b is None:
            raise MergeError(f"no run {into if a is None else run}")
        if a != b:
            raise MergeError(f"the runs differ in {RUN_COLS}: {a} vs {b}")
        ecols = ", ".join(EPISODE_COLS)
        ea = con.execute(f"SELECT {ecols} FROM episodes WHERE run_id = ? ORDER BY episode_id", [into]).fetchall()
        eb = con.execute(f"SELECT {ecols} FROM {src}.episodes WHERE run_id = ? ORDER BY episode_id", [run]).fetchall()
        if ea != eb:
            n = sum(x != y for x, y in zip(ea, eb)) + abs(len(ea) - len(eb))
            raise MergeError(f"the episodes differ ({len(ea)} vs {len(eb)} episodes, {n} mismatched): "
                             "same tier, snapshot, seed, --episodes and --targets give the same episodes")
        clash = con.execute(f"SELECT DISTINCT model_hash FROM {src}.scores WHERE run_id = ? AND model_hash IN "
                            "(SELECT model_hash FROM scores WHERE run_id = ?)", [run, into]).fetchall()
        if clash:
            raise MergeError(f"{len(clash)} models already have scores in {into}")
        out = {"episodes": len(ea)}
        for t in ("scores", "failures"):
            out[t] = con.execute(f"SELECT count(*) FROM {src}.{t} WHERE run_id = ?", [run]).fetchone()[0]
        out["models"] = con.execute(f"SELECT count(DISTINCT model_hash) FROM {src}.scores WHERE run_id = ?",
                                    [run]).fetchone()[0]
        if dry_run:
            return out
        con.execute("BEGIN")
        con.execute(f"INSERT INTO models SELECT * FROM {src}.models WHERE model_hash NOT IN (SELECT model_hash FROM models)")
        for t in ("scores", "failures"):
            names = [r[0] for r in con.execute(f"DESCRIBE {t}").fetchall()]
            sel = ", ".join("?" if c == "run_id" else c for c in names)
            con.execute(f"INSERT INTO {t} ({', '.join(names)}) SELECT {sel} FROM {src}.{t} WHERE run_id = ?",
                        [into, run])
        files = con.execute(f"SELECT model_hash, path FROM {src}.forecast_files WHERE run_id = ?", [run]).fetchall()
        copied = 0
        for h, rel in files:
            f = source_db.parent / rel
            if not f.is_file():
                continue
            dest = target_db.parent / "forecasts" / into / f.name
            if not same or dest != f:
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(f, dest)
            con.execute("INSERT INTO forecast_files VALUES (?, ?, ?)",
                        [into, h, str(dest.relative_to(target_db.parent))])
            copied += 1
        con.execute("COMMIT")
        out["forecast_files"] = copied
        return out
    finally:
        con.close()


def cmd_merge(a) -> int:
    from arena.results import default_path
    target = Path(a.results_db) if a.results_db else default_path()
    try:
        out = merge(target, Path(a.from_db), a.run, a.into, dry_run=a.dry_run)
    except MergeError as e:
        print(f"arena runs merge: {e}", file=sys.stderr)
        return 2
    verb = "would merge" if a.dry_run else "merged"
    print(f"{verb} run {a.run} into {a.into}: " + ", ".join(f"{v} {k}" for k, v in out.items()))
    return 0
