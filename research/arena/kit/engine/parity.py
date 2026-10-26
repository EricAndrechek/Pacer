"""Replay parity: run the port of the app's shipping rule at the moments the
app recorded a rate-limit prediction, on the history the app had then
(`as_recorded` mode), and compare with what it recorded.

Harness side, never a model: it reads the label table
`predictions_of_record` and the whole snapshot (every tier, since the
records run to the snapshot's end). It scores nothing against meter truth,
so it can't leak a tier's outcomes into anything; it reports agreement with
the app.

    uv run python -m kit.engine.parity --snapshot working-2026-10-24
    uv run python -m kit.engine.parity --legacy-every 0 --accounts A2 --json

Rows compared: the per-account surfaces (`rl-five_hour#A1`, `rl-seven_day#A1`,
`rl-weekly_scoped|Fable|#A1`, …) whose method is the app's own; the
prediction lab's own models (`is_lab`) and the unscoped all-accounts rows
(whose account is not recorded) are left out.

For each recorded row, at its `recordedAt`:
- **rule**: the rule's method and displayed value at reset (with the
  `EngineParams` of the row's `paramsVersion`) against the recorded ones;
- **given the method**: the recorded method's own displayed value from the
  same refit, which separates projection parity (the as-of view, the cycle,
  the method's port) from selection parity (the record);
- **reading**: the latest reading the cycle shows against `usedPct`.

Mismatches beyond the tolerance are put down to one cause, first match wins:
`reading` (the snapshot's latest reading differs from the app's: a reading
the app had that the snapshot dates later, or the other way round), `cycle`
(no live cycle here, or the app had none), `selection` (another method),
`projection` (same method, same reading, another value).

Eras, reported apart:
- `current`: the engine that ships (#311 onward, v1-6109fa45 and
  v1-c13c3f81), each row with its own `EngineParams`;
- `lab-standin`: the same engine on a prediction-lab build, where a lab
  model was picked and the app's model stood in. The rule can't reproduce a
  pick among lab models, so read the given-method numbers only;
- `legacy`: the engine before #311 (v1-4c0cc586), different code that
  `Params.legacy_engine` reproduces; sampled (`--legacy-every`) because it
  is most of the rows.

Writes `ARENA_HOME/results/parity/<snapshot>/{rows.parquet,summary.json}`
(outside git) and prints the summary.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np
import polars as pl

from arena.snapshot import arena_home
from arena.snapshot.views import HistoryView, SnapshotData
from arena.types import Scope
from kit.engine.core import displayed_at_reset
from kit.engine.engine import RULE
from kit.engine.model import EngineState
from kit.engine.params import LEGACY_VERSIONS, SHIPPING, VERSIONS

TOLERANCE = 0.5


def parse_surface(surface: str) -> tuple[str, str | None] | None:
    """`rl-five_hour#A1` → ("five_hour", None); `rl-weekly_scoped|Fable|#A1` →
    ("weekly_scoped", "Fable")."""
    if not surface.startswith("rl-") or "#" not in surface:
        return None
    window = surface[3:].split("#", 1)[0]
    if window in ("five_hour", "seven_day"):
        return window, None
    if window.startswith("weekly_scoped|"):
        parts = window.split("|")
        return "weekly_scoped", (parts[1] or None) if len(parts) > 1 else None
    return None


def recorded_rows(data: SnapshotData) -> pl.DataFrame:
    p = data.labels("predictions_of_record")
    if p.height == 0:
        return p
    # A lab build's own models (`is_lab`) are not the app's engine; a row where
    # one was picked but the app's model stood in (`replaced_method` lab-*)
    # still shows an app method, so it is kept for the given-method check.
    p = p.filter(pl.col("surface").str.starts_with("rl-") & pl.col("account").is_not_null()
                 & ~pl.col("is_lab").fill_null(False)
                 & ~pl.col("method").fill_null("").str.starts_with("lab-"))
    p = p.with_columns(pl.col("replaced_method").fill_null("").str.starts_with("lab-").alias("lab_standin"))
    parsed = [parse_surface(s) for s in p["surface"].to_list()]
    p = p.with_columns(pl.Series("window_kind", [x[0] if x else None for x in parsed]),
                       pl.Series("scope_model", [x[1] if x else None for x in parsed], dtype=pl.String))
    return (p.filter(pl.col("window_kind").is_not_null())
            .with_columns(pl.col("t_event").dt.epoch("ms").alias("now_ms"))
            .sort(["account", "now_ms"]))


def era_of(version: str | None, lab_standin: bool = False) -> str:
    if version in LEGACY_VERSIONS:
        return "legacy"
    if version not in VERSIONS:
        return "unknown"
    return "lab-standin" if lab_standin else "current"


def run(snapshot: str | None, *, accounts: list[str] | None = None, legacy_every: int = 10,
        max_moments: int | None = None, eras: tuple[str, ...] = ("current", "lab-standin", "legacy"),
        progress: bool = False) -> pl.DataFrame:
    data = SnapshotData.load(snapshot, tier="lockbox")
    recs = recorded_rows(data)
    recs = recs.with_columns(pl.struct("params_version", "lab_standin").map_elements(
        lambda r: era_of(r["params_version"], r["lab_standin"]), return_dtype=pl.String).alias("era"))
    recs = recs.filter(pl.col("era").is_in(list(eras)))
    if accounts:
        recs = recs.filter(pl.col("account").is_in(accounts))
    out: list[dict] = []
    for acct in sorted(recs["account"].unique().to_list()):
        rows = recs.filter(pl.col("account") == acct)
        # One refit per moment; a moment can hold rows of two builds (the old
        # and new engines overlapped for a few days), each compared with its own.
        moments = (rows.group_by("now_ms").agg((pl.col("era") == "legacy").all().alias("legacy_only"))
                   .sort("now_ms"))
        if legacy_every != 1:
            leg = moments.filter(pl.col("legacy_only"))
            keep_leg = leg[::legacy_every] if legacy_every > 1 else leg.head(0)
            moments = pl.concat([moments.filter(~pl.col("legacy_only")), keep_leg]).sort("now_ms")
        if max_moments:
            moments = moments.head(max_moments)
        scope = Scope((acct,), "scope_only")
        view = data.view(scope, "as_recorded")
        cur = EngineState(RULE, SHIPPING)
        states = {"current": cur, "lab-standin": cur, "legacy": EngineState(RULE, VERSIONS["v1-4c0cc586"])}
        by_now = rows.partition_by("now_ms", as_dict=True)
        t0 = time.time()
        for k, now_ms in enumerate(moments["now_ms"].to_list()):
            hv = HistoryView(view.history(now_ms), now_ms, scope, "as_recorded")
            for rec in by_now[(now_ms,)].iter_rows(named=True):
                if legacy_every == 0 and rec["era"] == "legacy":
                    continue
                out.append(_compare(states[rec["era"]], hv, acct, rec, now_ms / 1000.0))
            if progress and k % 200 == 0:
                print(f"  {acct}: {k}/{moments.height} moments, {time.time() - t0:.0f}s", file=sys.stderr)
    return pl.DataFrame(out, infer_schema_length=None)


def _compare(state: EngineState, hv: HistoryView, acct: str, rec: dict, now_s: float) -> dict:
    params = VERSIONS.get(rec["params_version"], SHIPPING)
    o = state.outlook(hv, acct, rec["window_kind"], rec["scope_model"], now_s, params)
    rec_method = rec["method"]
    row = {
        "account": acct, "surface": rec["surface"].split("#")[0], "window": rec["window_kind"],
        "now_ms": rec["now_ms"], "era": rec["era"], "params_version": rec["params_version"],
        "rec_method": rec_method, "rec_value": rec["value"], "rec_used": rec["used_pct"],
        "rec_reset_ms": rec["period_end"].timestamp() * 1000 if rec["period_end"] is not None else None,
        "method": None, "value": None, "used": None, "selection": None, "given_value": None,
        "same_cycle": False,
    }
    if o is None:
        return row
    row.update(method=o.method, value=o.value, used=o.used_now, selection=o.selection,
               same_cycle=row["rec_reset_ms"] is None
               or abs(o.reset * 1000 - row["rec_reset_ms"]) < 60_000)
    fit = o.fits.get(rec_method)
    if fit is not None:
        proj = fit(o.partial, params)
        if proj is not None:
            row["given_value"] = displayed_at_reset(proj, o.partial)
    return row


def classify(df: pl.DataFrame, tol: float = TOLERANCE) -> pl.DataFrame:
    both = pl.col("value").is_not_null() & pl.col("rec_value").is_not_null()
    delta = (pl.col("value") - pl.col("rec_value")).abs()
    # Both declined (the app recorded method "none" with no value): a match
    # when it is the same cycle at the same reading.
    refused = (pl.col("value").is_null() & pl.col("rec_value").is_null() & pl.col("same_cycle")
               & ((pl.col("used") - pl.col("rec_used")).abs() <= 1e-9))
    ok = (both & (delta <= tol)) | refused.fill_null(False)
    reading = pl.col("used").is_not_null() & ((pl.col("used") - pl.col("rec_used")).abs() > 1e-9)
    cycle = pl.col("used").is_null() | ~pl.col("same_cycle") | (pl.col("value").is_null() != pl.col("rec_value").is_null())
    selection = pl.col("method") != pl.col("rec_method")
    return df.with_columns(
        delta.alias("abs_delta"),
        ((pl.col("given_value") - pl.col("rec_value")).abs()).alias("given_delta"),
        pl.when(ok).then(pl.lit("match"))
        .when(reading).then(pl.lit("reading"))
        .when(cycle).then(pl.lit("cycle"))
        .when(selection).then(pl.lit("selection"))
        .otherwise(pl.lit("projection")).alias("cause"))


def summarize(df: pl.DataFrame, tol: float = TOLERANCE) -> dict:
    df = classify(df, tol)
    out: dict = {"tolerance_pp": tol, "eras": {}}
    for keys, g in df.group_by(["era"], maintain_order=True):
        era = keys[0]
        e: dict = {"rows": g.height}
        both = g.filter(pl.col("value").is_not_null() & pl.col("rec_value").is_not_null())
        e["value_rows"] = both.height
        e["within_tol"] = _share(g["cause"] == "match")
        e["within_tol_of_valued"] = _share(both["abs_delta"] <= tol) if both.height else None
        e["abs_delta_p50"] = _q(both["abs_delta"], 0.5)
        e["abs_delta_p90"] = _q(both["abs_delta"], 0.9)
        e["abs_delta_max"] = float(both["abs_delta"].max()) if both.height else None
        e["method_agree"] = _share(g["method"].fill_null("none") == g["rec_method"])
        e["reading_agree"] = _share((g["used"] - g["rec_used"]).abs() <= 1e-9)
        given = g.filter(pl.col("given_delta").is_not_null())
        e["given_method_within_tol"] = _share(given["given_delta"] <= tol) if given.height else None
        e["given_method_within_tol_same_reading"] = _share(
            given.filter((pl.col("used") - pl.col("rec_used")).abs() <= 1e-9)["given_delta"] <= tol)
        e["causes"] = {k: v for k, v in g.group_by("cause").len().sort("len", descending=True).iter_rows()}
        e["by_window"] = {w: _share(gg["cause"] == "match") for (w,), gg in g.group_by(["window"])}
        out["eras"][era] = e
    return out


def _share(mask: pl.Series) -> float | None:
    mask = mask.drop_nulls()
    return round(float(mask.mean()), 4) if len(mask) else None


def _q(s: pl.Series, q: float) -> float | None:
    return round(float(s.quantile(q)), 3) if len(s) else None


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Replay parity of the port of the app's shipping rule.")
    ap.add_argument("--snapshot")
    ap.add_argument("--accounts", help="comma-separated, e.g. A1,A2")
    ap.add_argument("--legacy-every", type=int, default=10,
                    help="score every Nth legacy-engine moment (1 = all, 0 = none)")
    ap.add_argument("--max-moments", type=int, help="per account")
    ap.add_argument("--tolerance", type=float, default=TOLERANCE)
    ap.add_argument("--json", action="store_true", help="print the summary as JSON")
    ap.add_argument("--no-write", action="store_true")
    args = ap.parse_args(argv)
    eras = ("current", "lab-standin", "legacy") if args.legacy_every else ("current", "lab-standin")
    t = time.time()
    df = run(args.snapshot, accounts=args.accounts.split(",") if args.accounts else None,
             legacy_every=args.legacy_every or 1, max_moments=args.max_moments, eras=eras, progress=True)
    if df.height == 0:
        print("no recorded rate-limit predictions to compare")
        return 1
    summary = summarize(df, args.tolerance)
    summary["seconds"] = round(time.time() - t, 1)
    if not args.no_write:
        from arena.snapshot.views import resolve_snapshot
        d = arena_home() / "results" / "parity" / resolve_snapshot(args.snapshot)
        d.mkdir(parents=True, exist_ok=True)
        classify(df, args.tolerance).write_parquet(d / "rows.parquet")
        (d / "summary.json").write_text(json.dumps(summary, indent=2))
        summary["written_to"] = str(d)
    print(json.dumps(summary, indent=2) if args.json else _text(summary))
    return 0


def _text(s: dict) -> str:
    lines = [f"replay parity, tolerance {s['tolerance_pp']} pp"]
    for era, e in s["eras"].items():
        lines.append(f"\n[{era}] rows={e['rows']} with values={e['value_rows']}")
        for k in ("within_tol", "within_tol_of_valued", "abs_delta_p50", "abs_delta_p90", "abs_delta_max",
                  "method_agree", "reading_agree", "given_method_within_tol",
                  "given_method_within_tol_same_reading"):
            lines.append(f"  {k:>38}: {e[k]}")
        lines.append(f"  {'causes':>38}: {e['causes']}")
        lines.append(f"  {'within_tol by window':>38}: {e['by_window']}")
    if "written_to" in s:
        lines.append(f"\nrows and summary in {s['written_to']}")
    return "\n".join(lines)


if __name__ == "__main__":
    sys.exit(main())
