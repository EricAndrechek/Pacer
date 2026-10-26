"""`arena export`, end to end: copy, extract, build (twice), validate,
write into a temp dir, and rename into place only when every gate passes.
On failure nothing lands under snapshots/; the report goes to
`ARENA_HOME/export-failures/` for inspection (counts only, like every report).
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
import pyarrow as pa

from arena.snapshot import arena_home, snapshot_dir
from arena.snapshot.schema import DATA_TABLES, SCHEMA_VERSION, TABLES

from . import build as build_mod
from . import extract, layout, sources, validate
from .pseudo import load_or_create_salt, salt_id
from .util import iso, ms

EXPORTER_VERSION = "1"


def log(msg: str) -> None:
    print(f"[export {datetime.now().strftime('%H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


@dataclass
class ExportResult:
    ok: bool
    snapshot: Path | None
    report: dict
    manifest: dict | None


def gather_inputs(paths: sources.SourcePaths, copies: sources.Copies) -> tuple[extract.Inputs, list[Path]]:
    files = sources.list_transcripts(paths.transcript_roots)
    s = extract.read_store(copies.store)
    lines, users = extract.extract_transcript_lines(files)
    inp = extract.Inputs(
        turns=s["turns"], rl=s["rl"], ul=s["ul"], archive=s["archive"], activations=s["activations"],
        accounts=s["accounts"], predictions=s["predictions"], evals=s["evals"], fits=s["fits"],
        price_records=s["price_records"], meta=s["meta"], ts_order=s["ts_order"], ts_changes=s["ts_changes"],
        reading_inserts=s["reading_inserts"], record_inserts=s["record_inserts"],
        history_start_ms=s["history_start_ms"], alias_map=s["alias_map"],
        duck_archive=extract.read_duck_archive(copies.archive),
        lines=lines, user_lines=users, cost_state=extract.extract_cost_state(files),
        metas=extract.extract_metas(files), history=extract.extract_history(paths.history_jsonl),
        cswap_switches=extract.extract_cswap(paths.cswap_log), rotate_ticks=extract.extract_rotate(paths.rotate_log),
        price_candidate=extract.read_json(paths.price_candidate), price_curated=extract.read_json(paths.price_curated),
        desktop_ids=extract.extract_desktop_ids(paths.desktop_sessions), transcript_files=len(files),
    )
    return inp, files


def _git_sha() -> str | None:
    try:
        r = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True,
                           cwd=Path(__file__).resolve().parent, timeout=10)
        return r.stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def run_export(snapshot_id: str, *, freeze: bool = False, t_train: str | None = None, tiers: str = "3w,3w",
               t_end: str | None = None, paths: sources.SourcePaths | None = None,
               home: Path | None = None) -> ExportResult:
    t_start = time.time()
    home = Path(home) if home else arena_home()
    if not snapshot_id or "/" in snapshot_id or snapshot_id.startswith("."):
        raise ValueError("snapshot id must be a plain name")
    final = home / "snapshots" / snapshot_id if home else snapshot_dir(snapshot_id)
    if final.exists():
        m = final / "manifest.json"
        if m.exists() and json.loads(m.read_text()).get("frozen"):
            raise SystemExit(f"snapshot {snapshot_id} is frozen; pick a new id")
    salt = load_or_create_salt(home)
    paths = paths or sources.SourcePaths.default()

    log("copying the store and archive")
    copies = sources.make_copies(paths)
    try:
        log("reading the copies and streaming transcripts")
        inp, files = gather_inputs(paths, copies)
        fp = sources.fingerprints(paths, copies, files)
    finally:
        copies.cleanup()
    copy_ms = fp["store"]["max_transaction_ms"] or int(inp.turns["t"].max())
    log(f"inputs ready: {len(inp.turns)} store turns, {len(inp.lines)} transcript lines, {len(files)} files")

    log("building tables")
    built = build_mod.build_all(inp, salt)
    hashes = {n: validate.table_hash(t) for n, t in built.tables.items()}
    log("rebuilding for the determinism gate")
    rebuilt = build_mod.build_all(inp, salt)
    hashes2 = {n: validate.table_hash(t) for n, t in rebuilt.tables.items()}
    del rebuilt

    T_end = ms(t_end) if t_end else built.data_end_ms
    bounds = layout.tier_bounds(T_end, tiers, ms(t_train) if t_train else None)
    tables = layout.clip_to_end(built.tables, bounds["T_end"])
    t_start_data = min(int(t["t_known"].cast(pa.int64()).to_numpy(zero_copy_only=False).min())
                       for n, t in tables.items() if n in DATA_TABLES and t.num_rows)
    final_hashes = {n: validate.table_hash(t) for n, t in tables.items()}

    log("running gates 1-6, 8, 9")
    f = built.frames
    prefixes, names = validate.leak_terms(inp)
    gates = [
        validate.gate_store_vs_transcripts(f["turns"], copy_ms),
        validate.gate_store_vs_archive(inp.turns, inp.duck_archive),
        validate.gate_cost_state(f["_reconcile"]),
        validate.gate_readings(f["meter_readings"], f["turns"], f["app_alive"]),
        validate.gate_cycles(f["cycles"]),
        validate.gate_prices(f["turns"], f["prices"]),
    ]
    det = validate.gate_determinism(hashes, hashes2)
    leak = validate.gate_leak_scan(tables, prefixes, names)
    del prefixes, names

    tmp = home / "snapshots" / f".tmp-{snapshot_id}-{int(time.time() * 1000)}"
    tmp.mkdir(parents=True)
    try:
        log("writing files")
        counts = layout.write_tables(tmp, tables, bounds["T_train"], bounds["T_end"], validate.table_hash)
        log("running gate 7 (point in time) on the written files")
        pit = validate.gate_point_in_time(tmp, tables, bounds["T_train"], bounds["T_end"])
        gates = gates + [pit, det, leak]
        report = {
            "snapshot_id": snapshot_id, "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "passed": all(g["passed"] for g in gates), "gates": gates,
            "build_stats": built.stats,
        }
        manifest = {
            "snapshot_id": snapshot_id, "schema_version": SCHEMA_VERSION, "exporter_version": EXPORTER_VERSION,
            "created_at": report["created_at"], "frozen": bool(freeze),
            "T_start": t_start_data, **bounds,
            **{k + "_iso": iso(v) for k, v in {"T_start": t_start_data, **bounds}.items()},
            "tiers": {"visible": [t_start_data, bounds["T_train"]],
                      "leaderboard": [bounds["T_train"], bounds["T_leaderboard_end"]],
                      "lockbox": [bounds["T_leaderboard_end"], bounds["T_end"]]},
            "tiers_spec": tiers,
            "salt_id": salt_id(salt), "exporter_git_sha": _git_sha(),
            "sources": fp, "store_meta": inp.meta,
            "price_history": {"candidate_generated_at": (inp.price_candidate or {}).get("generatedAt"),
                              "candidate_sources": (inp.price_candidate or {}).get("sources"),
                              "curated_as_of": (inp.price_curated or {}).get("asOf")},
            "history_start": iso(inp.history_start_ms),
            "tables": {n: {"where": TABLES[n].where.value, "scope": TABLES[n].scope.value,
                           "partitioned": n in layout.PARTITIONED,
                           "partitioned_by": list(layout.PARTITIONED.get(n, ())),
                           "rows_total": tables[n].num_rows, "content_sha256": final_hashes[n],
                           **counts.get(n, {})} for n in TABLES},
            "lag_model": built.lag_models,
            "validation": {g["gate"]: g["passed"] for g in gates},
            "wall_time_s": None,
        }
        manifest["wall_time_s"] = round(time.time() - t_start, 1)
        (tmp / "validation").mkdir(exist_ok=True)
        (tmp / "validation" / "report.json").write_text(json.dumps(report, indent=1, default=_json_default))
        (tmp / "manifest.json").write_text(json.dumps(manifest, indent=1, default=_json_default))
        if not report["passed"]:
            fail_dir = home / "export-failures"
            fail_dir.mkdir(parents=True, exist_ok=True)
            out = fail_dir / f"{snapshot_id}-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
            out.write_text(json.dumps(report, indent=1, default=_json_default))
            log(f"validation FAILED; no snapshot. Report: {out}")
            shutil.rmtree(tmp, ignore_errors=True)
            return ExportResult(False, None, report, manifest)
        if final.exists():
            trash = final.with_name(f".old-{snapshot_id}-{int(time.time() * 1000)}")
            final.rename(trash)
            shutil.rmtree(trash, ignore_errors=True)
        tmp.rename(final)
        log(f"snapshot {snapshot_id} written in {manifest['wall_time_s']} s")
        return ExportResult(True, final, report, manifest)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise


def _json_default(o):
    if hasattr(o, "item"):
        return o.item()
    if isinstance(o, (set, tuple)):
        return list(o)
    if isinstance(o, pd.Timestamp):
        return o.isoformat()
    return str(o)
